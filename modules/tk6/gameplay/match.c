// The stock TK6 gameplay module's match: the world setup, one battle frame per tick from two pads, and the view.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gameplay/match.h"
#include "openwavu.h"
#include "sim/constants.h"
#include "sim/frame.h"
#include "sim/round.h"

enum {
    MODE_VERSUS = 2,           // T6World.mode of a versus match
    BATTLE_FIGHT = 4,          // T6World.battle_state while fighting: every start move cancel (intros, win poses) asks for it
    START_HEALTH = 180,        // health points; the start_health param's fallback
    FRAMES_PER_SECOND = 60,
};
static const float STAGE_DEPTH = 10000.0f;  // mm: past it the arena pass counts a fighter as out of range
static const int32_t STAGE_MODE_INFINITE = 2;  // the game's floor word on infinite stages: no walls, flat floor

T6MatchState t6_match;
static T6View *view;  // on the heap: built from the state when asked, so it is no part of it

// Round 0 the first; the intros run the first round's.
static const T6Moveset *round_moveset(uint32_t side, uint32_t round) {
    return t6_match_data.sides[side].round_movesets[round < ROUNDS_MAX ? round : ROUNDS_MAX - 1];
}

// A fresh copy of the round's move set.
static void take_moveset(T6Fighter *f, uint32_t side, uint32_t round) {
    const T6Moveset *moveset = round_moveset(side, round);
    T6FighterData *data = &t6_match_data.sides[side].data;
    *data = moveset->data;
    f->chara = moveset->chara;
    f->body = t6_motbin_body(&data->moves);
    f->body_points = t6_motbin_body_points(&data->moves);
    f->gaze = t6_motbin_gaze(&data->moves);
}

// The fields the passes read of a fresh fighter on a side (no position, no move: the round init places it).
static void fighter_init(T6World *w, T6Fighter *f, uint32_t side) {
    T6SideData *picked = &t6_match_data.sides[side];
    T6FighterData *data = &picked->data;
    w->data[side] = data;
    w->fighters[side] = f;
    t6_fighter_clear_refs(f);
    take_moveset(f, side, 0);
    f->force_update = true;  // the move change sets update_divider -1, which would whiff every hit
    f->rig = data->bind;
    f->scale_base = data->skeleton.scale;
    f->data = f->moveset = (uint8_t)side;
    f->slot = (uint16_t)side;
    f->side_index = (int16_t)side;
    f->opponent = f->target = (int16_t)(1 - side);
    f->health = f->max_health = (int32_t)ow_param(OW_STR("start_health"), START_HEALTH) << 16;  // 16.16 fixed point
    f->chara_40 = picked->model;
    f->input.mode = T6_INPUT_LIVE;
    f->input.direction_held = T6_DIRECTION_N;
    f->base_position_w = 1.0f;
}

// A counted round starts on its move set when it is another than the last round's (Mokujin); the same one keeps the
// aliases properties set.
static void round_init(T6World *w, T6RoundSetup setup) {
    uint32_t round = w->round.round;  // the round about to be counted, 0 the first
    for (uint32_t side = 0; side < T6_FIGHTER_COUNT; side++)
        if (setup.counts_round && round > 0 && round_moveset(side, round) != round_moveset(side, round - 1))
            take_moveset(w->fighters[side], side, round);
    t6_default_hooks.round_init(w, setup);
}

