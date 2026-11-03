#include "gamerender/hand_bank.h"

#include <stdio.h>

#include "sim/math.h"
#include "sim/quat.h"

static const float BLEND_MIN = 1e-5f;  // weights below this skip the blend

static T5HandClip clip_at(T5HandBank bank, uint16_t clip) {
    if (clip >= bank.clip_count) clip = 0;  // a clip past the end reads clip 0
    return bank.clips[clip];
}

uint16_t t5_hand_clip_frames(T5HandBank bank, uint16_t clip) { return clip_at(bank, clip).frame_count; }

// Frames before the start read the first, frames past the end the last.
static T5FingerPose frame_pose(T5HandClip clip, int32_t frame) {
    static const T5HandKeys NONE;
    const T5HandKeys *keys = &NONE;
    if (clip.keys) {
        if (frame < 0) frame = 0;
        if (frame + 1 >= clip.frame_count) frame = clip.frame_count - 1;
        keys = &clip.keys[frame];
    }
    T5FingerPose pose;
    for (int joint = 0; joint < FINGER_JOINTS; joint++) {
        T5Vec4 key = {{(*keys)[joint][0], (*keys)[joint][1], (*keys)[joint][2], 0.0f}};
        t5_anim_key_turn(&pose.joint[joint], &key);
    }
    return pose;
}

T5FingerPose t5_hand_clip_sample(T5HandBank bank, uint16_t clip, float time) {
    T5HandClip played = clip_at(bank, clip);
    float whole;
    float weight = t5_modf(time, &whole);  // split time: fraction is the blend weight
    int32_t frame = t5_fctiwz(whole);  // whole part is the frame
    T5FingerPose pose = frame_pose(played, frame);
    if (!(weight >= BLEND_MIN)) return pose;  // no real blend: tiny or NaN weight
    T5FingerPose next = frame_pose(played, frame + 1);
    for (int joint = 0; joint < FINGER_JOINTS; joint++)  // blend each joint toward the next frame
        t5_quat_blend(&pose.joint[joint], weight, &pose.joint[joint], &next.joint[joint]);
    return pose;
}

enum { HAND_BANKS = 2, HAND_OWNER_BYTES = T5_OWNER_BYTES + sizeof "/hand_gestures" };

static int parse_hand_clip(void *clip, T5Bytes file) { return t5_hand_clip_parse(clip, file); }

static const T5ClipKind HAND_CLIPS = {sizeof(T5HandClip), parse_hand_clip, "hand clips"};

static const char *hand_owners(sqlite3 *db, const char *character, char owners[HAND_BANKS][HAND_OWNER_BYTES]) {
    char bank[T5_OWNER_BYTES];
    const char *failed = t5_own_anim_bank(db, character, bank);
    snprintf(owners[0], HAND_OWNER_BYTES, "%s/hand_poses", character);
    snprintf(owners[1], HAND_OWNER_BYTES, "%s/hand_gestures", bank);
    return failed;
}

const char *t5_load_hands_storage(sqlite3 *db, const char *character, size_t *bytes) {
    char owners[HAND_BANKS][HAND_OWNER_BYTES];
    const char *failed = hand_owners(db, character, owners);
    *bytes = 0;
    for (int bank = 0; bank < HAND_BANKS && !failed; bank++) {
        size_t bank_bytes;
        failed = t5_load_clips_storage(db, owners[bank], HAND_CLIPS, &bank_bytes);
        *bytes += bank_bytes;
    }
    return failed;
}

const char *t5_load_hands(T5HandBanks *banks, sqlite3 *db, const char *character, T5ReadFile read, void *context, T5Arena *arena) {
    char owners[HAND_BANKS][HAND_OWNER_BYTES];
    const char *failed = hand_owners(db, character, owners);
    T5HandBank *bank[HAND_BANKS] = {&banks->poses, &banks->gestures};
    for (int k = 0; k < HAND_BANKS && !failed; k++)
        failed = t5_load_clips((void **)&bank[k]->clips, &bank[k]->clip_count, HAND_CLIPS, db, owners[k], read, context, arena);
    if (!failed && (!banks->poses.clip_count || !banks->gestures.clip_count)) failed = "hands: a bank has no clips";
    return failed;
}
