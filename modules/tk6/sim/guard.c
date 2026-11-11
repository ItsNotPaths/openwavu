#include "sim/guard.h"

#include "sim/fighter.h"
#include "sim/state.h"
#include "sim/units.h"

// The stances, as state words. The class and the guard mask follow from the word.
static constexpr uint32_t STAND = (CLASS_STAND << STATE_CLASS_SHIFT) | STATE_THROW_STANDING | STATE_GUARD_STAND | STATE_HURT_2;
static constexpr uint32_t CROUCH = (CLASS_CROUCH << STATE_CLASS_SHIFT) | STATE_THROW_CROUCHING | STATE_GUARD_CROUCH | STATE_HURT_1;
static constexpr uint32_t NO_GUARD = (CLASS_NO_GUARD << STATE_CLASS_SHIFT) | STATE_THROW_CROUCHING | STATE_HURT_1;
static constexpr uint32_t ALTERNATE_STAND = (CLASS_ALTERNATE_STAND << STATE_CLASS_SHIFT) | STATE_THROW_STANDING | STATE_THROW_CROUCHING | STATE_GUARD_STAND | STATE_HURT_2;
static constexpr uint32_t ALTERNATE_CROUCH = (CLASS_ALTERNATE_CROUCH << STATE_CLASS_SHIFT) | STATE_THROW_CROUCHING | STATE_GUARD_CROUCH | STATE_HURT_2;
static constexpr uint32_t ALTERNATE_CROUCH_LOW = (CLASS_ALTERNATE_CROUCH_LOW << STATE_CLASS_SHIFT) | STATE_THROW_CROUCHING | STATE_GUARD_CROUCH | STATE_HURT_1;
static constexpr uint32_t ALTERNATE_DOWN = (CLASS_ALTERNATE_DOWN << STATE_CLASS_SHIFT) | STATE_THROW_CROUCHING | STATE_HURT_2;

enum : uint16_t {
    HOLD_BACK = T6_DIRECTION_B,
    HOLD_BACK_DOWN = T6_DIRECTION_DB,
    HOLD_DOWN = T6_DIRECTION_D | T6_DIRECTION_DF,  // down or down-forward
};

static void set_stance(T6Fighter *f, uint32_t state) {  // also sets class and guard mask
    f->state = state;
    f->state_class = t6_state_class(state);
    f->guard_mask = (uint16_t)(state & STATE_GUARD_BITS);
}

// With neutral guard, neutral guards standing and straight down guards crouching too.
static void stance_by_input(T6Fighter *f, const T6Move *move) {
    if ((move->flags & T6_MOVE_GUARD_BY_INPUT) == 0) return;  // moves without the flag keep their stance
    uint16_t stand = HOLD_BACK, crouch = HOLD_BACK_DOWN;  // back guards standing, back-down guards crouching
    if (f->neutral_guard != 0) {
        stand |= T6_DIRECTION_N;
        crouch |= T6_DIRECTION_D;
    }
    if (t6_input_holds(&f->input, stand)) set_stance(f, STAND);
    else if (t6_input_holds(&f->input, crouch)) set_stance(f, CROUCH);
}

static void stance_by_opponent(T6Fighter *f, const T6Fighter *opponent) {  // standing attacks: standing guard, others: no guard
    if (opponent->attack_kind >= ATTACK_KIND_STAND_FIRST && opponent->attack_kind <= ATTACK_KIND_STAND_LAST) set_stance(f, STAND);
    else set_stance(f, NO_GUARD);
}

// The state word is kept as a 16 bit value (sign extended) when no direction picks a stance.
static void stance_held(T6Fighter *f, const T6Fighter *opponent) {
    if (t6_input_holds(&f->input, HOLD_BACK)) {
        set_stance(f, ALTERNATE_STAND);
    } else if (t6_input_holds(&f->input, HOLD_BACK_DOWN)) {
        if (opponent->attack_kind == ATTACK_KIND_LOW) set_stance(f, ALTERNATE_CROUCH_LOW);  // low attack: low crouch
        else set_stance(f, ALTERNATE_CROUCH);
    } else if (t6_input_holds(&f->input, HOLD_DOWN)) {
        set_stance(f, ALTERNATE_DOWN);
    } else {
        f->state = (uint32_t)(int32_t)(int16_t)f->state_copy;
        t6_state_guard(f);  // sets the guard mask and applies the guard lock
    }
}

static void pick_stance(T6Fighter *f, const T6Move *move, const T6Fighter *opponent) {
    if (f->stance_rule == STANCE_BY_INPUT) stance_by_input(f, move);
    else if (f->stance_rule == STANCE_BY_OPPONENT) stance_by_opponent(f, opponent);
    else stance_held(f, opponent);
}

bool t6_in_front(int16_t angle) { return (uint16_t)angle < QUARTER_TURN.bits; }  // angle is a size: front on either side

// The guard works on the ground, and in the air in the air-guard classes, with the opponent in front.
static bool can_guard(const T6Fighter *f) {
    bool air_guard = t6_class_between(f->state_class, CLASS_AIR_GUARD_FIRST, CLASS_AIR_GUARD_LAST);
    return (f->in_air_window == 0 || air_guard) && t6_in_front(f->opponent_angle);
}

void t6_move_guard(const T6World *w, T6Fighter *f, const T6Fighter *opponent) {
    const T6Move *move = t6_move_at(w, f->move);
    pick_stance(f, move, opponent);
    f->guard_mask = 0;
    if (can_guard(f)) f->guard_mask = (uint16_t)(f->state & STATE_GUARD_BITS);  // stance bits become the mask when can_guard
    if (t6_class_between(f->state_class, CLASS_HIT_DOWN_FIRST, CLASS_HIT_DOWN_LAST) &&  // add touch-down bit
        (move->flags & T6_MOVE_STATE_4) != 0) {
        f->state |= STATE_HURT_4;
        f->state_copy = f->state;
    }
}

void t6_state_guard(T6Fighter *f) {
    f->guard_mask = (uint16_t)(f->state & STATE_GUARD_BITS);
    if ((f->state & STATE_GUARD_LOCKED) != 0 && f->neutral_guard == 0) {  // guard lock clears guard, unless neutral guard
        f->state &= ~STATE_GUARD_BITS;
        f->guard_mask = 0;
    }
}

bool t6_guards_attack(const T6Fighter *defender, const T6Fighter *attacker) {
    return (defender->guard_mask & attacker->hit_level) != 0  // guard covers the attack height
        && t6_in_front(defender->angle_84);  // attacker in front
}
