// The movement step of a fighter, its steps in game order, and the passes over the fighters.
#include "sim/move.h"

#include "sim/decide.h"
#include "sim/facing.h"
#include "sim/fighter.h"
#include "sim/guard.h"
#include "sim/properties.h"
#include "sim/move_change.h"
#include "sim/projectile.h"
#include "sim/requirements.h"

void t6_move_step(T6World *w, T6Fighter *f) {
    const T6Fighter *opponent = t6_object(w, f->opponent);
    t6_move_motion(w, f);  // gravity, slides, pushes, turns and pushback
    t6_shots_step(w, f);
    t6_facing_step(w, f);
    t6_move_pivot(f);  // turn around the pivot bone, then count down the cancel lock
    t6_move_counters(w, f);  // tick timers, hitboxes, air window and move end
    t6_move_guard(w, f, opponent);  // pick the stance and guard mask
    t6_move_hit_timers(f, opponent);  // count down counter-hit and repeat timers
    t6_move_update_can_act(w, f);  // decide if the fighter can act this frame
    t6_move_update_skip(w, f);  // skip motion on frames the update divider does not hit
}

// The fighters do not move while frozen (the flashback).
void t6_movement_pass(T6World *w) {
    if (!t6_phase_frozen(w))
        for (int side = 0; side < T6_FIGHTER_COUNT; side++) t6_move_step(w, w->fighters[side]);
    t6_each_extra(w, t6_move_step);  // extras step even while frozen
}

// The gate fields are read after the calls: the move step sets update_divider and skip_motion.
void t6_first_frame_pass(T6World *w, T6PoseMotion pose) {
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        T6Fighter *f = w->fighters[side];
        T6Fighter *opponent = t6_object(w, f->opponent);
        int selected = t6_first_frame_select(w, f, opponent);
        if (selected == 1) {  // a move starts this frame: tick it, then step it
            t6_move_tick(w, f, opponent);
            t6_props_changed(w, f);
            t6_move_step(w, f);
        }
        if (selected == 0) continue;  // no move this frame: no pose
        if (f->force_update || (!f->skip_motion && f->update_divider != T6_UPDATE_INACTIVE))
            pose(w, f);  // set the pose when forced, or when motion is not skipped
    }
}
