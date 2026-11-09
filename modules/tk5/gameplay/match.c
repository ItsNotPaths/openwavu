// The stock TK5 gameplay module's match: the world setup, one battle frame per tick from two pads, and the view.
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "gameplay/match.h"
#include "openwavu.h"
#include "sim/constants.h"
#include "sim/frame.h"
#include "sim/round.h"

enum {
    MODE_VERSUS = 2,           // T5World.mode of a versus match
    BATTLE_FIGHT = 4,          // T5World.battle_state while fighting: every start move cancel (intros, win poses) asks for it
    START_HEALTH = 180,        // health points; the start_health param's fallback
    FRAMES_PER_SECOND = 60,
};
static const float STAGE_DEPTH = 10000.0f;  // mm: past it the arena pass counts a fighter as out of range
static const int32_t STAGE_MODE_INFINITE = 2;  // the game's floor word on infinite stages (0x6abbc): no walls, flat floor

T5MatchState t5_match;
static T5View *view;  // on the heap: built from the state when asked, so it is no part of it

// The fields the passes read of a fresh fighter on a side (no position, no move: the round init places it).
static void fighter_init(T5World *w, T5Fighter *f, uint32_t side) {
    T5SideData *picked = &t5_match_data.sides[side];
    T5FighterData *data = &picked->data;
    w->data[side] = data;
    w->fighters[side] = f;
    t5_fighter_clear_refs(f);
    f->force_update = true;  // the move change sets update_divider -1, which would whiff every hit
    f->rig = data->bind;
    f->scale_base = data->skeleton.scale;
    f->data = f->moveset = (uint8_t)side;
    f->slot = (uint16_t)side;
    f->side_index = (int16_t)side;
    f->opponent = f->target = (int16_t)(1 - side);
    f->health = f->max_health = (int32_t)ow_param(OW_STR("start_health"), START_HEALTH) << 16;  // 16.16 fixed point
    f->chara = picked->chara;
    f->chara_40 = picked->model;
    f->body = t5_motbin_body(&data->moves);
    f->body_points = t5_motbin_body_points(&data->moves);
    f->gaze = t5_motbin_gaze(&data->moves);
    f->input.mode = T5_INPUT_LIVE;
    f->input.direction_held = T5_DIRECTION_N;
    f->base_position_w = 1.0f;
}

void t5_match_begin(uint64_t seed) {
    T5MatchState *m = &t5_match;
    T5World *w = &m->world;
    memset(m, 0, sizeof *m);
    for (uint32_t side = 0; side < T5_FIGHTER_COUNT; side++) fighter_init(w, &m->fighters[side], side);
    w->mode = MODE_VERSUS;
    w->battle_state = BATTLE_FIGHT;
    w->stage = &t5_match_data.stage;
    w->stage_depth = STAGE_DEPTH;
    w->floor_disabled = w->stage->infinite ? STAGE_MODE_INFINITE : 0;
    w->rng.x = (uint32_t)seed;
    w->round_seed = (uint32_t)seed;
    w->reactions = (T5ReactionHooks){t5_reaction_list, w};
    w->limb_env.floor_origin = true;
    w->flow = &T5_STANDARD_MATCH;
    w->rules = T5_STANDARD_RULES;
    w->rules.damage_scale = (T5Ratio){(int32_t)ow_param(OW_STR("damage_percent"), 100), 100};
    w->rules.pushback_scale = (T5Ratio){(int32_t)ow_param(OW_STR("pushback_percent"), 100), 100};
    w->rules.wins_needed = (uint32_t)ow_param(OW_STR("rounds_to_win"), DEFAULT_WINS_NEEDED);
    int32_t seconds = (int32_t)ow_param(OW_STR("round_time"), DEFAULT_ROUND_TIME.ticks / FRAMES_PER_SECOND);
    w->rules.untimed = seconds == 0;  // 0: no clock
    if (seconds > 0) w->rules.round_time = (T5Frames){seconds * FRAMES_PER_SECOND};
    t5_hooks = t5_default_hooks;
    m->view_normal[0] = -1;  // the camera on -x: side 1, at -z, is on the left
    m->view_normal[1] = 0;
    t5_match_start(w);
}

// The camera stays on its side of the line between the fighters, so a fighter changes screen side only by crossing
// over. A fresh view (a round start) puts side 1 on the left.
// (hole sim-side-switch :tags (tk5mod sim round-show) :needs side-switch-flags) a throw does not pick its camera row (by weight, with an RNG stream of its own so the stock rolls stay the game's) or show it in the view, and a flagged row does not switch the screen sides; only crossing over does.
static void update_sides(T5MatchState *m, bool fresh) {
    T5Vec3 a = m->fighters[0].base_position, b = m->fighters[1].base_position;
    float dx = b.x - a.x, dz = b.z - a.z, length = sqrtf(dx * dx + dz * dz);
    if (length > 1) {
        float nx = -dz / length, nz = dx / length;
        if (!fresh && nx * m->view_normal[0] + nz * m->view_normal[1] < 0) nx = -nx, nz = -nz;
        m->view_normal[0] = nx;
        m->view_normal[1] = nz;
    }
    float right[2] = {m->view_normal[1], -m->view_normal[0]};  // screen right on the floor
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        T5Vec3 me = m->fighters[side].base_position, other = m->fighters[1 - side].base_position;
        float along = (me.x - other.x) * right[0] + (me.z - other.z) * right[1];
        m->fighters[side].input.camera_side = along > 0 || (along == 0 && side == 1) ? T5_SIDE_RIGHT : T5_SIDE_LEFT;
    }
}

