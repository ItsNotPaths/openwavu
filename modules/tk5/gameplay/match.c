// The stock TK5 gameplay module's match: the world setup, one battle frame per tick from two pads, and the view.
#include <math.h>
#include <string.h>

#include "gameplay/match.h"
#include "openwavu.h"
#include "sim/frame.h"
#include "sim/round.h"

// (hole round-events :tags tk5mod) the KO and the round end are not reported with ow_event, only the match end.

enum {
    MODE_VERSUS = 2,           // T5World.mode of a versus match
    BATTLE_FIGHT = 4,          // T5World.battle_state while fighting: every start move cancel (intros, win poses) asks for it
    START_HEALTH = 180 << 16,  // 16.16 fixed point; the stock match setup is not ported (hole round-match-setup)
};
static const float STAGE_DEPTH = 10000.0f;  // mm: past it the arena pass counts a fighter as out of range

T5MatchState t5_match;
static T5View view;

// The fields the passes read of a fresh fighter on a side (no position, no move: the round init places it).
static void fighter_init(T5World *w, T5Fighter *f, uint32_t side) {
    const T5SideData *picked = &t5_match_data.sides[side];
    T5FighterData *d = &t5_match_data.sides[side].data;
    w->data[side] = d;
    w->fighters[side] = f;
    t5_fighter_clear_refs(f);
    f->force_update = true;  // the move change sets update_divider -1, which would whiff every hit
    f->rig = d->bind;
    f->scale_base = d->skeleton.scale;
    f->data = f->moveset = (uint8_t)side;
    f->slot = (uint16_t)side;
    f->side_index = (int16_t)side;
    f->opponent = f->target = (int16_t)(1 - side);
    f->health = f->max_health = START_HEALTH;
    f->chara = picked->chara;
    f->chara_40 = picked->model;
    f->body = t5_motbin_body(&d->moves);
    f->body_points = t5_motbin_body_points(&d->moves);
    f->gaze = t5_motbin_gaze(&d->moves);
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
    w->rng.x = (uint32_t)seed;
    w->round_seed = (uint32_t)seed;
    w->reactions = (T5ReactionHooks){t5_reaction_list, w};
    w->limb_env.floor_origin = true;
    w->flow = &T5_STANDARD_MATCH;
    w->rules = T5_STANDARD_RULES;
    t5_hooks = t5_default_hooks;
    m->view_normal[0] = -1;  // the camera on -x: side 1, at -z, is on the left
    m->view_normal[1] = 0;
    t5_match_start(w);
}

// The camera stays on its side of the line between the fighters, so a fighter changes screen side only by crossing
// over. A fresh view (a round start) puts side 1 on the left.
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
    if (w->round.phase == T5_PHASE_OVER) ow_event(OW_EVENT_MATCH_END, side_of(w->round.winner), 0);
}

OW_EXPORT(ow_sim_state) void *ow_sim_state(void) { return &t5_match; }
OW_EXPORT(ow_sim_state_size) uint32_t ow_sim_state_size(void) { return sizeof t5_match; }

static T5ViewFighter view_fighter(uint32_t side) {
    const T5Fighter *f = &t5_match.fighters[side];
    T5ViewFighter out = {
        .loadout = t5_match_data.sides[side].loadout,
        .health = f->health,
        .max_health = f->max_health,
        .wins = f->wins,
        .on_right = f->input.camera_side == T5_SIDE_RIGHT,
        .root = f->rig.root.world,
    };
    for (int bone = 0; bone < T5_BONES_B; bone++) out.bones[bone] = f->rig.bones_b[bone].world;
    return out;
}

// Built when asked, from the state, so it is right after a restore too.
OW_EXPORT(ow_sim_view) const void *ow_sim_view(void) {
    const T5World *w = &t5_match.world;
    view = (T5View){
        .version = T5_VIEW_VERSION,
        .frame = w->frame,
        .phase = w->round.phase,
        .phase_frame = w->round.frame.ticks,
        .round = w->round.round,
        .timer = w->round.timer.ticks,
        .wins_needed = w->rules.wins_needed,
    };
    memcpy(view.stage, t5_match_data.stage_id, sizeof view.stage);
    for (uint32_t side = 0; side < T5_FIGHTER_COUNT; side++) view.fighters[side] = view_fighter(side);
    return &view;
}

OW_EXPORT(ow_sim_view_size) uint32_t ow_sim_view_size(void) { return sizeof view; }
