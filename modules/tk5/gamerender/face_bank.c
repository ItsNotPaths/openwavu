#include "gamerender/face_bank.h"

#include <stdio.h>
#include <string.h>

#include "sim/math.h"
#include "sim/quat.h"

static const float BLEND_MIN = 1e-5f;  // weights below this skip the blend

static T5FacePose frame_pose(const T5ClipBank *bank, uint16_t clip, int32_t frame) {
    T5FacePose pose;
    for (uint32_t track = 0; track < bank->track_count; track++) pose.track[track] = t5_clip_key(bank, clip, track, frame);
    return pose;
}

T5FacePose t5_face_pose_blend(const T5ClipBank *bank, T5FacePose from, T5FacePose to, float weight) {
    T5FacePose out;
    for (uint32_t track = 0; track < bank->track_count; track++) {
        const T5Vec4 *first = &from.track[track], *second = &to.track[track];
        if (bank->tracks[track].path == CLIP_ROTATION) t5_quat_blend(&out.track[track], weight, first, second);
        else
            for (int axis = 0; axis < 4; axis++) out.track[track].v[axis] = first->v[axis] + (second->v[axis] - first->v[axis]) * weight;
    }
    return out;
}

T5FacePose t5_face_clip_sample(const T5ClipBank *bank, uint16_t clip, float time) {
    float whole;
    float weight = t5_modf(time, &whole);  // split time: fraction is the blend weight
    int32_t frame = t5_fctiwz(whole);
    T5FacePose pose = frame_pose(bank, clip, frame);
    if (!(weight >= BLEND_MIN)) return pose;  // no real blend: tiny or NaN weight
    return t5_face_pose_blend(bank, pose, frame_pose(bank, clip, frame + 1), weight);
}

static bool same_tracks(const T5ClipBank *first, const T5ClipBank *second) {
    return first->track_count == second->track_count && memcmp(first->tracks, second->tracks, first->track_count * sizeof *first->tracks) == 0;
}

enum { FACE_OWNER_BYTES = T5_OWNER_BYTES + sizeof "/face_poses" };

const char *t5_load_faces(T5FaceBanks *banks, sqlite3 *db, const char *character, T5ReadFile read, void *context) {
    char bank[T5_OWNER_BYTES], poses[FACE_OWNER_BYTES], clips[FACE_OWNER_BYTES];
    *banks = (T5FaceBanks){0};
    const char *failed = t5_own_anim_bank(db, character, bank);
    snprintf(poses, sizeof poses, "%s/face_poses", character);
    snprintf(clips, sizeof clips, "%s/face_clips", bank);
    if (!failed) failed = t5_load_clip_bank(&banks->poses, db, poses, read, context);
    if (!failed) failed = t5_load_clip_bank(&banks->clips, db, clips, read, context);
    if (!failed && !banks->poses.clip_count) failed = "faces: no face poses";
    if (!failed && banks->poses.track_count > FACE_TRACKS_MAX) failed = "faces: too many tracks";
    if (!failed && banks->clips.clip_count && !same_tracks(&banks->poses, &banks->clips)) failed = "faces: the banks have other tracks";
    if (failed) t5_free_faces(banks);
    return failed;
}

void t5_free_faces(T5FaceBanks *banks) {
    t5_free_clip_bank(&banks->poses);
    t5_free_clip_bank(&banks->clips);
}
