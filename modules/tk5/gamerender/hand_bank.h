// Hand banks: the finger clips from .anim files (layout tk5hand, data.md 6.5), loaded from the pack db, and their sampler.
// Views of caller-owned bytes.
#ifndef T5_VISUAL_HAND_BANK_H
#define T5_VISUAL_HAND_BANK_H

#include <stdbool.h>
#include <stdint.h>

#include "load.h"
#include "sim/anim.h"
#include "sim/memory.h"
#include "sim/vec.h"

enum { FINGER_JOINTS = 15 };  // 5 fingers x 3 joints: thumb, index, middle, ring, little; root joint first

// One local rotation per finger joint, as quaternions. They replace the bind rotation of the bone.
typedef struct { T5Vec4 joint[FINGER_JOINTS]; } T5FingerPose;

// Per frame, per joint: (axis pitch, axis yaw, angle) in radians.
typedef float T5HandKeys[FINGER_JOINTS][3];

typedef struct {
    uint16_t frame_count;
    const T5HandKeys *keys;  // NULL: no clip, every frame is zeros
} T5HandClip;

typedef struct {
    uint32_t clip_count;
    T5HandClip *clips;
} T5HandBank;

// The two banks of a character: the pose library (clip 0, frame i = pose i) and the gesture clips.
typedef struct { T5HandBank poses, gestures; } T5HandBanks;

static inline bool t5_hand_joint_is_rotation(int32_t joint) { return (void)joint, true; }

// The clip points into `file`; 0 on success.
static inline int t5_hand_clip_parse(T5HandClip *clip, T5Bytes file) {
    const float *keys;
    uint16_t frames = t5_anim_file(file, "tk5hand", FINGER_JOINTS, t5_hand_joint_is_rotation, &keys);
    *clip = frames ? (T5HandClip){frames, (const T5HandKeys *)keys} : (T5HandClip){0};
    return frames ? 0 : -1;
}

// The finger pose library and gestures of the character (owners <character>/hand_poses, <its anim bank>/hand_gestures).
const char *t5_load_hands_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t5_load_hands takes
const char *t5_load_hands(T5HandBanks *banks, sqlite3 *db, const char *character, T5ReadFile read, void *context, T5Arena *arena);

uint16_t t5_hand_clip_frames(T5HandBank bank, uint16_t clip);  // frame count; a clip past the end reads clip 0
// Frame floor(time) and the next mixed by the fraction (shortest arc, not normalized). A clip past the end reads clip 0.
T5FingerPose t5_hand_clip_sample(T5HandBank bank, uint16_t clip, float time);

#endif
