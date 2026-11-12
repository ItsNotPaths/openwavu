#include "gamerender/hand_bank.h"

#include <stdio.h>

#include "sim/math.h"
#include "sim/quat.h"

enum { FIRST_FINGER_JOINT = 76 };  // glb joints 76..90 the right fingers, 91..105 the left (BONE records 75..104)

static const float BLEND_MIN = 1e-5f;  // weights below this skip the blend

static T6FingerPose frame_pose(const T6ClipBank *bank, uint16_t clip, int32_t frame, T6HandSide side) {
    T6FingerPose pose;
    for (int joint = 0; joint < FINGER_JOINTS; joint++) {
        int32_t track = t6_clip_track(bank, (uint16_t)(FIRST_FINGER_JOINT + side * FINGER_JOINTS + joint), CLIP_ROTATION);
        pose.joint[joint] = t6_clip_key(bank, clip, (uint32_t)track, frame);
    }
    return pose;
}

T6FingerPose t6_hand_clip_sample(const T6ClipBank *bank, uint16_t clip, float time, T6HandSide side) {
    float whole;
    float weight = t6_modf(time, &whole);  // split time: fraction is the blend weight
    int32_t frame = t6_fctiwz(whole);  // whole part is the frame
    T6FingerPose pose = frame_pose(bank, clip, frame, side);
    if (!(weight >= BLEND_MIN)) return pose;  // no real blend: tiny or NaN weight
    T6FingerPose next = frame_pose(bank, clip, frame + 1, side);
    for (int joint = 0; joint < FINGER_JOINTS; joint++)  // blend each joint toward the next frame
        t6_quat_blend(&pose.joint[joint], weight, &pose.joint[joint], &next.joint[joint]);
    return pose;
}

enum { HAND_OWNER_BYTES = T6_OWNER_BYTES + sizeof "/hand_gestures" };

const char *t6_load_hands(T6HandBanks *banks, sqlite3 *db, const char *character, T6ReadFile read, void *context) {
    char bank[T6_OWNER_BYTES], poses[HAND_OWNER_BYTES], gestures[HAND_OWNER_BYTES];
    *banks = (T6HandBanks){0};
    const char *failed = t6_own_anim_bank(db, character, bank);
    snprintf(poses, sizeof poses, "%s/hand_poses", character);
    snprintf(gestures, sizeof gestures, "%s/hand_gestures", bank);
    if (!failed) failed = t6_load_clip_bank(&banks->poses, db, poses, read, context);
    if (!failed) failed = t6_load_clip_bank(&banks->gestures, db, gestures, read, context);
    if (!failed && (!banks->poses.clip_count || !banks->gestures.clip_count)) failed = "hands: a bank has no clips";
    if (failed) t6_free_hands(banks);
    return failed;
}

void t6_free_hands(T6HandBanks *banks) {
    t6_free_clip_bank(&banks->poses);
    t6_free_clip_bank(&banks->gestures);
}
