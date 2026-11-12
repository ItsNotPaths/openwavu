#include "gamerender/hand_bank.h"

#include <stdio.h>

#include "sim/math.h"
#include "sim/quat.h"

enum { FIRST_FINGER_JOINT = 55 };  // glb joints 55..69 the right fingers, 70..84 the left

static const float BLEND_MIN = 1e-5f;  // weights below this skip the blend

static T5FingerPose frame_pose(const T5ClipBank *bank, uint16_t clip, int32_t frame, T5HandSide side) {
    T5FingerPose pose;
    for (int joint = 0; joint < FINGER_JOINTS; joint++) {
        int32_t track = t5_clip_track(bank, (uint16_t)(FIRST_FINGER_JOINT + side * FINGER_JOINTS + joint), CLIP_ROTATION);
        pose.joint[joint] = t5_clip_key(bank, clip, (uint32_t)track, frame);
    }
    return pose;
}

T5FingerPose t5_hand_clip_sample(const T5ClipBank *bank, uint16_t clip, float time, T5HandSide side) {
    float whole;
    float weight = t5_modf(time, &whole);  // split time: fraction is the blend weight
    int32_t frame = t5_fctiwz(whole);  // whole part is the frame
    T5FingerPose pose = frame_pose(bank, clip, frame, side);
    if (!(weight >= BLEND_MIN)) return pose;  // no real blend: tiny or NaN weight
    T5FingerPose next = frame_pose(bank, clip, frame + 1, side);
    for (int joint = 0; joint < FINGER_JOINTS; joint++)  // blend each joint toward the next frame
        t5_quat_blend(&pose.joint[joint], weight, &pose.joint[joint], &next.joint[joint]);
    return pose;
}

enum { HAND_OWNER_BYTES = T5_OWNER_BYTES + sizeof "/hand_gestures" };

const char *t5_load_hands(T5HandBanks *banks, sqlite3 *db, const char *character, T5ReadFile read, void *context) {
    char bank[T5_OWNER_BYTES], poses[HAND_OWNER_BYTES], gestures[HAND_OWNER_BYTES];
    *banks = (T5HandBanks){0};
    const char *failed = t5_own_anim_bank(db, character, bank);
    snprintf(poses, sizeof poses, "%s/hand_poses", character);
    snprintf(gestures, sizeof gestures, "%s/hand_gestures", bank);
    if (!failed) failed = t5_load_clip_bank(&banks->poses, db, poses, read, context);
    if (!failed) failed = t5_load_clip_bank(&banks->gestures, db, gestures, read, context);
    if (!failed && (!banks->poses.clip_count || !banks->gestures.clip_count)) failed = "hands: a bank has no clips";
    if (failed) t5_free_hands(banks);
    return failed;
}

void t5_free_hands(T5HandBanks *banks) {
    t5_free_clip_bank(&banks->poses);
    t5_free_clip_bank(&banks->gestures);
}
