// The stock TK5 sim view: what the presenter (gamerender.wasm) reads of the last sim frame (ow_sim_view, ow_view).
// Plain data, no pointers, so it copies between modules as bytes.
#ifndef T5_VIEW_H
#define T5_VIEW_H

#include "loadout.h"
#include "sim/phase.h"
#include "sim/skel.h"
#include "sim/world.h"

enum { T5_VIEW_VERSION = 2 };

typedef struct {  // the fighter fields the presenter's hand poses read
    T5PoseProp right_pose, left_pose;  // the hand channel properties
    bool posable;          // a fighter kind: other kinds keep the sim's fingers
    bool posed;            // a property posed the hands in this move
    bool new_anim;         // the move change took another anim
    bool damaging;         // the move does damage
    bool clean_streak;     // in a clean-hit streak
    bool thrown;
    bool clean_hit;
    int32_t frames_to_active;  // the move's first active frame minus the move frame
    uint8_t hitbox_code;   // the move's first hitbox code; 0 = no move
} T5ViewHands;

typedef struct {
    T5Loadout loadout;
    int32_t health, max_health;  // 16.16 fixed point
    int16_t wins;                // rounds won
    bool on_right;               // right of the opponent on screen
    T5Rig rig;                   // mm; root translation = base position; B worlds are the slots a model's bones follow
    int8_t parent_a[T5_BONES_A]; // the skeleton's A parents, to rebuild posed bones
    T5ViewHands hands;
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

// The frame and each fighter's rig, A parents and hand block, from the world.
void t5_view_poses(T5View *view, const T5World *w);

#endif
