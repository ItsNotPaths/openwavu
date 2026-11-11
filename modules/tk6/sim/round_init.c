// The round init as a phase starts it (T6RoundSetup). Camera, HUD, sound, effects, scene objects and stats are left
// out; the Mokujin move set swap is the gameplay module's round_init hook. The world has no mobs and no extras.
#include "sim/round.h"

#include "sim/blend.h"
#include "sim/collision.h"
#include "sim/fighter.h"
#include "sim/frame.h"
#include "sim/look.h"
#include "sim/motion_driver.h"
#include "sim/rng.h"

enum { AI_DRAWS_SHORT = 128, AI_DRAWS_LONG = 48 };

// The clock, the result and the decided flag start again; the input goes neutral.
static void start_round(T6World *w) {
    w->round.timer = w->rules.round_time;
    w->round.decided = false;
    w->round.result = 0;
    t6_round_input_mode(w, T6_INPUT_NEUTRAL);
}

static void reset_ai(T6World *w) {  // the CPU AI blocks of both sides start again; each draws twice
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {  // loop through both sides
        w->fighters[side]->ai_engaged = 0;  // the AI stops driving this fighter
        t6_rand_n(&w->rng, AI_DRAWS_SHORT);  // draw a number and drop it, to move the rng on
        t6_rand_n(&w->rng, AI_DRAWS_LONG);
    }
}

void t6_round_reset_models(T6World *w) {
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {  // loop through both fighters
        T6Fighter *f = w->fighters[side];
        t6_motion_setup_fighter(w, f);  // set up the rig, limbs, look and scale
        t6_blend_reset(f);  // turn the blend off, take the current pose as the start
        t6_push_init(f);  // push spheres go to the base position
    }
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) t6_blend_reset(w->fighters[side]);  // blend off again for both
}

// for both, the focus fighter last. On the entrance point the other fighter moves.
static void reset_fighters(T6World *w, T6RoundSetup setup) {
    int focus = t6_round_focus(w, setup);
    T6Fighter *last = w->fighters[focus];  // the focus fighter, reset last
    T6Fighter *first = w->fighters[T6_FIGHTER_COUNT - 1 - focus];  // the other fighter, reset first
    t6_fighter_reset(w, first, last, setup);  // reset the other fighter, with the focus as opponent
    t6_fighter_reset(w, last, first, setup);  // reset the focus fighter, with the other as opponent
    if (setup.on_entrance_point) first->skip_motion = 0;  // on the entrance point the other fighter moves
}

void t6_round_init(T6World *w, T6RoundSetup setup) {
    w->rng.x = w->round_seed;  // the match rng restarts from the round seed
    w->frame = 0;
    t6_cue_clear(&w->cues);  // their frames would come round again
    w->scene_turn = 0;
    if (setup.counts_round) w->round.round++;  // a counted round adds one to the round number
    if (setup.new_round) start_round(w);  // new round: clock, result and input start again
    if (setup.nearest_start) t6_round_nearest_start(w);  // pick the start record nearest the fighters
    w->force = 1;  // force a full update this frame
    t6_hooks.reset_models(w);  // reset each fighter's model, blend and push
    t6_round_place(w, setup);  // put the fighters on their start spots
    t6_round_floor_origin(w);  // floor height at the fighters' middle
    reset_fighters(w, setup);
    t6_scene_cut(w, setup.cut);  // start the pose snap for this cut
    t6_hooks.arena(w);  // centre the arena between the fighters
    t6_hooks.apply_moves(w);  // tick the moves and start pending throws
    w->skip_apply_moves = 1;  // skip the next move pass
    if (setup.on_entrance_point) t6_round_turn(w);  // turn both fighters by the scene turn
    t6_hooks.motion(w);  // run the motion for the start pose
    reset_ai(w);
    if (setup.counts_round) t6_look_snap(w);  // a counted round snaps every look-at to its target
    t6_hooks.root_matrix(w);  // root matrices from the base positions
}
