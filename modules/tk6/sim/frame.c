// The battle frame, normal fight branch. Pause, the flashback scene branch, the practice record/playback
// and the not-sim calls (camera, effects, models, HUD) are left out; voice clips leave as cues. Passes without a port
// are empty until ported.
#include "sim/frame.h"

#include "sim/collision.h"
#include "sim/damage.h"
#include "sim/decide.h"
#include "sim/fighter.h"
#include "sim/hit.h"
#include "sim/motion.h"
#include "sim/motion_driver.h"
#include "sim/move.h"
#include "sim/properties.h"
#include "sim/move_change.h"
#include "sim/requirements.h"
#include "sim/round.h"

void t6_battle_frame(T6World *w) {
    const T6Hooks *hooks = &t6_hooks;
    hooks->round(w);
    hooks->side_latch(w);
    if (w->frame != UINT32_MAX) w->frame++;  // count up, but never wrap back to 0
    hooks->side(w);
    hooks->hitbox_starts(w);
    hooks->apply_moves(w);
    hooks->clear_push(w);
    hooks->props_logic(w);
    hooks->distance(w);
    hooks->movement(w);
    hooks->save_root(w);
    hooks->motion(w);
    hooks->angles(w);
    hooks->root_matrix(w);
    hooks->arena(w);
    hooks->props_effects(w);
    hooks->root_delta(w);
    hooks->hurtboxes(w);
    hooks->push_radii(w);
    hooks->push_solve(w);
    hooks->hit_clear(w);
    hooks->hit_detect(w);
    hooks->attack_direction(w);
    hooks->reversals(w);
    hooks->clear_results(w);
    hooks->damage(w);
    if (t6_phase_reads_pads(w)) hooks->input(w);  // input pass runs only in phases that read pads
    hooks->decide(w);
    hooks->voice_clips(w);
    w->force = 0;  // the forced full update lasts one frame
}

static void side_latch(T6World *w) { t6_side_latch(&w->fighters[0]->input, &w->fighters[1]->input); }  // freeze both screen sides

static void side(T6World *w) {
    for (int fighter_index = 0; fighter_index < 2; fighter_index++)  // side comes from the host camera
        t6_side_update(&w->fighters[fighter_index]->input);
}

static void props_logic(T6World *w) { t6_props_pass(w, false, T6_PASS_LOGIC); }
static void props_effects(T6World *w) { t6_props_pass(w, false, T6_PASS_EFFECTS); }

const T6Hooks t6_default_hooks = {
    .frame = t6_battle_frame,
    .round = t6_round_flow,
    .side_latch = side_latch,
    .side = side,
    .hitbox_starts = t6_hitbox_starts_pass,
    .apply_moves = t6_apply_moves_pass,
    .clear_push = t6_clear_push_pass,
    .props_logic = props_logic,
    .distance = t6_distance_pass,
    .movement = t6_movement_pass,
    .save_root = t6_previous_root_pass,
    .motion = t6_motion_driver,
    .angles = t6_angles_pass,
    .root_matrix = t6_root_matrix_pass,
    .arena = t6_arena_pass,
    .props_effects = props_effects,
    .root_delta = t6_root_delta_pass,
    .hurtboxes = t6_hurtboxes_pass,
    .push_radii = t6_push_radii_pass,
    .push_solve = t6_push_pass,
    .hit_clear = t6_hit_records_pass,
    .hit_detect = t6_hit_detection_pass,
    .attack_direction = t6_attack_direction_pass,
    .reversals = t6_reversals_pass,
    .clear_results = t6_clear_results_pass,
    .damage = t6_damage_pass,
    .input = t6_input_pass,
    .decide = t6_decide_pass,
    .round_init = t6_round_init,
    .reset_models = t6_round_reset_models,
    .voice_clips = t6_voice_clips_pass,
};

T6Hooks t6_hooks = t6_default_hooks;

