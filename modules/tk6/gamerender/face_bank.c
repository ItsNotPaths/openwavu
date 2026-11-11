#include "gamerender/face_bank.h"

#include <stdio.h>

#include "sim/anim.h"
#include "sim/math.h"
#include "sim/quat.h"

static const float BLEND_MIN = 1e-5f;  // weights below this skip the blend

// The channels and the channel types of the face banks.
const T6FaceChannel T6_FACE_CHANNELS[FACE_CHANNELS] = {
    {81, FACE_TURN}, {81, FACE_MOVE}, {96, FACE_TURN}, {105, FACE_TURN}, {94, FACE_TURN}, {103, FACE_TURN},
    {97, FACE_MOVE}, {106, FACE_MOVE}, {95, FACE_MOVE}, {104, FACE_MOVE}, {93, FACE_MOVE}, {102, FACE_MOVE},
    {91, FACE_MOVE}, {100, FACE_MOVE}, {90, FACE_MOVE}, {99, FACE_MOVE}, {89, FACE_TURN}, {98, FACE_TURN},
    {89, FACE_MOVE}, {98, FACE_MOVE}, {88, FACE_TURN}, {92, FACE_TURN}, {101, FACE_TURN}, {88, FACE_MOVE},
    {92, FACE_MOVE}, {101, FACE_MOVE}, {83, FACE_TURN}, {85, FACE_TURN}, {83, FACE_MOVE}, {85, FACE_MOVE},
    {82, FACE_TURN}, {84, FACE_TURN}, {82, FACE_MOVE}, {84, FACE_MOVE}, {86, FACE_TURN}, {87, FACE_TURN},
    {86, FACE_SCALE}, {87, FACE_SCALE},
};

static T6KeyKind face_key_kind(int32_t channel) {
    static const T6KeyKind KEY_KINDS[] = {[FACE_TURN] = T6_KEY_AXIS_ANGLE, [FACE_MOVE] = T6_KEY_POSITION, [FACE_SCALE] = T6_KEY_VALUES};
    return KEY_KINDS[T6_FACE_CHANNELS[channel].kind];
}

static int parse_face_clip(void *clip, T6Bytes file) {
    const float *keys;
    uint16_t frames = t6_anim_file(file, "tk5face", FACE_CHANNELS, face_key_kind, &keys);
    *(T6FaceClip *)clip = frames ? (T6FaceClip){frames, (const T6FaceKeys *)keys} : (T6FaceClip){0};
    return frames ? 0 : -1;
}

static T6FaceClip clip_at(T6FaceBank bank, uint16_t clip) {
    if (clip >= bank.clip_count) clip = 0;  // a clip past the end reads clip 0
    return bank.clip_count ? bank.clips[clip] : (T6FaceClip){0};
}

uint16_t t6_face_clip_frames(T6FaceBank bank, uint16_t clip) { return clip_at(bank, clip).frame_count; }

// Frames before the start read the first, frames past the end the last.
static T6FacePose frame_pose(T6FaceClip clip, int32_t frame) {
    static const T6FaceKeys NONE;
    const T6FaceKeys *keys = &NONE;
    if (clip.keys) {
        if (frame < 0) frame = 0;
        if (frame + 1 >= clip.frame_count) frame = clip.frame_count - 1;
        keys = &clip.keys[frame];
    }
    T6FacePose pose;
    for (int channel = 0; channel < FACE_CHANNELS; channel++) {
        T6Vec4 key = {{(*keys)[channel][0], (*keys)[channel][1], (*keys)[channel][2], 1.0f}};
        if (T6_FACE_CHANNELS[channel].kind == FACE_TURN) t6_anim_key_turn(&pose.channel[channel], &key);
        else pose.channel[channel] = key;
    }
    return pose;
}

T6FacePose t6_face_pose_blend(T6FacePose from, T6FacePose to, float weight) {
    T6FacePose out;
    for (int channel = 0; channel < FACE_CHANNELS; channel++) {
        const T6Vec4 *first = &from.channel[channel], *second = &to.channel[channel];
        if (T6_FACE_CHANNELS[channel].kind == FACE_TURN) t6_quat_blend(&out.channel[channel], weight, first, second);
        else
            for (int axis = 0; axis < 4; axis++) out.channel[channel].v[axis] = first->v[axis] + (second->v[axis] - first->v[axis]) * weight;
    }
    return out;
}

T6FacePose t6_face_clip_sample(T6FaceBank bank, uint16_t clip, float time) {
    T6FaceClip played = clip_at(bank, clip);
    float whole;
    float weight = t6_modf(time, &whole);  // split time: fraction is the blend weight
    int32_t frame = t6_fctiwz(whole);
    T6FacePose pose = frame_pose(played, frame);
    if (!(weight >= BLEND_MIN)) return pose;  // no real blend: tiny or NaN weight
    return t6_face_pose_blend(pose, frame_pose(played, frame + 1), weight);
}

enum { FACE_BANKS = 2, FACE_OWNER_BYTES = T6_OWNER_BYTES + sizeof "/face_poses" };

static const T6ClipKind FACE_CLIPS = {sizeof(T6FaceClip), parse_face_clip, "face clips"};

static const char *face_owners(sqlite3 *db, const char *character, char owners[FACE_BANKS][FACE_OWNER_BYTES]) {
    char bank[T6_OWNER_BYTES];
    const char *failed = t6_own_anim_bank(db, character, bank);
    snprintf(owners[0], FACE_OWNER_BYTES, "%s/face_poses", character);
    snprintf(owners[1], FACE_OWNER_BYTES, "%s/face_clips", bank);
    return failed;
}

const char *t6_load_faces_storage(sqlite3 *db, const char *character, size_t *bytes) {
    char owners[FACE_BANKS][FACE_OWNER_BYTES];
    const char *failed = face_owners(db, character, owners);
    *bytes = 0;
    for (int bank = 0; bank < FACE_BANKS && !failed; bank++) {
        size_t bank_bytes;
        failed = t6_load_clips_storage(db, owners[bank], FACE_CLIPS, &bank_bytes);
        *bytes += bank_bytes;
    }
    return failed;
}

const char *t6_load_faces(T6FaceBanks *banks, sqlite3 *db, const char *character, T6ReadFile read, void *context, T6Arena *arena) {
    char owners[FACE_BANKS][FACE_OWNER_BYTES];
    const char *failed = face_owners(db, character, owners);
    T6FaceBank *bank[FACE_BANKS] = {&banks->poses, &banks->clips};
    for (int index = 0; index < FACE_BANKS && !failed; index++)
        failed = t6_load_clips((void **)&bank[index]->clips, &bank[index]->clip_count, FACE_CLIPS, db, owners[index], read, context, arena);
    if (!failed && !banks->poses.clip_count) failed = "faces: no face poses";
    return failed;
}
