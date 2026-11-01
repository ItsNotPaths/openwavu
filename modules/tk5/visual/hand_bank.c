#include "visual/hand_bank.h"

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
