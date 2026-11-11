// The movement step of a fighter, its steps in game order, and the passes over the fighters.
// (hole port-move-face :tags (port tk5mod) :sev polish) the hand call and 0x303ac of the movement step are left out. 0x303ac is not the face (the face step is 0x2ff10, display only in gamerender/face.c): it steps the Jin and Devil Jin type 0x64 bank of slot 4 and the camera clip channel of slot 5 (properties 0x8153..0x8155); in game states 0x18 and 0x19 that camera channel sets marked_finished when its clip is within 33 frames of its end: left out, so the round flow waits end with the move length (decided 2026-10-12). The hand step's libc rand stays out of the sim: random results are non-sim (decided 2026-11-09). tekken 6 as well modules/tk6/sim/move.c
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
