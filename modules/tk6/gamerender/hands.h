// The finger animation of a fighter: two hand channels, the poses and gestures that moves and hits
// set on them, and the blend toward each new pose. Display only: reads the sim view, the sim never reads this.
#ifndef T6_VISUAL_HANDS_H
#define T6_VISUAL_HANDS_H

#include <stdbool.h>
#include <stdint.h>

#include "gamerender/hand_bank.h"
#include "view.h"

enum { HAND_POSES, HAND_GESTURES };

// What a hand plays: a pose of the library (bank HAND_POSES, clip 0, time = pose id) or a looping clip.
typedef struct {
    float time;             // pose id, or the clip frame
    uint8_t bank;           // HAND_POSES or HAND_GESTURES
    uint16_t clip;
    uint16_t blend_frames;  // frames left of the blend toward the new pose
} T6HandChannel;

typedef struct {
    T6HandChannel channel;  // the channel the hand is set to play now
    T6HandChannel sampled;  // the channel of the last sample: the same channel again keeps `pose`
    bool has_sample;  // false until the first sample
    T6FingerPose pose;      // the last sample, where the next blend starts
    T6PoseProp seen;        // the pose property of the last tick: a new one sets the channel
} T6Hand;

typedef struct {
    T6Hand right, left;
    bool clean_hit;  // of the last tick: the game opens the hands on the tick after the hit
} T6Hands;

// The idle hands at once (a reset, a round start).
T6Hands t6_hands_idle(T6Hands hands, T6HandBanks banks, const T6ViewHands *fighter);
// One sim tick, after the sim step: the pose properties, the hit and wind-up poses, the channel clocks, the sample.
T6Hands t6_hands_tick(T6Hands hands, T6HandBanks banks, const T6ViewHands *fighter);

// The left hand plays the right hand's channel data mirrored; the mirror is its own inverse.
T6Vec4 t6_left_finger_turn(T6Vec4 turn, int32_t joint);

#endif