void t6_match_begin(uint64_t seed) {
    T6MatchState *m = &t6_match;
    T6World *w = &m->world;
    memset(m, 0, sizeof *m);
    for (uint32_t side = 0; side < T6_FIGHTER_COUNT; side++) fighter_init(w, &m->fighters[side], side);
    w->mode = MODE_VERSUS;
    w->battle_state = BATTLE_FIGHT;
    w->stage = &t6_match_data.stage;
    w->stage_depth = STAGE_DEPTH;
    w->floor_disabled = w->stage->infinite ? STAGE_MODE_INFINITE : 0;
    w->rng.x = (uint32_t)seed;
    w->round_seed = (uint32_t)seed;
    w->reactions = (T6ReactionHooks){t6_reaction_list, w};
    w->limb_env.floor_origin = true;
    w->flow = &T6_STANDARD_MATCH;
    w->rules = T6_STANDARD_RULES;
    w->rules.damage_scale = (T6Ratio){(int32_t)ow_param(OW_STR("damage_percent"), 100), 100};
    w->rules.pushback_scale = (T6Ratio){(int32_t)ow_param(OW_STR("pushback_percent"), 100), 100};
    w->rules.clean_hit_bonus = (T6Ratio){(int32_t)ow_param(OW_STR("clean_hit_bonus_percent"), CLEAN_HIT_BONUS_PERCENT), 100};
    w->rules.rage_health = t6_health_points((int32_t)ow_param(OW_STR("rage_health"), RAGE_HEALTH_POINTS));
    w->rules.rage_bonus = (T6Ratio){(int32_t)ow_param(OW_STR("rage_bonus_percent"), RAGE_BONUS_PERCENT), 100};
    w->rules.bounds_per_combo = (int32_t)ow_param(OW_STR("bounds_per_combo"), BOUNDS_PER_COMBO);
    w->rules.wins_needed = (uint32_t)ow_param(OW_STR("rounds_to_win"), DEFAULT_WINS_NEEDED);
    int32_t seconds = (int32_t)ow_param(OW_STR("round_time"), DEFAULT_ROUND_TIME.ticks / FRAMES_PER_SECOND);
    w->rules.untimed = seconds == 0;  // 0: no clock
    if (seconds > 0) w->rules.round_time = (T6Frames){seconds * FRAMES_PER_SECOND};
    t6_hooks = t6_default_hooks;
    t6_hooks.round_init = round_init;
    t6_match_start(w);
}

static int8_t axis(uint32_t pad, uint32_t plus, uint32_t minus) { return (int8_t)((pad & plus ? 1 : 0) - (pad & minus ? 1 : 0)); }

static T6StdInput standard_input(uint32_t pad) {
    T6ButtonSet held = (T6ButtonSet)(pad >> OW_PAD_BUTTON_SHIFT) & T6_BUTTONS_ALL;
    return (T6StdInput){axis(pad, OW_PAD_UP, OW_PAD_DOWN), axis(pad, OW_PAD_RIGHT, OW_PAD_LEFT), held};
}

static int32_t side_of(T6Who who) { return who == T6_SIDE_1 ? 0 : who == T6_SIDE_2 ? 1 : -1; }

static int8_t round_winner(const T6World *w) {
    if (w->round.result & T6_RESULT_DRAW) return -1;
    for (int8_t side = 0; side < T6_FIGHTER_COUNT; side++)
        if (t6_match.fighters[side].last_round == T6_ROUND_WON) return side;
    return -1;
}

// The fight just ended: who fell, then the round's winner.
static void report_round(const T6World *w) {
    T6RoundView fallen = t6_round_view(w);
    for (int32_t side = 0; side < T6_FIGHTER_COUNT; side++) if (fallen.fallen[side]) ow_event(OW_EVENT_KO, side, 0);
    ow_event(OW_EVENT_ROUND_END, round_winner(w), 0);
}

#ifdef T6_TRACE
// One tab-separated line per frame on the log (build with SIM_TRACE=1): the round, then per side the pad, move and the
// hit fields. A header line comes first.
static void trace_frame(const T6World *w, const uint32_t pads[T6_FIGHTER_COUNT]) {
    static bool headed;
    char line[512];
    int length = 0;
    if (!headed) {
        headed = true;
        length = snprintf(line, sizeof line, "trace\tframe\tphase\tround");
        for (int side = 1; side <= T6_FIGHTER_COUNT; side++)
            length += snprintf(line + length, sizeof line - (size_t)length,
                               "\tpad%d\tmove%d\tmove_frame%d\tx%d\ty%d\tz%d\thealth%d\tstate%d\tstate_class%d\thit_level%d\tlanded%d\twhiffed%d\thit_lockout%d",
                               side, side, side, side, side, side, side, side, side, side, side, side, side);
        ow_log((OwStr){(uint32_t)length, line});
    }
    length = snprintf(line, sizeof line, "trace\t%u\t%d\t%u", w->frame, w->round.phase, w->round.round);
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        const T6Fighter *f = w->fighters[side];
        length += snprintf(line + length, sizeof line - (size_t)length, "\t%#x\t%d\t%d\t%.0f\t%.0f\t%.0f\t%d\t%#x\t%u\t%#x\t%u\t%u\t%d",
                           pads[side], f->move.index, f->frame, f->base_position.x, f->base_position.y, f->base_position.z,
                           f->health >> 16, f->state, f->state_class, f->hit_level, f->landed_this_move, f->whiffed, f->hit_lockout);
    }
    ow_log((OwStr){(uint32_t)length, line});
}
#endif

