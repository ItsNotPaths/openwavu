// Hand banks: the finger clips of a character (clip banks, gamerender/clip_bank.h) and their sampler.
#ifndef T5_VISUAL_HAND_BANK_H
#define T5_VISUAL_HAND_BANK_H

#include <stdint.h>

#include "gamerender/clip_bank.h"

enum { FINGER_JOINTS = 15 };  // 5 fingers x 3 joints: thumb, index, middle, ring, little; root joint first
typedef enum : uint8_t { RIGHT_HAND, LEFT_HAND } T5HandSide;

// One local rotation per finger joint, as quaternions. They replace the bind rotation of the bone.
typedef struct { T5Vec4 joint[FINGER_JOINTS]; } T5FingerPose;

// The two banks of a character: the pose library (clip 0, frame i = pose i) and the gesture clips.
typedef struct { T5ClipBank poses, gestures; } T5HandBanks;

// The finger pose library and gestures of the character (owners <character>/hand_poses, <its anim bank>/hand_gestures).
const char *t5_load_hands(T5HandBanks *banks, sqlite3 *db, const char *character, T5ReadFile read, void *context);
void t5_free_hands(T5HandBanks *banks);

// Frame floor(time) and the next mixed by the fraction (shortest arc, not normalized). A clip past the end reads clip 0.
T5FingerPose t5_hand_clip_sample(const T5ClipBank *bank, uint16_t clip, float time, T5HandSide side);

#endif
