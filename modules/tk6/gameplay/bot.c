// Stock TK6 bot: a pad source, like a player pressing buttons. It sees what a player sees on screen, plans a few frames
// of keys, and picks attacks made by one press from the standing idle's cancel list. Its state is outside the snapshot.
#include <math.h>
#include <stdlib.h>

#include "gameplay/bot.h"
#include "gameplay/match.h"
#include "openwavu.h"
#include "sim/rng.h"

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

static const T6ButtonSet THROWS[] = {T6_BUTTON_1 | T6_BUTTON_3, T6_BUTTON_2 | T6_BUTTON_4};

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
    T6ButtonSet buttons;
} BotKey;

typedef struct {
    uint16_t directions;  // command direction bits (numpad bit n), 0: any
    T6ButtonSet buttons;
} BotMove;

typedef struct {
    T6Rng rng;
    BotMove moves[MOVES_MAX];
    int32_t move_count;
    BotKey plan[PLAN_MAX];
    int32_t plan_length, plan_at;
    bool saw_attack;
    int32_t react_in;  // frames until the block decision, 0: none pending
} Bot;

static Bot *bots;  // on the heap: the bot is outside the snapshot, and only the machine that runs it has it

enum { CHANCE_STEPS = 10000 };

static int32_t pick(Bot *bot, int32_t count) { return t6_rand_n(&bot->rng, count); }
static bool chance(Bot *bot, float probability) { return (float)t6_rand_n(&bot->rng, CHANCE_STEPS) < probability * CHANCE_STEPS; }
static int32_t between(Bot *bot, int32_t low, int32_t high) { return low + pick(bot, high - low + 1); }

// --- the move list

static int32_t move_index(const T6Motbin *motbin, uint16_t id) {
    return id & T6_ALIAS_BASE ? (int32_t)motbin->aliases[id & ~T6_ALIAS_BASE] : id;
}

static bool attacks(const T6Motbin *motbin, uint16_t id) {
    int32_t index = move_index(motbin, id);
    return index >= 0 && index < motbin->move_count && motbin->moves[index].first_active > 0;
}

// A direction and buttons pressed together; no sequence, no special input.
static bool one_press(const T6Cancel *entry) {
    T6Command command = entry->command;
    T6ButtonSet press = t6_buttons_pressed(command.buttons), held = t6_buttons_held(command.buttons);
    bool plain_direction = command.code < T6_CANCEL_END && !(command.code & ~(DIRECTION_BITS | T6_DIRECTION_NEW_PRESS));
    bool plain_buttons = press && !(command.buttons & SUMMARY_BITS) && !(held & ~press) && !(t6_buttons_not_held(command.buttons) & press);
    bool takes_input = !(entry->option & (T6_OPTION_NO_INPUT | T6_OPTION_REVERSAL));
    return plain_direction && plain_buttons && takes_input;
}

static void add_move(Bot *bot, BotMove move) {
    for (int32_t index = 0; index < bot->move_count; index++)
        if (bot->moves[index].directions == move.directions && bot->moves[index].buttons == move.buttons) return;
    if (bot->move_count < MOVES_MAX) bot->moves[bot->move_count++] = move;
}

static void scan(Bot *bot, const T6Motbin *motbin, const T6Cancel *entry) {
    for (; entry->command.code != T6_CANCEL_END && entry->command.code != T6_CANCEL_GROUP_END; entry++) {
        if (entry->command.code == T6_CANCEL_GROUP) scan(bot, motbin, &motbin->group_cancels[entry->move]);
        else if (one_press(entry) && attacks(motbin, entry->move))
            add_move(bot, (BotMove){entry->command.code & DIRECTION_BITS, t6_buttons_pressed(entry->command.buttons)});
    }
}

const char *t6_bots_begin(uint64_t seed) {
    bots = calloc(T6_FIGHTER_COUNT, sizeof *bots);
    if (!bots) return "out of memory for the bots";
    for (uint32_t side = 0; side < T6_FIGHTER_COUNT; side++) {
        Bot *bot = &bots[side];
        const T6Motbin *motbin = &t6_match_data.sides[side].data.moves;
        *bot = (Bot){.rng = {(uint32_t)(seed >> 32) + side}};  // the world rng takes the low half
        const T6Move *idle = &motbin->moves[move_index(motbin, T6_ALIAS_IDLE_STAND)];
        scan(bot, motbin, &motbin->cancels[idle->cancels]);
    }
    return NULL;
}

