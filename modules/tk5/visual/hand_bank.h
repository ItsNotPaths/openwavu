// Hand banks: the type 1 banks of the fingers (data.md 6.5) and their sampler. Read-only views of caller-owned bytes.
#ifndef T5_VISUAL_HAND_BANK_H
#define T5_VISUAL_HAND_BANK_H

#include <stdint.h>

#include "sim/memory.h"
#include "sim/vec.h"

enum { FINGER_JOINTS = 15 };  // 5 fingers x 3 joints: thumb, index, middle, ring, little; root joint first

// One local rotation per finger joint, as quaternions. They replace the bind rotation of the bone.
typedef struct { T5Vec4 joint[FINGER_JOINTS]; } T5FingerPose;

typedef struct {
    T5Bytes bytes;
    uint16_t clip_count;
} T5HandBank;

// The two banks of a character: the pose library (clip 0, frame i = pose i) and the gesture clips.
typedef struct { T5HandBank poses, gestures; } T5HandBanks;

// A .t5h file (tools/hands2bin.py). Returns 0 on success; the banks point into `file`.
int t5_hand_banks_parse(T5HandBanks *banks, T5Bytes file);

uint16_t t5_hand_clip_frames(T5HandBank bank, uint16_t clip);  // frame count; a clip past the end reads clip 0
// Frame floor(time) and the next mixed by the fraction (shortest arc, not normalized). A clip past the end reads clip 0.
T5FingerPose t5_hand_clip_sample(T5HandBank bank, uint16_t clip, float time);

#endif
