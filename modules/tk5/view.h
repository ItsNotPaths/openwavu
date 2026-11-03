// The stock TK5 sim view: what the presenter (gamerender.wasm) reads of the last sim frame (ow_sim_view, ow_view).
// Plain data, no pointers, so it copies between modules as bytes.
#ifndef T5_VIEW_H
#define T5_VIEW_H

#include "loadout.h"
#include "sim/phase.h"
#include "sim/skel.h"
#include "sim/world.h"

enum { T5_VIEW_VERSION = 1 };

typedef struct {
    T5Loadout loadout;
    int32_t health, max_health;  // 16.16 fixed point
    int16_t wins;                // rounds won
    bool on_right;               // right of the opponent on screen
    T5Mat4 root;                 // the rig root's world matrix, mm; translation = base position
    T5Mat4 bones[T5_BONES_B];    // skeleton B world matrices, mm: the slots a model's bones follow
} T5ViewFighter;

typedef struct {
    uint32_t version;  // T5_VIEW_VERSION
    uint32_t frame;
    T5Phase phase;
    int32_t phase_frame;  // frames of the phase so far
    uint32_t round;       // rounds started
    int32_t timer;        // frames left on the round clock
    uint32_t wins_needed;
    char stage[T5_NAME_BYTES];  // the db stage id
    T5ViewFighter fighters[T5_FIGHTER_COUNT];
    float view_normal[2];  // xz direction from the fighters to the camera; screen sides follow it
    bool snap;             // a scene cut: the fighters jump, so the display must not blend into this frame
} T5View;

#endif