// --- plans: a few frames of keys, then a new decision

static void push(Bot *bot, int forward, int vertical, T6ButtonSet buttons, int32_t frames) {
    for (; frames > 0 && bot->plan_length < PLAN_MAX; frames--) bot->plan[bot->plan_length++] = (BotKey){(int8_t)forward, (int8_t)vertical, buttons};
}

// Numpad key 1..9 held for frames: 1 is down-back, 5 neutral, 9 up-forward.
static void push_key(Bot *bot, int32_t key, T6ButtonSet buttons, int32_t frames) {
    push(bot, (key - 1) % 3 - 1, (key - 1) / 3 - 1, buttons, frames);
}

static void plan_reset(Bot *bot) { bot->plan_length = bot->plan_at = 0; }
static void wait_out(Bot *bot) { push(bot, 0, 0, 0, TUNING.think_interval - bot->plan_length); }

static void dash(Bot *bot, int forward) {
    push(bot, forward, 0, 0, TAP_FRAMES);
    push(bot, 0, 0, 0, TAP_FRAMES);
    push(bot, forward, 0, 0, forward > 0 ? TUNING.think_interval : TAP_FRAMES);
}

static void attack(Bot *bot) {
    if (bot->move_count == 0) return;
    BotMove move = bot->moves[pick(bot, bot->move_count)];
    int32_t key = NEUTRAL_KEY;  // any direction goes
    if (move.directions) do key = between(bot, 1, 9); while (!(move.directions & 1u << key));
    push(bot, 0, 0, 0, TAP_FRAMES);  // a fresh direction press
    push_key(bot, key, move.buttons, PRESS_FRAMES);
}

static void block(Bot *bot) {
    plan_reset(bot);
    push(bot, -1, chance(bot, TUNING.crouch_block_chance) ? -1 : 0, 0, TUNING.block_frames);
}

static void think(Bot *bot, BotView view) {
    plan_reset(bot);
    if (view.distance > TUNING.far_distance) {
        if (chance(bot, TUNING.dash_chance)) dash(bot, 1);
        else push(bot, 1, 0, 0, TUNING.think_interval);
    } else if (view.distance < TUNING.close_distance && chance(bot, TUNING.throw_chance)) {
        push(bot, 0, 0, 0, TAP_FRAMES);
        push(bot, 0, 0, THROWS[pick(bot, 2)], PRESS_FRAMES);
    } else if (chance(bot, TUNING.aggression)) {
        attack(bot);
    } else if (chance(bot, TUNING.backdash_chance)) {
        dash(bot, -1);
    } else if (chance(bot, TUNING.step_chance)) {
        push(bot, 1, 0, 0, TUNING.think_interval);  // step in
    }
    wait_out(bot);
}

static BotKey bot_key(Bot *bot, BotView view) {
    if (!view.fighting) {
        plan_reset(bot);
        bot->saw_attack = false;
        bot->react_in = 0;
        return (BotKey){};
    }
    if (view.opp_attacking && !bot->saw_attack) bot->react_in = between(bot, TUNING.reaction_min, TUNING.reaction_max);
    bot->saw_attack = view.opp_attacking;
    if (bot->react_in > 0 && --bot->react_in == 0 && chance(bot, TUNING.block_chance)) block(bot);
    if (bot->plan_at >= bot->plan_length) think(bot, view);
    return bot->plan[bot->plan_at++];
}

// --- what the bot sees, and its keys as a pad word

static bool attacking(const T6World *w, const T6Fighter *f) {
    const T6Move *move = t6_move_at(w, f->move);
    return move && move->first_active > 0 && f->frame <= move->last_active;
}

static BotView bot_view(uint32_t side) {
    const T6World *w = &t6_match.world;
    const T6Fighter *me = &t6_match.fighters[side], *opponent = &t6_match.fighters[1 - side];
    float dx = opponent->base_position.x - me->base_position.x, dz = opponent->base_position.z - me->base_position.z;
    return (BotView){
        .distance = sqrtf(dx * dx + dz * dz),
        .on_right = me->input.camera_side == T6_SIDE_RIGHT,
        .opp_attacking = attacking(w, opponent),
        .fighting = w->round.phase == T6_PHASE_FIGHT,
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
    if (side >= T6_FIGHTER_COUNT) return 0;
    BotView view = bot_view(side);
    return pad_word(bot_key(&bots[side], view), view.on_right);
}
