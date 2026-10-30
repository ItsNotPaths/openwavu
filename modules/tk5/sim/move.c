// The movement step of a fighter, its steps in game order, and the passes over the fighters.
// (hole port-move-face :tags (port tk5mod) :sev gap) the face and hand calls of the movement step are left out; the face step sets marked_finished to 1 only when the face clip's speed word reaches the length of a face clip minus 4 (a clip of at most 5 frames): left out, so the round flow waits end with the move length (decided 2026-10-12), and the hand step advances the libc rand.
#include "sim/move.h"

#include "sim/decide.h"
#include "sim/facing.h"
#include "sim/fighter.h"
#include "sim/guard.h"
#include "sim/properties.h"
#include "sim/move_change.h"
#include "sim/projectile.h"
#include "sim/requirements.h"

void t5_move_step(T5World *w, T5Fighter *f) {
    const T5Fighter *opponent = t5_object(w, f->opponent);
    t5_move_motion(w, f);  // gravity, slides, pushes, turns and pushback
    t5_shots_step(w, f);
    t5_facing_step(w, f);
    t5_move_pivot(f);  // turn around the pivot bone, then count down the cancel lock
    t5_move_counters(w, f);  // tick timers, hitboxes, air window and move end
    t5_move_guard(w, f, opponent);  // pick the stance and guard mask
    t5_move_hit_timers(f, opponent);  // count down counter-hit and repeat timers
    t5_move_update_can_act(w, f);  // decide if the fighter can act this frame
    t5_move_update_skip(w, f);  // skip motion on frames the update divider does not hit
}

// The fighters do not move while frozen (the flashback).
void t5_movement_pass(T5World *w) {
    if (!t5_phase_frozen(w))
        for (int side = 0; side < T5_FIGHTER_COUNT; side++) t5_move_step(w, w->fighters[side]);
    t5_each_extra(w, t5_move_step);  // extras step even while frozen
}

// The gate fields are read after the calls: the move step sets update_divider and skip_motion.
void t5_first_frame_pass(T5World *w, T5PoseMotion pose) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        T5Fighter *f = w->fighters[side];
        T5Fighter *opponent = t5_object(w, f->opponent);
        int selected = t5_first_frame_select(w, f, opponent);
        if (selected == 1) {  // a move starts this frame: tick it, then step it
            t5_move_tick(w, f, opponent);
            t5_props_changed(w, f);
            t5_move_step(w, f);
        }
        if (selected == 0) continue;  // no move this frame: no pose
        if (f->force_update || (!f->skip_motion && f->update_divider != T5_UPDATE_INACTIVE))
            pose(w, f);  // set the pose when forced, or when motion is not skipped
    }
}
