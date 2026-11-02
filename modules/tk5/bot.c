// Stock TK5 bot: a pad source, like a player pressing buttons. It sees what a player sees on screen, plans a few frames
// of keys, and picks attacks made by one press from the standing idle's cancel list. Its state is outside the snapshot.
#include <math.h>

#include "bot.h"
#include "match.h"
#include "openwavu.h"

typedef struct {
    int32_t think_interval;              // frames a plan lasts at least
    int32_t reaction_min, reaction_max;  // frames from seeing an attack to the block
    int32_t block_frames;                // how long a block is held
    float block_chance, crouch_block_chance;
    float aggression;                    // chance to attack in range
    float throw_chance;                  // chance to throw when close
    float dash_chance;                   // far: dash instead of walk
    float backdash_chance;
    float step_chance;                   // otherwise: step in, else wait
    float far_distance, close_distance;  // mm
} BotTuning;

static const BotTuning TUNING = {
    .think_interval = 20,
    .reaction_min = 8,
    .reaction_max = 20,
    .block_frames = 24,
    .block_chance = 0.5f,
    .crouch_block_chance = 0.3f,
    .aggression = 0.6f,
    .throw_chance = 0.15f,
    .dash_chance = 0.4f,
    .backdash_chance = 0.1f,
    .step_chance = 0.5f,
    .far_distance = 1400,
    .close_distance = 1100,
};

enum {
    DIRECTION_BITS = 0x3fe,  // numpad bits 1..9
    PRESS_FRAMES = 2,
    TAP_FRAMES = 1,
    SUMMARY_BITS = 0xc000,  // whole-word tests, not a press (any press, hold after press)
    MOVES_MAX = 128,
    PLAN_MAX = 64,
    NEUTRAL_KEY = 5,  // numpad 5: no direction
};

static const T5ButtonSet THROWS[] = {T5_BUTTON_1 | T5_BUTTON_3, T5_BUTTON_2 | T5_BUTTON_4};

// What a player of one side sees on screen.
typedef struct {
    float distance;      // mm between the fighters
    bool on_right;       // own screen side
    bool opp_attacking;  // the opponent's move is in its startup or hit frames
    bool fighting;       // the round is live
} BotView;

// One frame of keys, the direction relative to the opponent.
typedef struct {
    int8_t forward, vertical;  // -1, 0, +1
    T5ButtonSet buttons;
} BotKey;

typedef struct {
    uint16_t directions;  // command direction bits (numpad bit n), 0: any
    T5ButtonSet buttons;
} BotMove;

typedef struct {
    uint32_t rng;
    BotMove moves[MOVES_MAX];
    int32_t move_count;
    BotKey plan[PLAN_MAX];
    int32_t plan_length, plan_at;
    bool saw_attack;
    int32_t react_in;  // frames until the block decision, 0: none pending
} Bot;

static Bot bots[T5_FIGHTER_COUNT];

static uint32_t next(Bot *b) {  // xorshift32
    b->rng ^= b->rng << 13;
    b->rng ^= b->rng >> 17;
    b->rng ^= b->rng << 5;
    return b->rng;
}

static int32_t pick(Bot *b, int32_t n) { return (int32_t)(next(b) % (uint32_t)n); }
static bool chance(Bot *b, float p) { return (float)(next(b) % 10000) < p * 10000; }
static int32_t between(Bot *b, int32_t low, int32_t high) { return low + pick(b, high - low + 1); }

// --- the move list

static int32_t move_index(const T5Motbin *motbin, uint16_t id) {
    return id & T5_ALIAS_BASE ? (int32_t)motbin->aliases[id & ~T5_ALIAS_BASE] : id;
}

static bool attacks(const T5Motbin *motbin, uint16_t id) {
    int32_t index = move_index(motbin, id);
    return index >= 0 && index < motbin->move_count && motbin->moves[index].first_active > 0;
}

// A direction and buttons pressed together; no sequence, no special input.
static bool one_press(const T5Cancel *entry) {
    T5Command command = entry->command;
    T5ButtonSet press = t5_buttons_pressed(command.buttons), held = t5_buttons_held(command.buttons);
    return command.code < T5_CANCEL_END && !(command.code & ~(DIRECTION_BITS | T5_DIRECTION_NEW_PRESS))
        && !(command.buttons & SUMMARY_BITS) && !(entry->option & (T5_OPTION_NO_INPUT | T5_OPTION_REVERSAL)) && press
        && !(held & ~press) && !(t5_buttons_not_held(command.buttons) & press);
}

static void add_move(Bot *b, BotMove move) {
    for (int32_t i = 0; i < b->move_count; i++)
        if (b->moves[i].directions == move.directions && b->moves[i].buttons == move.buttons) return;
    if (b->move_count < MOVES_MAX) b->moves[b->move_count++] = move;
}

static void scan(Bot *b, const T5Motbin *motbin, const T5Cancel *entry) {
    for (; entry->command.code != T5_CANCEL_END && entry->command.code != T5_CANCEL_GROUP_END; entry++) {
        if (entry->command.code == T5_CANCEL_GROUP) scan(b, motbin, &motbin->group_cancels[entry->move]);
        else if (one_press(entry) && attacks(motbin, entry->move))
            add_move(b, (BotMove){entry->command.code & DIRECTION_BITS, t5_buttons_pressed(entry->command.buttons)});
    }
}

