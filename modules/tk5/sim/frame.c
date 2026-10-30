// The battle frame, normal fight branch. Pause, the flashback scene branch, the practice record/playback
// and the not-sim calls (camera, effects, models, HUD, voice) are left out. Passes without a port are empty until ported.
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

void t5_battle_frame(T5World *w) {
    const T5Hooks *hooks = &t5_hooks;
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
    if (t5_phase_reads_pads(w)) hooks->input(w);  // input pass runs only in phases that read pads
    hooks->decide(w);
    w->force = 0;  // the forced full update lasts one frame
}

static void side_latch(T5World *w) { t5_side_latch(&w->fighters[0]->input, &w->fighters[1]->input); }  // freeze both screen sides

static void side(T5World *w) {
    for (int fighter_index = 0; fighter_index < 2; fighter_index++)  // side comes from the host camera
        t5_side_update(&w->fighters[fighter_index]->input);
}

static void props_logic(T5World *w) { t5_props_pass(w, false, T5_PASS_LOGIC); }
static void props_effects(T5World *w) { t5_props_pass(w, false, T5_PASS_EFFECTS); }

const T5Hooks t5_default_hooks = {
    .frame = t5_battle_frame,
    .round = t5_round_flow,
    .side_latch = side_latch,
    .side = side,
    .hitbox_starts = t5_hitbox_starts_pass,
    .apply_moves = t5_apply_moves_pass,
    .clear_push = t5_clear_push_pass,
    .props_logic = props_logic,
    .distance = t5_distance_pass,
    .movement = t5_movement_pass,
    .save_root = t5_previous_root_pass,
    .motion = t5_motion_driver,
    .angles = t5_angles_pass,
    .root_matrix = t5_root_matrix_pass,
    .arena = t5_arena_pass,
    .props_effects = props_effects,
    .root_delta = t5_root_delta_pass,
    .hurtboxes = t5_hurtboxes_pass,
    .push_radii = t5_push_radii_pass,
    .push_solve = t5_push_pass,
    .hit_clear = t5_hit_records_pass,
    .hit_detect = t5_hit_detection_pass,
    .attack_direction = t5_attack_direction_pass,
    .reversals = t5_reversals_pass,
    .clear_results = t5_clear_results_pass,
    .damage = t5_damage_pass,
    .input = t5_input_pass,
    .decide = t5_decide_pass,
    .round_init = t5_round_init,
    .reset_models = t5_round_reset_models,
};

T5Hooks t5_hooks = t5_default_hooks;