static int8_t axis(uint32_t pad, uint32_t plus, uint32_t minus) { return (int8_t)((pad & plus ? 1 : 0) - (pad & minus ? 1 : 0)); }

static T5StdInput standard_input(uint32_t pad) {
    T5ButtonSet held = (T5ButtonSet)(pad >> OW_PAD_BUTTON_SHIFT) & T5_BUTTONS_ALL;
    return (T5StdInput){axis(pad, OW_PAD_UP, OW_PAD_DOWN), axis(pad, OW_PAD_RIGHT, OW_PAD_LEFT), held};
}

static int32_t side_of(T5Who who) { return who == T5_SIDE_1 ? 0 : who == T5_SIDE_2 ? 1 : -1; }

static int8_t round_winner(const T5World *w) {
    if (w->round.result & T5_RESULT_DRAW) return -1;
    for (int8_t side = 0; side < T5_FIGHTER_COUNT; side++)
        if (t5_match.fighters[side].last_round == T5_ROUND_WON) return side;
    return -1;
}

// The fight just ended: who fell, then the round's winner.
static void report_round(const T5World *w) {
    T5RoundView fallen = t5_round_view(w);
    for (int32_t side = 0; side < T5_FIGHTER_COUNT; side++) if (fallen.fallen[side]) ow_event(OW_EVENT_KO, side, 0);
    ow_event(OW_EVENT_ROUND_END, round_winner(w), 0);
}

OW_EXPORT(ow_sim_step) void ow_sim_step(uint32_t pad0, uint32_t pad1) {
    T5MatchState *m = &t5_match;
    T5World *w = &m->world;
    uint32_t pads[T5_FIGHTER_COUNT] = {pad0, pad1};
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        m->fighters[side].standard_input = standard_input(pads[side]);
        m->fighters[side].menu_pressed = pads[side] & OW_PAD_START ? T5_MENU_START : 0;
    }
    T5Phase before = w->round.phase;
    update_sides(m, false);
    t5_hooks.frame(w);
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) m->fighters[side].menu_pressed = 0;
    if (w->round.phase == before) return;
    T5RoundSetup setup = t5_phase_row(w).setup;
    if (setup.runs && !setup.on_entrance_point) update_sides(m, true);
    if (w->round.phase == T5_PHASE_KO) report_round(w);
    if (w->round.phase == T5_PHASE_OVER) ow_event(OW_EVENT_MATCH_END, side_of(w->round.winner), 0);
}

// The state is the statics, from the start to the end of the data. The stack before them is empty between ticks; the
// heap after them holds load data, written only at init, the bots and the view.
extern uint8_t __global_base[], __data_end[];  // set by the linker
OW_EXPORT(ow_sim_state) void *ow_sim_state(void) { return __global_base; }
OW_EXPORT(ow_sim_state_size) uint32_t ow_sim_state_size(void) { return (uint32_t)(__data_end - __global_base); }

static void view_fighter(T5ViewFighter *out, uint32_t side) {
    const T5Fighter *f = &t5_match.fighters[side];
    out->loadout = t5_match_data.sides[side].loadout;
    out->health = f->health;
    out->max_health = f->max_health;
    out->wins = f->wins;
    out->on_right = f->input.camera_side == T5_SIDE_RIGHT;
}

// Intros are about their own fighter; the flashback and the win poses about the winner.
static int8_t focus_of(const T5World *w) {
    switch (w->round.phase) {
    case T5_PHASE_INTRO_1:
    case T5_PHASE_INTRO_2: return (int8_t)t5_round_focus(w, t5_phase_row(w).setup);
    case T5_PHASE_MATCH_END:
    case T5_PHASE_OVER: return (int8_t)side_of(w->round.winner);
    case T5_PHASE_FLASHBACK:
    case T5_PHASE_ROUND_END: return round_winner(w);
    default: return -1;
    }
}

const char *t5_view_begin(void) {
    view = malloc(sizeof *view);
    return view ? NULL : "out of memory for the view";
}

// Built when asked, from the state, so it is right after a restore too.
OW_EXPORT(ow_sim_view) const void *ow_sim_view(void) {
    const T5World *w = &t5_match.world;
    *view = (T5View){
        .version = T5_VIEW_VERSION,
        .phase = w->round.phase,
        .phase_frame = w->round.frame.ticks,
        .round = w->round.round,
        .timer = w->round.timer.ticks,
        .wins_needed = w->rules.wins_needed,
        .view_normal = {t5_match.view_normal[0], t5_match.view_normal[1]},
        .snap = w->blend_snap_left > 0,
        .focus = focus_of(w),
    };
    memcpy(view->stage, t5_match_data.stage_id, sizeof view->stage);
    t5_view_poses(view, w);
    for (uint32_t side = 0; side < T5_FIGHTER_COUNT; side++) view_fighter(&view->fighters[side], side);
    return view;
}

OW_EXPORT(ow_sim_view_size) uint32_t ow_sim_view_size(void) { return sizeof *view; }
