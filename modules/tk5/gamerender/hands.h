// The finger animation of a fighter (code-map "Fingers"): two hand channels, the poses and gestures that moves and hits
// set on them, and the blend toward each new pose. Display only: reads the sim view, the sim never reads this.
#ifndef T5_VISUAL_HANDS_H
#define T5_VISUAL_HANDS_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/cue.h"
#include "sim/fighter.h"
#include "gamerender/hand_bank.h"

enum { HAND_POSES, HAND_GESTURES };

// What a hand plays: a pose of the library (bank HAND_POSES, clip 0, time = pose id) or a looping clip.
typedef struct {
    float time;             // pose id, or the clip frame
    uint8_t bank;           // HAND_POSES or HAND_GESTURES
    uint16_t clip;
    uint16_t blend_frames;  // frames left of the blend toward the new pose
} T5HandChannel;

typedef struct {
    T5HandChannel channel;  // the channel the hand is set to play now
    T5HandChannel sampled;  // the channel of the last sample: the same channel again keeps `pose`
    bool has_sample;  // false until the first sample
    T5FingerPose pose;      // the last sample, where the next blend starts
    T5PoseProp seen;        // the pose property of the last tick: a new one sets the channel
} T5Hand;

typedef struct {
    T5Hand right, left;
    bool clean_hit;  // of the last tick: the game opens the hands on the tick after the hit
} T5Hands;

// The idle hands at once (a reset, a round start).
T5Hands t5_hands_idle(T5Hands hands, T5HandBanks banks, const T5Fighter *f);
// One sim tick, after the sim step: the pose properties, the hit and wind-up poses, the channel clocks, the sample.
T5Hands t5_hands_tick(T5Hands hands, T5HandBanks banks, const T5World *w, const T5Fighter *f);

// The left hand plays the right hand's channel data mirrored; the mirror is its own inverse.
T5Vec4 t5_left_finger_turn(T5Vec4 turn, int32_t joint);

#endif
