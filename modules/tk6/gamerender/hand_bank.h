// Hand banks: the finger clips from .anim files (layout tk5hand), loaded from the pack db, and their sampler.
// Views of caller-owned bytes.
#ifndef T6_VISUAL_HAND_BANK_H
#define T6_VISUAL_HAND_BANK_H

#include <stdbool.h>
#include <stdint.h>

#include "load.h"
#include "sim/anim.h"
#include "sim/memory.h"
#include "sim/vec.h"

enum { FINGER_JOINTS = 15 };  // 5 fingers x 3 joints: thumb, index, middle, ring, little; root joint first

// One local rotation per finger joint, as quaternions. They replace the bind rotation of the bone.
typedef struct { T6Vec4 joint[FINGER_JOINTS]; } T6FingerPose;

// Per frame, per joint: (axis pitch, axis yaw, angle) in radians.
typedef float T6HandKeys[FINGER_JOINTS][3];

typedef struct {
    uint16_t frame_count;
    const T6HandKeys *keys;  // NULL: no clip, every frame is zeros
} T6HandClip;

typedef struct {
    uint32_t clip_count;
    T6HandClip *clips;
} T6HandBank;

// The two banks of a character: the pose library (clip 0, frame i = pose i) and the gesture clips.
typedef struct { T6HandBank poses, gestures; } T6HandBanks;

static inline T6KeyKind t6_hand_joint_kind(int32_t joint) { return (void)joint, T6_KEY_AXIS_ANGLE; }

// The clip points into `file`; 0 on success.
static inline int t6_hand_clip_parse(T6HandClip *clip, T6Bytes file) {
    const float *keys;
    uint16_t frames = t6_anim_file(file, "tk5hand", FINGER_JOINTS, t6_hand_joint_kind, &keys);
    *clip = frames ? (T6HandClip){frames, (const T6HandKeys *)keys} : (T6HandClip){0};
    return frames ? 0 : -1;
}

// The finger pose library and gestures of the character (owners <character>/hand_poses, <its anim bank>/hand_gestures).
const char *t6_load_hands_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t6_load_hands takes
const char *t6_load_hands(T6HandBanks *banks, sqlite3 *db, const char *character, T6ReadFile read, void *context, T6Arena *arena);

uint16_t t6_hand_clip_frames(T6HandBank bank, uint16_t clip);  // frame count; a clip past the end reads clip 0
// Frame floor(time) and the next mixed by the fraction (shortest arc, not normalized). A clip past the end reads clip 0.
T6FingerPose t6_hand_clip_sample(T6HandBank bank, uint16_t clip, float time);

#endif