void t5_bots_begin(uint64_t seed) {
    for (uint32_t side = 0; side < T5_FIGHTER_COUNT; side++) {
        Bot *b = &bots[side];
        const T5Motbin *motbin = &t5_match_data.data[side].moves;
        *b = (Bot){.rng = (uint32_t)(seed * 2 + side + 1)};  // never 0: xorshift would stay 0
        const T5Move *idle = &motbin->moves[move_index(motbin, T5_ALIAS_IDLE_STAND)];
        scan(b, motbin, &motbin->cancels[idle->cancels]);
    }
}

// --- plans: a few frames of keys, then a new decision

static void push(Bot *b, int forward, int vertical, T5ButtonSet buttons, int32_t frames) {
    for (; frames > 0 && b->plan_length < PLAN_MAX; frames--) b->plan[b->plan_length++] = (BotKey){(int8_t)forward, (int8_t)vertical, buttons};
}

static void plan_reset(Bot *b) { b->plan_length = b->plan_at = 0; }
static void wait_out(Bot *b) { push(b, 0, 0, 0, TUNING.think_interval - b->plan_length); }

static void dash(Bot *b, int forward) {
    push(b, forward, 0, 0, TAP_FRAMES);
    push(b, 0, 0, 0, TAP_FRAMES);
    push(b, forward, 0, 0, forward > 0 ? TUNING.think_interval : TAP_FRAMES);
}

static void attack(Bot *b) {
    if (b->move_count == 0) return;
    BotMove move = b->moves[pick(b, b->move_count)];
    int32_t key = NEUTRAL_KEY;  // any direction goes
    if (move.directions) do key = between(b, 1, 9); while (!(move.directions & 1u << key));
    push(b, 0, 0, 0, TAP_FRAMES);  // a fresh direction press
    push(b, (key - 1) % 3 - 1, (key - 1) / 3 - 1, move.buttons, PRESS_FRAMES);
}

static void block(Bot *b) {
    plan_reset(b);
    push(b, -1, chance(b, TUNING.crouch_block_chance) ? -1 : 0, 0, TUNING.block_frames);
}

static void think(Bot *b, BotView v) {
    plan_reset(b);
    if (v.distance > TUNING.far_distance) {
        if (chance(b, TUNING.dash_chance)) dash(b, 1);
        else push(b, 1, 0, 0, TUNING.think_interval);
    } else if (v.distance < TUNING.close_distance && chance(b, TUNING.throw_chance)) {
        push(b, 0, 0, 0, TAP_FRAMES);
        push(b, 0, 0, THROWS[pick(b, 2)], PRESS_FRAMES);
    } else if (chance(b, TUNING.aggression)) {
        attack(b);
    } else if (chance(b, TUNING.backdash_chance)) {
        dash(b, -1);
    } else if (chance(b, TUNING.step_chance)) {
        push(b, 1, 0, 0, TUNING.think_interval);  // step in
    }
    wait_out(b);
}

static BotKey bot_key(Bot *b, BotView v) {
    if (!v.fighting) {
        plan_reset(b);
        b->saw_attack = false;
        b->react_in = 0;
        return (BotKey){};
    }
    if (v.opp_attacking && !b->saw_attack) b->react_in = between(b, TUNING.reaction_min, TUNING.reaction_max);
    b->saw_attack = v.opp_attacking;
    if (b->react_in > 0 && --b->react_in == 0 && chance(b, TUNING.block_chance)) block(b);
    if (b->plan_at >= b->plan_length) think(b, v);
    return b->plan[b->plan_at++];
}

// --- what the bot sees, and its keys as a pad word

static bool attacking(const T5World *w, const T5Fighter *f) {
    const T5Move *move = t5_move_at(w, f->move);
    return move && move->first_active > 0 && f->frame <= move->last_active;
}

static BotView bot_view(uint32_t side) {
    const T5World *w = &t5_match.world;
    const T5Fighter *me = &t5_match.fighters[side], *opponent = &t5_match.fighters[1 - side];
    float dx = opponent->base_position.x - me->base_position.x, dz = opponent->base_position.z - me->base_position.z;
    return (BotView){
        .distance = sqrtf(dx * dx + dz * dz),
        .on_right = me->input.camera_side == T5_SIDE_RIGHT,
        .opp_attacking = attacking(w, opponent),
        .fighting = w->round.phase == T5_PHASE_FIGHT,
    };
}

static uint32_t pad_word(BotKey key, bool on_right) {
    int horizontal = on_right ? -key.forward : key.forward;
    uint32_t pad = (uint32_t)key.buttons << OW_PAD_BUTTON_SHIFT;
    if (key.vertical > 0) pad |= OW_PAD_UP;
    if (key.vertical < 0) pad |= OW_PAD_DOWN;
    if (horizontal > 0) pad |= OW_PAD_RIGHT;
    if (horizontal < 0) pad |= OW_PAD_LEFT;
    return pad;
}

OW_EXPORT(ow_bot_pad) uint32_t ow_bot_pad(uint32_t side) {
    if (side >= T5_FIGHTER_COUNT) return 0;
    BotView v = bot_view(side);
    return pad_word(bot_key(&bots[side], v), v.on_right);
}
