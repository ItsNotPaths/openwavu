#include "gamerender/face_bank.h"

#include <stdio.h>

#include "sim/anim.h"
#include "sim/math.h"
#include "sim/quat.h"

static const float BLEND_MIN = 1e-5f;  // weights below this skip the blend

// The table at 0x10007ed0 and the channel types of the face banks.
const T5FaceChannel T5_FACE_CHANNELS[FACE_CHANNELS] = {
    {81, FACE_TURN}, {81, FACE_MOVE}, {96, FACE_TURN}, {105, FACE_TURN}, {94, FACE_TURN}, {103, FACE_TURN},
    {97, FACE_MOVE}, {106, FACE_MOVE}, {95, FACE_MOVE}, {104, FACE_MOVE}, {93, FACE_MOVE}, {102, FACE_MOVE},
    {91, FACE_MOVE}, {100, FACE_MOVE}, {90, FACE_MOVE}, {99, FACE_MOVE}, {89, FACE_TURN}, {98, FACE_TURN},
    {89, FACE_MOVE}, {98, FACE_MOVE}, {88, FACE_TURN}, {92, FACE_TURN}, {101, FACE_TURN}, {88, FACE_MOVE},
    {92, FACE_MOVE}, {101, FACE_MOVE}, {83, FACE_TURN}, {85, FACE_TURN}, {83, FACE_MOVE}, {85, FACE_MOVE},
    {82, FACE_TURN}, {84, FACE_TURN}, {82, FACE_MOVE}, {84, FACE_MOVE}, {86, FACE_TURN}, {87, FACE_TURN},
    {86, FACE_SCALE}, {87, FACE_SCALE},
};

static T5KeyKind face_key_kind(int32_t channel) {
    static const T5KeyKind KEY_KINDS[] = {[FACE_TURN] = T5_KEY_AXIS_ANGLE, [FACE_MOVE] = T5_KEY_POSITION, [FACE_SCALE] = T5_KEY_VALUES};
    return KEY_KINDS[T5_FACE_CHANNELS[channel].kind];
}

static int parse_face_clip(void *clip, T5Bytes file) {
    const float *keys;
    uint16_t frames = t5_anim_file(file, "tk5face", FACE_CHANNELS, face_key_kind, &keys);
    *(T5FaceClip *)clip = frames ? (T5FaceClip){frames, (const T5FaceKeys *)keys} : (T5FaceClip){0};
    return frames ? 0 : -1;
}

static T5FaceClip clip_at(T5FaceBank bank, uint16_t clip) {
    if (clip >= bank.clip_count) clip = 0;  // a clip past the end reads clip 0
    return bank.clip_count ? bank.clips[clip] : (T5FaceClip){0};
}

uint16_t t5_face_clip_frames(T5FaceBank bank, uint16_t clip) { return clip_at(bank, clip).frame_count; }

// Frames before the start read the first, frames past the end the last.
static T5FacePose frame_pose(T5FaceClip clip, int32_t frame) {
    static const T5FaceKeys NONE;
    const T5FaceKeys *keys = &NONE;
    if (clip.keys) {
        if (frame < 0) frame = 0;
        if (frame + 1 >= clip.frame_count) frame = clip.frame_count - 1;
        keys = &clip.keys[frame];
    }
    T5FacePose pose;
    for (int channel = 0; channel < FACE_CHANNELS; channel++) {
        T5Vec4 key = {{(*keys)[channel][0], (*keys)[channel][1], (*keys)[channel][2], 1.0f}};
        if (T5_FACE_CHANNELS[channel].kind == FACE_TURN) t5_anim_key_turn(&pose.channel[channel], &key);
        else pose.channel[channel] = key;
    }
    return pose;
}

T5FacePose t5_face_pose_blend(T5FacePose from, T5FacePose to, float weight) {
    T5FacePose out;
    for (int channel = 0; channel < FACE_CHANNELS; channel++) {
        const T5Vec4 *first = &from.channel[channel], *second = &to.channel[channel];
        if (T5_FACE_CHANNELS[channel].kind == FACE_TURN) t5_quat_blend(&out.channel[channel], weight, first, second);
        else
            for (int axis = 0; axis < 4; axis++) out.channel[channel].v[axis] = first->v[axis] + (second->v[axis] - first->v[axis]) * weight;
    }
    return out;
}

T5FacePose t5_face_clip_sample(T5FaceBank bank, uint16_t clip, float time) {
    T5FaceClip played = clip_at(bank, clip);
    float whole;
    float weight = t5_modf(time, &whole);  // split time: fraction is the blend weight
    int32_t frame = t5_fctiwz(whole);
    T5FacePose pose = frame_pose(played, frame);
    if (!(weight >= BLEND_MIN)) return pose;  // no real blend: tiny or NaN weight
    return t5_face_pose_blend(pose, frame_pose(played, frame + 1), weight);
}

enum { FACE_BANKS = 2, FACE_OWNER_BYTES = T5_OWNER_BYTES + sizeof "/face_poses" };

static const T5ClipKind FACE_CLIPS = {sizeof(T5FaceClip), parse_face_clip, "face clips"};

static const char *face_owners(sqlite3 *db, const char *character, char owners[FACE_BANKS][FACE_OWNER_BYTES]) {
    char bank[T5_OWNER_BYTES];
    const char *failed = t5_own_anim_bank(db, character, bank);
    snprintf(owners[0], FACE_OWNER_BYTES, "%s/face_poses", character);
    snprintf(owners[1], FACE_OWNER_BYTES, "%s/face_clips", bank);
    return failed;
}

const char *t5_load_faces_storage(sqlite3 *db, const char *character, size_t *bytes) {
    char owners[FACE_BANKS][FACE_OWNER_BYTES];
    const char *failed = face_owners(db, character, owners);
    *bytes = 0;
    for (int bank = 0; bank < FACE_BANKS && !failed; bank++) {
        size_t bank_bytes;
        failed = t5_load_clips_storage(db, owners[bank], FACE_CLIPS, &bank_bytes);
        *bytes += bank_bytes;
    }
    return failed;
}

const char *t5_load_faces(T5FaceBanks *banks, sqlite3 *db, const char *character, T5ReadFile read, void *context, T5Arena *arena) {
    char owners[FACE_BANKS][FACE_OWNER_BYTES];
    const char *failed = face_owners(db, character, owners);
    T5FaceBank *bank[FACE_BANKS] = {&banks->poses, &banks->clips};
    for (int index = 0; index < FACE_BANKS && !failed; index++)
        failed = t5_load_clips((void **)&bank[index]->clips, &bank[index]->clip_count, FACE_CLIPS, db, owners[index], read, context, arena);
    if (!failed && !banks->poses.clip_count) failed = "faces: no face poses";
    return failed;
}
