// Steps 13, 16, 20 and 21 of the movement step: the counters and flags of the fighter. Pure bookkeeping, no motion.
#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/move.h"
#include "sim/state.h"
#include "sim/units.h"

static int16_t count_down(int16_t v) {
    if (v > 0) v--;
    return v;
}

static uint16_t count_down_to_zero(uint16_t v) {
    if (v != 0) v--;
    return v;
}

// Counts up and stops at the top.
static uint16_t count_up(uint16_t v) {
    v++;
    if (v == 0) v = COUNTER_MAX;  // wrapped to 0: hold at COUNTER_MAX
    return v;
}

static void tick_timers(T6Fighter *f) {
    f->countdown = count_down(f->countdown);
    f->hit_lockout = count_down(f->hit_lockout);
    t6_set_move_var(f, MOVE_VAR_COUNT_UP_A, count_up(t6_move_var(f, MOVE_VAR_COUNT_UP_A)));
    t6_set_move_var(f, MOVE_VAR_COUNT_UP_B, count_up(t6_move_var(f, MOVE_VAR_COUNT_UP_B)));
    t6_set_move_var(f, MOVE_VAR_COUNT_DOWN_A, count_down_to_zero(t6_move_var(f, MOVE_VAR_COUNT_DOWN_A)));
    t6_set_move_var(f, MOVE_VAR_COUNT_DOWN_B, count_down_to_zero(t6_move_var(f, MOVE_VAR_COUNT_DOWN_B)));
}

// A move with a second hitbox has two active, every other one.
static uint8_t active_hitboxes(const T6Fighter *f, const T6Move *move) {
    if (!t6_frame_between(f->frame, move->first_active, move->last_active)) return 0;  // outside the active frames: no hitbox
    if (move->hits.slots == 2) return 2;
    return 1;
}

// A hit-down move that ends touches down; every other move end is a plain end.
static bool ends_down(const T6Fighter *f) {
    uint8_t class_ = f->state_class;
    bool down_class = t6_class_between(class_, CLASS_HIT_DOWN_FIRST, CLASS_HIT_DOWN_LAST) ||
                      t6_class_between(class_, CLASS_FALLEN_FIRST, CLASS_FALLEN_LAST);  // hit-down or fallen count as down
    return f->hit_this_move && (down_class || (f->state & STATE_HURT_4));  // the move hit them and they are down or touching down
}

static void check_move_end(T6Fighter *f, const T6Move *move) {  // last window frame; not held, frame 1, or height-only root
    bool at_end = f->frame == move->window_end && f->hold_count == T6_HOLD_NONE && f->frame != 1 && f->root_mode != T6_ROOT_HEIGHT_ONLY;
    if (!at_end) return;
    if (ends_down(f)) f->touchdown = 1;  // a down ending sets touchdown; others set move_end
    else f->move_end = 1;
}

static void count_thrown_length(T6Fighter *f) {
    if (f->thrown_length == 0) return;
    f->thrown_length = (int16_t)(f->thrown_length - 1);
    if (f->thrown_length < 0 || f->clean_hit) f->thrown_length = 0;  // a clean hit or underflow clears the count
}

static void count_juggle_weight(T6Fighter *f) {
    if (f->thrown_length > JUGGLE_WEIGHT_FREE_LENGTH || f->juggle_weight == 0) return;  // drops only within free length
    f->juggle_weight = (int16_t)(f->juggle_weight - 1);
    if (f->juggle_weight < 0) f->juggle_weight = 0;
}

void t6_move_counters(const T6World *w, T6Fighter *f) {
    const T6Move *move = t6_move_at(w, f->move);
    tick_timers(f);
    f->active_hitboxes = active_hitboxes(f, move);
    f->in_air_window = f->juggle_count != 0 ||  // juggled, or inside the move's window frames
        t6_frame_between(f->frame, move->window_start, move->window_end);
    check_move_end(f, move);
    count_thrown_length(f);
    count_juggle_weight(f);
    if (f->keeps_throw_immune) f->throw_immune = 1;  // keep flag: throw immunity stays on
}

void t6_move_hit_timers(T6Fighter *f, const T6Fighter *opponent) {
    if (f->clean_hit || opponent->clean_hit) {  // a clean hit on either side cancels the forced counter hit
        f->force_counter_hit = 0;
    } else if ((uint16_t)f->force_counter_hit != 0) {
        f->guard_mask &= (uint16_t)~STATE_GUARD_BITS;  // clears guard bits each frame while forced
        f->force_counter_hit = (int16_t)(f->force_counter_hit - 1);
        if (f->force_counter_hit < 0) f->force_counter_hit = 0;
    }
    if (f->in_air_window) f->repeat_timer = 0;  // in the air window, repeat timer resets
    if (f->repeat_timer > 0) f->repeat_timer--;
    else f->repeat_timer = 0;
    if (f->repeat_timer == 0) f->repeat_count = 0;  // repeat count resets when repeat timer hits 0
}

void t6_move_update_can_act(const T6World *w, T6Fighter *f) {
    const T6Move *move = t6_move_at(w, f->move);
    bool late = f->frame >= (int32_t)f->can_act_frame && t6_move_ends_in_idle(move);  // late in a move that returns to idle
    if (move->first_active) f->can_act = late;  // an attack: free to act only late in it
    else if (!f->hit_this_move) f->can_act = !t6_off_ground(f) && !(f->state & STATE_HURT_4);  // can act: grounded and not hurt
    else f->can_act = late || f->stance_rule != 0;  // after a hit: free late, or when a stance rule holds
}

// The divisor is unsigned (divwu).
void t6_move_update_skip(const T6World *w, T6Fighter *f) {
    int16_t divider = f->update_divider;
    if (divider == T6_UPDATE_INACTIVE) return;  // inactive: skip_motion keeps its value
    f->skip_motion = divider == 0 || w->frame % (uint32_t)(int32_t)divider != 0;  // skip unless frame is a multiple of divider
}