OW_EXPORT(ow_sim_step) void ow_sim_step(uint32_t pad0, uint32_t pad1) {
    T6MatchState *m = &t6_match;
    T6World *w = &m->world;
    uint32_t pads[T6_FIGHTER_COUNT] = {pad0, pad1};
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        m->fighters[side].standard_input = standard_input(pads[side]);
        m->fighters[side].menu_pressed = pads[side] & OW_PAD_START ? T6_MENU_START : 0;
        m->fighters[side].input.camera_side = pads[side] & OW_PAD_ON_RIGHT ? T6_SIDE_RIGHT : T6_SIDE_LEFT;
    }
    T6Phase before = w->round.phase;
    t6_hooks.frame(w);
#ifdef T6_TRACE
    trace_frame(w, pads);
#endif
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) m->fighters[side].menu_pressed = 0;
    if (w->round.phase == before) return;
    if (w->round.phase == T6_PHASE_KO) report_round(w);
    if (w->round.phase == T6_PHASE_OVER) ow_event(OW_EVENT_MATCH_END, side_of(w->round.winner), 0);
}

// The state is the statics, from the start to the end of the data. The stack before them is empty between ticks; the
// heap after them holds load data, written only at init, the bots and the view.
extern uint8_t __global_base[], __data_end[];  // set by the linker
OW_EXPORT(ow_sim_state) void *ow_sim_state(void) { return __global_base; }
OW_EXPORT(ow_sim_state_size) uint32_t ow_sim_state_size(void) { return (uint32_t)(__data_end - __global_base); }

static void view_fighter(T6ViewFighter *out, uint32_t side) {
    const T6Fighter *f = &t6_match.fighters[side];
    out->loadout = t6_match_data.sides[side].loadout;
    uint32_t round = t6_match.world.round.round;
    memcpy(out->moveset, round_moveset(side, round ? round - 1 : 0)->character, sizeof out->moveset);
    out->health = f->health;
    out->max_health = f->max_health;
    out->wins = f->wins;
}

// Intros are about their own fighter; the flashback and the win poses about the winner.
static int8_t focus_of(const T6World *w) {
    switch (w->round.phase) {
    case T6_PHASE_INTRO_1:
    case T6_PHASE_INTRO_2: return (int8_t)t6_round_focus(w, t6_phase_row(w).setup);
    case T6_PHASE_MATCH_END:
    case T6_PHASE_OVER: return (int8_t)side_of(w->round.winner);
    case T6_PHASE_FLASHBACK:
    case T6_PHASE_ROUND_END: return round_winner(w);
    default: return -1;
    }
}

const char *t6_view_begin(void) {
    view = malloc(sizeof *view);
    return view ? NULL : "out of memory for the view";
}

// Built when asked, from the state, so it is right after a restore too.
OW_EXPORT(ow_sim_view) const void *ow_sim_view(void) {
    const T6World *w = &t6_match.world;
    *view = (T6View){
        .version = T6_VIEW_VERSION,
        .phase = w->round.phase,
        .phase_frame = w->round.frame.ticks,
        .round = w->round.round,
        .timer = w->round.timer.ticks,
        .wins_needed = w->rules.wins_needed,
        .snap = w->blend_snap_left > 0,
        .focus = focus_of(w),
    };
    memcpy(view->stage, t6_match_data.stage_id, sizeof view->stage);
    t6_view_poses(view, w);
    for (uint32_t side = 0; side < T6_FIGHTER_COUNT; side++) view_fighter(&view->fighters[side], side);
    return view;
}

OW_EXPORT(ow_sim_view_size) uint32_t ow_sim_view_size(void) { return sizeof *view; }
