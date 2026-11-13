// Requirements: the conditions of cancels, hit conditions and conditional properties. Each id names one
// predicate in REQUIREMENTS; the list walkers and the hit conditions read them.
#include "sim/requirements.h"

#include <stddef.h>

#include "sim/bones.h"
#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/hit.h"
#include "sim/limb.h"
#include "sim/properties.h"
#include "sim/round.h"
#include "sim/stage.h"
#include "sim/throw.h"
#include "sim/transition.h"
#include "sim/units.h"

// What a requirement reads: the fighter f who owns the list, the other object (opponent), their moves, the param
// (its low 16 bits, as the TK5 tests read it, and as a float; whole_param: a compare id or a move pool start at full
// width), and the row's argument.
typedef struct {
    const T6World *w;
    const T6Fighter *f, *opponent;
    const T6Move *own_move, *opponent_move;
    uint16_t id, param;
    uint32_t whole_param;
    float param_float;
    uint8_t argument, levels;
} Ask;

typedef bool Test(Ask ask);
// A requirement that writes state: the throw cache and the punch latch of f, the rng of w.
typedef bool Draw(T6World *w, T6Fighter *f, Ask ask);

typedef struct {
    Test *test;
    Draw *draw;
    uint8_t argument;  // what the predicate reads: a counter, a variable, a joint, a facing
    uint8_t levels;  // the hit levels of the facing hit tests
} Row;

// --- shared reads

static int16_t angle_of(const T6Fighter *fighter) {  // angle to the opponent, or to the reference direction if asked
    if (fighter->use_angle_84) return fighter->angle_84;  // reference angle mode: use it instead
    return fighter->opponent_angle;
}

static constexpr int16_t FACING_LIMIT = ANGLE_FROM_DEG(60);
static constexpr int16_t BEHIND_LIMIT = ANGLE_FROM_DEG(120);
static bool faces(const T6Fighter *fighter) {  // looking at the opponent: within 60 degrees
    return angle_of(fighter) < FACING_LIMIT;
}
static bool behind(const T6Fighter *fighter) {  // looking away from the opponent: more than 120 degrees off
    return angle_of(fighter) > BEHIND_LIMIT;
}
static bool back_turned(const T6Fighter *fighter) {  // back is to the opponent: more than a quarter turn off
    return fighter->opponent_angle > QUARTER_TURN.bits;
}

// The hit levels of the facing hit tests, as sets.
enum : uint8_t { LEVELS_NONE = 0, LEVELS_HIGH = 1 << 0, LEVELS_MID = 1 << 1, LEVELS_LOW = 1 << 2, LEVELS_HIGH_MID = LEVELS_HIGH | LEVELS_MID };

static bool level_in(uint16_t level, uint8_t sets) {  // is the hit level one of the high, mid or low kinds in the set
    bool high = level == HIT_LEVEL_HIGH_B || level == HIT_LEVEL_HIGH_A;
    bool mid = level == HIT_LEVEL_MID_A || level == HIT_LEVEL_MID_B || level == HIT_LEVEL_MID_C;
    bool low = level == HIT_LEVEL_LOW_A || level == HIT_LEVEL_LOW_B;
    return ((sets & LEVELS_HIGH) && high) || ((sets & LEVELS_MID) && mid) || ((sets & LEVELS_LOW) && low);
}

// Bone 0 passes, else the move attacks with that bone (T6MoveHits.attack_bones; params from 32 on name no
// bone).
static bool attacks_with(const T6Move *move, uint16_t bone) {  // does the move attack with this bone
    enum { ATTACK_BONES = 32 };
    if (bone == 0) return true;  // param 0 means any bone
    return bone < ATTACK_BONES && (move->hits.attack_bones & (1u << bone)) != 0;
}

// The run of the id pool at pool_start holds the move's id.
static bool in_pool(const T6World *w, const T6Fighter *f, const T6Move *move, uint32_t pool_start) {  // id is in list
    const uint32_t *pool = t6_set(w, f->moveset)->id_pool;
    for (uint32_t pool_index = pool_start; pool[pool_index] != 0; pool_index++)  // walk the list until the 0 end mark
        if (pool[pool_index] == move->compare_id) return true;
    return false;
}

// The first frame of a move with T6_MOVE_STATE_4.
static bool first_frame(const T6World *w, const T6Fighter *fighter) {  // a move that flags a knock-down class, on its first frame
    return (t6_move_at(w, fighter->move)->flags & T6_MOVE_STATE_4) && fighter->frame2 == 1;
}

static bool pushed(const T6Fighter *f) {  // any push speed on any axis
    return !(f->push.x == 0.0f && f->push.y == 0.0f && f->push.z == 0.0f);
}

static bool down(const T6Fighter *fighter) {  // hurt-4 state: knocked down or against a wall
    return t6_state_has(fighter->state, STATE_HURT_4);
}

static float floor_at(const T6World *w, T6Vec3 position) { return t6_stage_floor(w, position); }

// --- 0..1

static bool always(Ask ask) { (void)ask; return true; }  // requirement 0 and some others: always passes
static bool never(Ask ask) { (void)ask; return false; }  // a requirement the game never lets pass
static bool landed(Ask ask) { return ask.f->hit_landed != 0 && !ask.opponent->body_rules.unthrowable; }  // hit one that can be thrown

// --- 2..33 throws: the victim's position from the cache of the target, and the range

static bool throw_takes(T6World *w, T6Fighter *f, Ask ask) {
    (void)w;
    T6ThrowTarget *target = &f->throw.target[ask.opponent->slot];  // the throw cache for this opponent
    *target = t6_throw_look(*target, f, ask.opponent,  // look at the opponent again; a seen spot is kept if unchanged
                            ask.own_move->compare_id, ask.opponent_move->compare_id);
    return t6_throw_position_takes(t6_throw_position_of_requirement(ask.id), target->seen) &&  // id names the throw position
           ask.param_float >= target->range;  // and the param reach covers the throw range
}

// --- 34..41 distances

static bool near(Ask ask) { return ask.f->distance <= ask.param_float; }  // opponent is within param distance
static bool far(Ask ask) { return ask.param_float <= ask.f->distance; }  // opponent is at least param distance away
static bool near2(Ask ask) {  // second distance (the other body reference) is within param
    return ask.f->distance2 <= ask.param_float;
}
static bool far2(Ask ask) { return ask.param_float <= ask.f->distance2; }  // second distance is at least param
static bool near_either(Ask ask) {  // either distance is within param
    return ask.f->distance <= ask.param_float || ask.f->distance2 <= ask.param_float;
}
static bool far_either(Ask ask) {  // either distance is at least param
    return ask.param_float <= ask.f->distance || ask.param_float <= ask.f->distance2;
}

// --- 42..56 the opponent's attack and guard

static bool landed_unguarded(Ask ask) {  // own hit landed and its height is not one the opponent guards
    return ask.f->hit_landed && !(ask.f->hit_level & ask.opponent->guard_mask);
}
static bool opponent_guarded(Ask ask) { return ask.opponent->guarded != 0; }  // opponent guarded this frame
static bool whiffed(Ask ask) { return ask.f->whiffed != 0; }  // own attack missed
static bool opponent_not_throwing(Ask ask) {  // opponent is not the thrower of a throw
    return t6_transition_class(ask.opponent->transition) != TRANSITION_THROWER;
}
static bool opponent_attacks(Ask ask) { return ask.opponent->damage != 0; }  // opponent has an attack with damage
static bool opponent_quiet(Ask ask) { return ask.opponent->damage == 0; }  // opponent has no attack damage

static uint32_t hurt_bits(const T6Fighter *fighter) {  // the standing or crouching bits of the state
    return fighter->state & STATE_HURT_BITS;
}
static bool opponent_attacks_standing(Ask ask) {  // opponent attacks from a standing pose
    return ask.opponent->damage != 0 && hurt_bits(ask.opponent) == STATE_HURT_2;
}
static bool opponent_attacks_crouching(Ask ask) {  // opponent attacks from a crouch
    return ask.opponent->damage != 0 && hurt_bits(ask.opponent) == STATE_HURT_1;
}
static bool opponent_stands(Ask ask) {  // opponent is standing and not launched
    return !t6_state_has(ask.opponent->state, STATE_LAUNCHED) && hurt_bits(ask.opponent) == STATE_HURT_2;
}
static bool opponent_crouches(Ask ask) {  // opponent is crouching and not launched
    return !t6_state_has(ask.opponent->state, STATE_LAUNCHED) && hurt_bits(ask.opponent) == STATE_HURT_1;
}

static bool opponent_attack_high(Ask ask) { return ask.opponent->hit_level == HIT_LEVEL_HIGH_B; }  // opponent's attack is a high
static bool opponent_attack_mid(Ask ask) { return ask.opponent->hit_level == HIT_LEVEL_MID_A; }  // opponent's attack is a mid
static bool opponent_attack_low(Ask ask) {  // opponent's attack is a low
    return ask.opponent->hit_level == HIT_LEVEL_LOW_A || ask.opponent->hit_level == HIT_LEVEL_LOW_B;
}
static bool opponent_attack_high_or_mid(Ask ask) {  // opponent's attack is a high or a mid
    return ask.opponent->hit_level == HIT_LEVEL_HIGH_B || ask.opponent->hit_level == HIT_LEVEL_MID_A;
}
static bool opponent_attacks_with(Ask ask) {  // opponent's move attacks with the bone in the param
    return attacks_with(ask.opponent_move, ask.param);
}

// --- 57..77 angles and side bands

static constexpr int16_t SIDE_WIDE = ANGLE_FROM_DEG(110);

static bool back_to_opponent(Ask ask) { return back_turned(ask.f); }  // own back is to the opponent
static bool front_to_opponent(Ask ask) { return !back_turned(ask.f); }  // own front is to the opponent
static bool side_negative(Ask ask) { return ask.f->side_angle < 0; }  // opponent is on the negative side
static bool side_non_negative(Ask ask) { return ask.f->side_angle >= 0; }  // opponent is on the zero or positive side
static bool opponent_angle_at_least(Ask ask) {  // own angle to the opponent is at least param
    return ask.param <= ask.f->opponent_angle;
}
static bool opponent_angle_below(Ask ask) {  // own angle to the opponent is below param
    return ask.f->opponent_angle < ask.param;
}
static bool their_angle_at_least(Ask ask) {  // opponent's angle to us is at least param
    return ask.param <= ask.opponent->opponent_angle;
}
static bool their_angle_below(Ask ask) {  // opponent's angle to us is below param
    return ask.opponent->opponent_angle < ask.param;
}
static bool side_quarter(Ask ask) {  // opponent is a quarter turn or more to the positive side
    return ask.f->side_angle >= QUARTER_TURN.bits - 1;
}
static bool side_quarter_other(Ask ask) {  // opponent is more than a quarter turn to the negative side
    return ask.f->side_angle < -QUARTER_TURN.bits;
}
static bool side_wide(Ask ask) { return ask.f->side_angle > SIDE_WIDE; }  // opponent is past the wide side angle, positive side
static bool side_wide_other(Ask ask) {  // opponent is past the wide side angle, negative side
    return ask.f->side_angle <= -SIDE_WIDE;
}
static bool side_band_is(Ask ask) {  // own side band (0..3 of the side angle) is the one of the row
    return ask.f->side_band == ask.argument;
}
static bool their_side_band_is(Ask ask) {  // opponent's side band is the one of the row
    return ask.opponent->side_band == ask.argument;
}

// --- 78..96 frames of the moves

static constexpr float HIGH_ATTACK_REACH = 1792.0f;

static bool opponent_high_attack_near(Ask ask) {  // their high attack is still active and they are close
    return ask.opponent->hit_level == HIT_LEVEL_HIGH_B && ask.opponent->frame <= ask.opponent_move->last_active && ask.f->distance < HIGH_ATTACK_REACH;
}

// The frame counters the frame requirements compare with the param.
enum : uint8_t { TO_OPP_FIRST_ACTIVE, TO_OPP_LAST_ACTIVE, OPP_FRAME, OWN_FRAME2, OWN_MOVE_FRAMES };

static int16_t counter(Ask ask) {  // pick the frame counter the row names
    switch (ask.argument) {
    case TO_OPP_FIRST_ACTIVE:  // frames until the opponent's hitbox turns on (negative once on)
        return (int16_t)(ask.opponent_move->first_active - ask.opponent->frame);
    case TO_OPP_LAST_ACTIVE:  // frames until the opponent's hitbox turns off
        return (int16_t)(ask.opponent_move->last_active - ask.opponent->frame);
    case OPP_FRAME: return ask.opponent->frame;  // the opponent's current move frame
    case OWN_FRAME2: return ask.f->frame2;  // own second frame counter (1 = first frame)
    default: return ask.f->move_frames;  // frames since own move started
    }
}

static bool count_below(Ask ask) { return counter(ask) < (int16_t)ask.param; }  // counter is below param
static bool count_at_least(Ask ask) { return (int16_t)ask.param <= counter(ask); }  // counter is at least param
static bool count_is(Ask ask) { return (uint16_t)counter(ask) == ask.param; }  // counter equals param
static bool opponent_active_ends_within(Ask ask) {  // their active frames end within param frames, or they have none
    return ask.opponent->frame <= ask.opponent_move->last_active + (int16_t)ask.param || ask.opponent_move->first_active == 0;
}
static bool past_end_by(Ask ask) {  // own move is at least param frames past its length
    return ask.own_move->length + ask.param <= ask.f->frame;
}
static bool before_end_by(Ask ask) {  // own move is more than param frames from its end
    return ask.f->frame < ask.own_move->length - ask.param;
}

// --- 97..112 juggle, push, down, counter, punch latch, health

static bool not_juggled(Ask ask) {  // not juggled and not in a throw
    return ask.f->juggle_weight == 0 && ask.f->thrown_length == 0;
}
static bool juggled(Ask ask) { return ask.f->juggle_weight != 0 || ask.f->thrown_length != 0; }  // juggled or in a throw
static bool is_pushed(Ask ask) { return pushed(ask.f); }  // being pushed
static bool pushed_by_grounded(Ask ask) {  // being pushed by an opponent who is on the ground and not down
    return pushed(ask.f) && !ask.opponent->in_air_window && !down(ask.opponent);
}
static bool opponent_down(Ask ask) { return down(ask.opponent); }  // opponent is knocked down
static bool opponent_up(Ask ask) { return !down(ask.opponent); }  // opponent is not knocked down
static bool opponent_down_near(Ask ask) {  // opponent is down, their move has no slide window, and they are within param distance
    return down(ask.opponent) && ask.opponent_move->window_start == 0 && ask.param_float >= ask.f->distance;
}
static bool opponent_down_behind(Ask ask) {  // opponent is down and a quarter turn or more off our facing
    return down(ask.opponent) && ask.f->opponent_angle >= QUARTER_TURN.bits;
}
static bool opponent_counter_hit_grounded(Ask ask) {  // opponent is in a counter hit and on the ground
    return ask.opponent->counter_hit && !ask.opponent->in_air_window;
}
static bool no_health(Ask ask) {  // own health is 0, except in practice where there is no KO
    return ask.f->health == 0 && ask.w->mode != T6_MODE_PRACTICE;
}
static bool opponent_no_health(Ask ask) { return ask.opponent->health == 0; }  // opponent's health is 0
static bool opponent_below_half_health(Ask ask) {  // opponent has under half of their max health
    return ask.opponent->health < ask.opponent->max_health / 2;
}

// 106..108: was the first punch the one of the row? The answer stays in latch_result.
enum : uint8_t { LATCH_1, LATCH_2, LATCH_BOTH };

static bool first_punch(T6World *w, T6Fighter *f, Ask ask) {
    (void)w;
    T6ButtonSet punches = T6_BUTTON_1 | T6_BUTTON_2;  // row picks which punch buttons count: both by default
    if (ask.argument == LATCH_1) punches = T6_BUTTON_1;
    else if (ask.argument == LATCH_2) punches = T6_BUTTON_2;
    f->latch_result = t6_input_ask_first_punch(&f->input, punches);  // was the first punch one of them; keep the answer
    return f->latch_result;
}

// --- 113..127 side, first frames, the id pool, the cancel scan ahead

static bool on_right(const T6Fighter *f) {  // fighter stands on the right side of the screen
    return t6_input_on_right(&f->input);
}
static bool on_left_side(Ask ask) { return !on_right(ask.f); }  // stands on the left side
static bool on_right_side(Ask ask) { return on_right(ask.f); }  // stands on the right side
static bool on_left_back_turned(Ask ask) {  // on the left side with their back to the opponent
    return !on_right(ask.f) && back_turned(ask.f);
}
static bool on_right_back_turned(Ask ask) {  // on the right side with their back to the opponent
    return on_right(ask.f) && back_turned(ask.f);
}
static bool on_left_facing(Ask ask) { return !on_right(ask.f) && !back_turned(ask.f); }  // on the left side facing the opponent
static bool on_right_facing(Ask ask) { return on_right(ask.f) && !back_turned(ask.f); }  // on the right side facing the opponent
static bool forced_counter(Ask ask) { return ask.f->force_counter_hit != 0; }  // own next hit is forced to be a counter hit
static bool no_forced_counter(Ask ask) { return ask.f->force_counter_hit == 0; }  // no forced counter hit

// Objects 0 and 1 are the fighters; the stock game's mobs (2 and up) are not in the sim.
static bool fighter_first_frame(Ask ask) {  // fighter number in the param is on its first move frame
    return ask.param < T6_FIGHTER_COUNT && first_frame(ask.w, ask.w->fighters[ask.param]);
}
static bool any_fighter_first_frame(Ask ask) {  // either fighter is on its first move frame
    return first_frame(ask.w, ask.w->fighters[0]) || first_frame(ask.w, ask.w->fighters[1]);
}
static bool opponent_move_in_pool(Ask ask) {  // opponent's move id is in the id list at the param
    return in_pool(ask.w, ask.f, ask.opponent_move, ask.whole_param);
}
static bool scanning_ahead(Ask ask) {  // cancel scan is looking ahead past the move end
    return ask.f->scan_ahead.mode == SCAN_AHEAD;
}
static bool not_scanning_ahead(Ask ask) { return ask.f->scan_ahead.mode != SCAN_AHEAD; }  // cancel scan is not looking ahead

// Outside a scan ahead it passes; in one, the frame must be in the end window (param frames early) playing forward.
static bool in_ahead_window(Ask ask) {
    const T6ScanAhead *scan = &ask.f->scan_ahead;
    if (scan->mode == SCAN_OWN_MOVE) return true;  // scanning the own move: no window to check
    return scan->set && scan->window_start - ask.param <= ask.f->frame &&  // cancel has a window, frame is in it (param early)
           ask.f->frame <= scan->window_end && ask.f->play_direction > 0;  // and the move plays forward
}

// --- 128..142 per-joint wall bits; param WALL_ANY_SIDE tests for any bit

enum { WALL_JOINTS = 6, WALL_ANY_SIDE = 16, ALL_WALL_JOINTS = WALL_JOINTS };

static bool joint_at_wall(const T6Fighter *f, int joint, uint16_t wall_sides) {  // joint touches a wall on those sides
    if (wall_sides == WALL_ANY_SIDE) return f->wall_bits[joint] != 0;  // any wall side counts
    return (f->wall_bits[joint] & wall_sides) != 0;
}

static bool at_wall(Ask ask) {  // one joint, or any of the joints, touches a wall
    if (ask.argument != ALL_WALL_JOINTS) return joint_at_wall(ask.f, ask.argument, ask.param);
    bool hit = false;
    for (int joint = 0; joint < WALL_JOINTS; joint++) hit |= joint_at_wall(ask.f, joint, ask.param);  // check every joint
    return hit;
}

// --- 143..167 character, control, battle globals

enum { CHARA_CHRISTIE = 8, CHARA_KUMA = 11, CHARA_PANDA = 32, CHARA_EDDY = 33 };

// Kuma and Panda, Christie and Eddy count as one character.
static int16_t twin_of(uint16_t chara) {  // the paired character, or -1 when there is none
    switch (chara) {
    case CHARA_KUMA: return CHARA_PANDA;
    case CHARA_PANDA: return CHARA_KUMA;
    case CHARA_CHRISTIE: return CHARA_EDDY;
    case CHARA_EDDY: return CHARA_CHRISTIE;
    default: return -1;
    }
}

static bool same_chara(int16_t chara, uint16_t wanted) {  // is the character, or its twin
    return chara == wanted || (twin_of(wanted) >= 0 && chara == twin_of(wanted));
}
// The game's "not character X" passes for any X with a twin.
static bool other_chara(int16_t chara, uint16_t wanted) {  // "not character X" passes for any X with a twin
    return twin_of(wanted) >= 0 || chara != wanted;
}

static bool chara_is(Ask ask) { return same_chara(ask.f->chara, ask.param); }  // own character is the param
static bool chara_is_not(Ask ask) { return other_chara(ask.f->chara, ask.param); }  // own character is not the param
static bool opponent_chara_is(Ask ask) {  // opponent's character is the param
    return same_chara(ask.opponent->chara, ask.param);
}
static bool opponent_chara_is_not(Ask ask) {  // opponent's character is not the param
    return other_chara(ask.opponent->chara, ask.param);
}
static bool model_is(Ask ask) { return ask.f->chara_40 == ask.param; }  // own model id is the param
static bool model_is_not(Ask ask) { return ask.f->chara_40 != ask.param; }  // own model id is not the param
static bool opponent_model_is(Ask ask) { return ask.opponent->chara_40 == ask.param; }  // opponent's model id is the param
static bool opponent_model_is_not(Ask ask) {  // opponent's model id is not the param
    return ask.opponent->chara_40 != ask.param;
}
static bool chara_in_fight(Ask ask) {  // either fighter is the character in the param
    return ask.w->fighters[0]->chara == ask.param || ask.w->fighters[1]->chara == ask.param;
}
static bool model_in_fight(Ask ask) {  // either fighter has the model id in the param
    return ask.w->fighters[0]->chara_40 == ask.param || ask.w->fighters[1]->chara_40 == ask.param;
}

// A pad fighter under CPU control whose AI block is engaged.
static bool ai_driven(const T6Fighter *f) {
    return f->kind == T6_KIND_FIGHTER && t6_input_cpu_driven(&f->input) && f->ai_engaged != 0;  // a fighter the CPU drives
}

// param 0: a pad, or the AI driving a pad fighter (with ai_assist); else the control in the param.
static bool control_is(Ask ask) {
    if (ask.param != 0) return t6_input_control_is(&ask.f->input, ask.param);  // a control type is named: match it
    return t6_input_pad_driven(&ask.f->input) ||  // a human pad
           (ask.f->ai_assist && ai_driven(ask.f));  // or the AI driving a pad fighter that allows it
}
static bool opponent_control_is(Ask ask) {  // opponent's control type is the param
    return t6_input_control_is(&ask.opponent->input, ask.param);
}

// (hole tk6-costume-variant-table :tags (tk6 sim) :sev polish) this is the TK5 table; TK6's 102-entry table is not extracted.
// 155: a costume variant, by costume (other values read record 0).
enum { COSTUMES = 86 };
static const int16_t COSTUME_VARIANT[COSTUMES] = {
    0, 1, 0, 1, 2, 0, 1, 0, 1, 0, 1, 2, 0, 1, 0, 1, 0, 1, 2, 3, 4, 0, 1, 0, 1, 0, 1, 2, 0,
    1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 0, 1, 0, 1,
    2, 0, 1, 2, 3, 0, 1, 2, 0, 1, 0, 1, 0, 1, 2, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 3, 0,
};

static int16_t costume_variant_of(const T6Fighter *fighter) {
    int16_t costume = fighter->costume;
    if (costume < 0 || costume >= COSTUMES) costume = 0;  // a costume out of range reads as the first
    return COSTUME_VARIANT[costume];
}

static bool costume_variant_is(Ask ask) { return costume_variant_of(ask.f) == ask.param; }  // own costume is the variant in the param

static bool ai_signal_is(Ask ask) { return ask.f->ai_signal == ask.param; }  // the AI signal is the param
static bool practice_16_is(Ask ask) { return ask.w->practice_16 == ask.param; }  // a practice setting equals the param
static bool match_setting_at_least(Ask ask) { return ask.param <= ask.w->match_setting; }  // the match setting is at least param
static bool match_setting_at_most(Ask ask) { return ask.w->match_setting <= ask.param; }  // the match setting is at most param
static bool match_setting_is(Ask ask) { return ask.w->match_setting == ask.param; }  // the match setting is the param
static constexpr int32_t ROLL_PERIOD = 90;
static bool roll_frame_reached(Ask ask) {  // own roll slot in a 90 frame cycle, plus param, has been reached by the world frame
    return (int32_t)(ask.f->roll % ROLL_PERIOD + ask.param) <= (int32_t)ask.w->frame;
}

// --- 168..209 move variables of f (8), then of the opponent (6)

static bool var_at_least(Ask ask) {  // own move variable is at least param
    return ask.param <= t6_move_var(ask.f, ask.argument);
}
static bool var_at_most(Ask ask) { return t6_move_var(ask.f, ask.argument) <= ask.param; }  // own move variable is at most param
static bool var_is(Ask ask) { return t6_move_var(ask.f, ask.argument) == ask.param; }  // own move variable equals param
static bool opponent_var_at_least(Ask ask) {  // opponent's move variable is at least param
    return ask.param <= t6_move_var(ask.opponent, ask.argument);
}
static bool opponent_var_at_most(Ask ask) {  // opponent's move variable is at most param
    return t6_move_var(ask.opponent, ask.argument) <= ask.param;
}
static bool opponent_var_is(Ask ask) {  // opponent's move variable equals param
    return t6_move_var(ask.opponent, ask.argument) == ask.param;
}

// --- 210..218 frame speed and the facing hit tests

static bool speed_at_least(Ask ask) { return (int16_t)ask.param <= ask.f->speed; }  // own frame speed is at least param
static bool speed_at_most(Ask ask) { return ask.f->speed <= (int16_t)ask.param; }  // own frame speed is at most param
static bool speed_is(Ask ask) { return ask.f->speed == (int16_t)ask.param; }  // own frame speed equals param

// The facing of the hit tests: both face each other, f faces the opponent's back, or the opponent faces f.
enum : uint8_t { FACE_TO_FACE, FACING_BACK, OPP_FACING };

static bool facings(Ask ask, uint8_t facing) {  // do the fighters look the way the row wants
    if (facing == FACE_TO_FACE) return faces(ask.f) && faces(ask.opponent);  // both look at each other
    if (facing == FACING_BACK) return faces(ask.f) && behind(ask.opponent);  // own front to the opponent's back
    return faces(ask.opponent);  // opponent looks at us, whichever way we look
}

// The opponent's attack is of the levels and the bone of the param.
static bool attack_of(Ask ask, uint8_t levels) {  // opponent's attack height is in the set, and it uses the param's bone
    return level_in(ask.opponent->hit_level, levels) && attacks_with(ask.opponent_move, ask.param);
}

// The opponent on the ground, face to face.
static bool grounded_face_attack(Ask ask) {
    if (ask.opponent->in_air_window) return false;  // an airborne opponent never passes
    if (ask.levels == LEVELS_NONE) return facings(ask, FACE_TO_FACE);  // no height asked: only the facing counts
    return facings(ask, FACE_TO_FACE) &&  // face to face
           attack_of(ask, ask.levels);  // and their attack matches the height set
}

static bool grounded_face_pool(Ask ask) {
    return !ask.opponent->in_air_window && facings(ask, FACE_TO_FACE) &&  // grounded and face to face
           in_pool(ask.w, ask.f, ask.opponent_move, ask.whole_param);  // their move id is in the list
}

// --- 219..226 the first target hit by this move

static const T6Fighter *first_target(Ask ask) {  // the first object this move hit
    return t6_object(ask.w, ask.f->hit_targets[0]);
}

static uint32_t game_id(uint32_t move_id) {
    static constexpr uint32_t NO_MOVE_ID = UINT32_MAX;  // no TK6 move has it (TK5: 65535)
    if (move_id == NO_MOVE_ID) return 0;  // no move reads as id 0
    return move_id;
}

static bool target_guarded(Ask ask) { return first_target(ask)->guarded != 0; }  // the first target guarded
static bool target_first_frame(Ask ask) {  // the first target is on its first move frame
    return first_frame(ask.w, first_target(ask));
}
static bool target_down(Ask ask) { return down(first_target(ask)); }  // the first target is knocked down
static bool target_downed(Ask ask) {  // the first target lies on the floor
    return t6_state_has(first_target(ask)->state, STATE_DOWNED);
}
static bool target_up(Ask ask) {  // the first target is neither down nor lying
    return !down(first_target(ask)) && !t6_state_has(first_target(ask)->state, STATE_DOWNED);
}
static bool target_move_is(Ask ask) {  // the first target's move id is the param
    return game_id(t6_move_at(ask.w, first_target(ask)->move)->compare_id) == ask.whole_param;
}

static bool target_pending_is(Ask ask) {
    const T6Fighter *target = first_target(ask);
    return !t6_ref_none(target->pending_move) &&  // it has a move queued
           game_id(t6_move_at(ask.w, target->pending_move)->compare_id) == ask.whole_param;  // and its id is the param
}

static bool target_thrown(Ask ask) { return t6_thrown(first_target(ask)->throw.chain); }  // the first target is in a throw

// --- 227..238 rng draws and frame cycles

// One in param (param 0: the draw is 0).
static bool chance(T6World *w, T6Fighter *f, Ask ask) {
    (void)f;
    int32_t x = t6_rand(&w->rng);  // draw a random number
    if (ask.param == 0) return x == 0;  // param 0: passes only on a draw of 0
    return x % ask.param == 0;  // one chance in param
}

// param per mille, on the low 12 bits of the draw.
static bool chance_per_mille(T6World *w, T6Fighter *f, Ask ask) {
    (void)f;
    enum { DRAW_STEPS = 4096, PER_MILLE = 1000 };
    return (uint32_t)t6_rand(&w->rng) % DRAW_STEPS <  // low 12 bits of a draw
           (uint32_t)ask.param * DRAW_STEPS / PER_MILLE;  // fall under the param per mille
}

// argument: the cycle length of the roll and the frame.
static bool cycle_at(Ask ask) {  // the roll plus the world frame, in a cycle of the row's length, sits at the param's slot
    return (ask.f->roll + ask.w->frame) % ask.argument == ask.param % ask.argument;
}

static bool roll_one_in(Ask ask) {
    if (ask.param == 0) return ask.f->roll == 0;  // param 0: the roll must be 0
    return ask.f->roll % ask.param == 0;  // one in param, by the roll fixed at move start
}

// --- 239..261 game globals, score, stubs

enum { MODE_F9 = 3 };  // the value requirement 249 wants; its meaning is open
enum { SCORE_AHEAD, SCORE_BEHIND, SCORE_EVEN };

static int score_code(int16_t own_wins, int16_t opponent_wins) {  // who leads in round wins
    if (own_wins > opponent_wins) return SCORE_AHEAD;
    if (own_wins < opponent_wins) return SCORE_BEHIND;
    return SCORE_EVEN;
}

static int last_round_code(const T6Fighter *f, const T6Fighter *opponent) {  // 0 won, 1 no result or lost, 2 both lost
    if (f->last_round != T6_ROUND_LOST) return f->last_round < T6_ROUND_WON;  // own round was not lost: 0 if won, else 1
    if (opponent->last_round != T6_ROUND_LOST) return 1;  // own round lost, opponent's not
    return 2;
}

// The option bit in the param
static const uint32_t OPTION_BITS[] = {1 << 0, 1 << 1, 1 << 5, 1 << 2, 1 << 3, 1 << 4};

static bool option_on(Ask ask) {  // the round result has the option bit that the param names
    return ask.param < sizeof OPTION_BITS / sizeof *OPTION_BITS && (ask.w->round.result & OPTION_BITS[ask.param]) != 0;
}

static bool match_ending(Ask ask) { return ask.w->round.phase == T6_PHASE_MATCH_END; }  // the match is in its end phase
static bool battle_state_is(Ask ask) { return ask.w->battle_state == ask.param; }  // the battle state is the param
static bool in_phases(Ask ask) {  // the param is a phase test (db edit)
    T6PhaseTest test = t6_phase_test_of(ask.param);
    T6RoundState round_state = ask.w->round;
    bool first_frame = round_state.frame.ticks == 1 &&  // first frame of the phase
                       test.first_frame_of != T6_PHASE_NONE &&  // the param names one
                       round_state.phase == test.first_frame_of;  // and the round is in it
    return t6_phase_in(test.every_frame, round_state.phase) || first_frame;
}
static bool score_is(Ask ask) {  // win lead is the param (0 ahead, 1 behind, 2 even)
    return score_code(ask.f->wins, ask.opponent->wins) == ask.param;
}
static bool last_round_is(Ask ask) {  // the last round result code is the param
    return last_round_code(ask.f, ask.opponent) == ask.param;
}
static bool round_is(Ask ask) { return ask.w->round.round == ask.param; }  // the round number is the param

static bool match_point(Ask ask) {  // the match is over by the rules with the current wins
    const T6World *w = ask.w;
    return t6_match_over(w->rules, w->round, w->fighters[0]->wins, w->fighters[1]->wins);
}

static bool scene_state_is(Ask ask) { return ask.w->scene_state == ask.param; }  // the scene state is the param
static bool mode_is_f9(Ask ask) { return ask.w->mode == MODE_F9; }  // the game mode is the one value 249 wants (meaning open)
static bool mode_30_is(Ask ask) { return ask.w->mode_30 == ask.param; }  // a game mode field equals the param
static bool stage_is(Ask ask) { return ask.w->stage_id == ask.param; }  // the stage is the param
static bool stage_is_not(Ask ask) { return ask.w->stage_id != ask.param; }  // the stage is not the param
static bool start_record_is(Ask ask) {  // the stage start record is the param
    return (uint32_t)ask.w->start_record == ask.param;
}
static bool start_record_is_not(Ask ask) {  // the stage start record is not the param
    return (uint32_t)ask.w->start_record != ask.param;
}

// Requirements whose game function returns a constant: they test the param.
static constexpr uint16_t PARAM_103 = 65532;
static bool param_is_one(Ask ask) { return ask.param == 1; }  // param is 1
static bool param_is_zero_or_two(Ask ask) { return ask.param == 0 || ask.param == 2; }  // param is 0 or 2
static bool param_is_103(Ask ask) { return ask.param == PARAM_103; }  // param is 65532
static bool skip_motion_is(Ask ask) { return ask.f->skip_motion == ask.param; }  // own skip motion flag is the param
static bool input_mode_is(Ask ask) { return t6_input_mode_is(&ask.f->input, ask.param); }  // own input mode is the param

// --- 262..284 heights over the stage, the feet

// The param names a joint of skeleton A; another param fails.
static bool joint_param(Ask ask) {  // only fighters, and the param must name a joint
    return ask.f->kind == T6_KIND_FIGHTER && ask.param < T6_BONES_A;
}

static bool joint_on_floor(Ask ask) {
    if (!joint_param(ask)) return false;
    T6Vec3 joint = vec3_of(ask.f->joints[ask.param]);
    return joint.y + t6_fall_dy(ask.f) <= floor_at(ask.w, joint);  // after this frame's fall the joint is at or under the floor
}

// argument: the joint. At most param_float above the floor, and falling (fighters only).
static bool joint_low(Ask ask) {
    if (ask.f->kind != T6_KIND_FIGHTER) return false;  // fighters only
    T6Vec3 joint = vec3_of(ask.f->joints[ask.argument]);
    float above = (joint.y + t6_fall_dy(ask.f)) - floor_at(ask.w, joint);  // height of the joint over the floor after the fall
    return above <= ask.param_float && ask.f->base_delta.y < 0.0f;  // low enough and moving down
}

// argument: the feet. The words of the limb state of the side of f (limb.h `below`).
enum : uint8_t { R_FOOT = 1 << LIMB_R_FOOT, L_FOOT = 1 << LIMB_L_FOOT, FEET = R_FOOT | L_FOOT };
static bool feet_rose(Ask ask) {  // a foot in the row's set rose above the floor, by the limb state
    return (ask.w->fighters[ask.f->side_index]->limbs.below[BELOW_ROSE] & ask.argument) != 0;
}
static bool feet_below(Ask ask) {  // a foot in the row's set is below the floor, by the limb state
    return (ask.w->fighters[ask.f->side_index]->limbs.below[BELOW_NOW] & ask.argument) != 0;
}

static bool joint_under_ceiling(Ask ask) {
    enum { QUERY_KIND = 5 };
    static constexpr float QUERY_MARGIN = 100.0f;
    if (!joint_param(ask)) return false;
    T6Vec3 joint = vec3_of(ask.f->joints[ask.param]);
    return t6_stage_lowest(ask.w, joint, QUERY_KIND) - QUERY_MARGIN <=  // the ceiling above is within 100 units
           joint.y;  // of the joint
}

static float height(Ask ask) {  // height of the body base over the floor
    return ask.f->base_position.y - floor_at(ask.w, ask.f->base_position);
}
static bool height_below(Ask ask) { return height(ask) < ask.param_float; }  // base is lower than param over the floor
static bool height_at_least(Ask ask) { return ask.param_float <= height(ask); }  // base is at least param over the floor
static bool base_y_at_most(Ask ask) {  // base height is at most param, floor ignored
    return ask.f->base_position.y <= ask.param_float;
}

// --- 285..326 hits taken: off the ground, and the facing hit tests. `REQ_AIR_REACTION` also makes an air hit of the hit condition
// take its own reaction list (t6_hit_condition).

static bool opponent_off_ground(Ask ask) { return t6_off_ground(ask.opponent); }  // opponent is in the air or launched

// argument: the facing. 291..308 and 309..326 are the same 18 tests.
static bool hit_facing(Ask ask) {  // own hit was taken this frame and the facing fits
    return ask.f->hit_taken && facings(ask, ask.argument);
}
static bool pool_facing(Ask ask) {  // facing fits and the opponent's move id is in the list
    return facings(ask, ask.argument) && in_pool(ask.w, ask.f, ask.opponent_move, ask.whole_param);
}

static bool attack_facing(Ask ask) {  // the opponent shows their attack, the facing fits, and the attack height matches
    return !ask.opponent->hides_attack && facings(ask, ask.argument) && attack_of(ask, ask.levels);
}
// 357..368: as attack_facing, but a hidden attack counts unless its hit is harmless (TK6 0x181..0x18c).
static bool attack_facing_unless_harmless(Ask ask) {
    bool shown = !ask.opponent->hides_attack || ask.opponent->reaction_rule != REACT_HARMLESS;
    return shown && facings(ask, ask.argument) && attack_of(ask, ask.levels);
}

// --- 327..351 new in TK6: bound, health, the move variables H to J, the ground, costumes

static bool bound_allowed(Ask ask) {
    return t6_off_ground(ask.opponent) && ask.opponent->bounds_used < ask.w->rules.bounds_per_combo;
}

// argument: whose health. The param is whole points, or a percent of the full health.
enum : uint8_t { OWN_HEALTH, OPPONENT_HEALTH };
static const T6Fighter *health_owner(Ask ask) {
    if (ask.argument == OPPONENT_HEALTH) return ask.opponent;
    return ask.f;
}
static bool health_at_least(Ask ask) { return health_owner(ask)->health >= t6_health_points(ask.param).raw; }
static bool health_below(Ask ask) { return health_owner(ask)->health < t6_health_points(ask.param).raw; }
// Percent in whole points: health and full health are each cut to whole points first.
static int32_t whole_points(int32_t health) { return health / HEALTH_FROM_POINTS(1); }
static int32_t health_percent(Ask ask) {
    const T6Fighter *owner = health_owner(ask);
    return t6_divw(whole_points(owner->health) * 100, whole_points(owner->max_health));
}
static bool health_percent_at_least(Ask ask) { return health_percent(ask) >= ask.param; }
static bool health_percent_below(Ask ask) { return health_percent(ask) < ask.param; }

static bool opponent_on_ground(Ask ask) { return !t6_off_ground(ask.opponent); }

// The param is the character (or model) in the high byte and the costume variant in the low byte.
enum { PARAM_BYTE_BITS = 8, PARAM_BYTE_MASK = 255 };
static bool opponent_variant_is(Ask ask) {
    return costume_variant_of(ask.opponent) == (ask.param & PARAM_BYTE_MASK);
}
static bool opponent_chara_variant(Ask ask) {
    return ask.opponent->chara == ask.param >> PARAM_BYTE_BITS && opponent_variant_is(ask);
}
static bool opponent_chara_variant_not(Ask ask) { return !opponent_chara_variant(ask); }
static bool opponent_model_variant(Ask ask) {
    return ask.opponent->chara_40 == ask.param >> PARAM_BYTE_BITS && opponent_variant_is(ask);
}
static bool opponent_model_variant_not(Ask ask) { return !opponent_model_variant(ask); }

// The costume is the param or the one after it.
enum { COSTUME_PAIR = 2 };
static bool in_costume_pair(const T6Fighter *fighter, uint16_t first) {
    return (uint32_t)(fighter->costume - first) < COSTUME_PAIR;
}
static bool costume_pair(Ask ask) { return in_costume_pair(ask.f, ask.param); }
static bool opponent_costume_pair(Ask ask) { return in_costume_pair(ask.opponent, ask.param); }

// --- 352..368 new in TK6, found later: the hit of this move, Yoshimitsu's part swaps, the loose facing copies (above)

static bool hit_this_move(Ask ask) { return ask.f->hit_this_move != 0; }  // P+0x229

// argument: which pair of parts (P+0x740 bit 6 or bit 5).
enum : uint8_t { PARTS_FIRST, PARTS_SECOND };
static bool parts_swapped(Ask ask) {
    return (ask.argument == PARTS_FIRST ? ask.f->parts_swapped_first : ask.f->parts_swapped_second) != 0;
}
static bool parts_not_swapped(Ask ask) { return !parts_swapped(ask); }

static const Row REQUIREMENTS[T6_REQUIREMENT_COUNT] = {
    [0] = {always}, [1] = {landed},
    // 2..33: throws
    [2] = {.draw = throw_takes}, [3] = {.draw = throw_takes}, [4] = {.draw = throw_takes}, [5] = {.draw = throw_takes},
    [6] = {.draw = throw_takes}, [7] = {.draw = throw_takes}, [8] = {.draw = throw_takes}, [9] = {.draw = throw_takes},
    [10] = {.draw = throw_takes}, [11] = {.draw = throw_takes}, [12] = {.draw = throw_takes}, [13] = {.draw = throw_takes},
    [14] = {.draw = throw_takes}, [15] = {.draw = throw_takes}, [16] = {.draw = throw_takes}, [17] = {.draw = throw_takes},
    [18] = {.draw = throw_takes}, [19] = {.draw = throw_takes}, [20] = {.draw = throw_takes}, [21] = {.draw = throw_takes},
    [22] = {.draw = throw_takes}, [23] = {.draw = throw_takes}, [24] = {.draw = throw_takes}, [25] = {.draw = throw_takes},
    [26] = {.draw = throw_takes}, [27] = {.draw = throw_takes}, [28] = {.draw = throw_takes}, [29] = {.draw = throw_takes},
    [30] = {.draw = throw_takes}, [31] = {.draw = throw_takes}, [32] = {.draw = throw_takes}, [33] = {.draw = throw_takes},
    // 34..41: distances
    [34] = {near}, [35] = {far}, [36] = {near}, [37] = {near2}, [38] = {near_either}, [39] = {far}, [40] = {far2},
    [41] = {far_either},
    // 42..56: the opponent's attack and guard
    [42] = {landed_unguarded}, [43] = {opponent_guarded}, [44] = {whiffed}, [45] = {opponent_not_throwing}, [46] = {opponent_attacks},
    [47] = {opponent_attacks_standing}, [48] = {opponent_attacks_crouching}, [49] = {opponent_quiet}, [50] = {opponent_stands},
    [51] = {opponent_crouches}, [52] = {opponent_attack_high}, [53] = {opponent_attack_mid}, [54] = {opponent_attack_low},
    [55] = {opponent_attack_high_or_mid}, [56] = {opponent_attacks_with},
    // 57..77: angles and side bands
    [57] = {back_to_opponent}, [58] = {front_to_opponent}, [59] = {side_negative}, [60] = {side_non_negative},
    [61] = {opponent_angle_at_least}, [62] = {opponent_angle_below}, [63] = {their_angle_at_least}, [64] = {their_angle_below},
    [65] = {side_quarter}, [66] = {side_quarter_other}, [67] = {side_wide}, [68] = {side_wide_other},
    [69] = {side_band_is, .argument = 0}, [70] = {side_band_is, .argument = 1}, [71] = {side_band_is, .argument = 3},
    [72] = {side_band_is, .argument = 2}, [73] = {their_side_band_is, .argument = 0}, [74] = {their_side_band_is, .argument = 1},
    [75] = {their_side_band_is, .argument = 3}, [76] = {their_side_band_is, .argument = 2}, [77] = {never},
    // 78..96: frames of the moves
    [78] = {opponent_high_attack_near},
    [79] = {count_below, .argument = TO_OPP_FIRST_ACTIVE}, [80] = {count_at_least, .argument = TO_OPP_FIRST_ACTIVE},
    [81] = {count_is, .argument = TO_OPP_FIRST_ACTIVE},
    [82] = {count_below, .argument = TO_OPP_LAST_ACTIVE}, [83] = {count_at_least, .argument = TO_OPP_LAST_ACTIVE},
    [84] = {count_is, .argument = TO_OPP_LAST_ACTIVE},
    [85] = {opponent_active_ends_within}, [86] = {past_end_by}, [87] = {before_end_by},
    [88] = {count_at_least, .argument = OPP_FRAME}, [89] = {count_below, .argument = OPP_FRAME}, [90] = {count_is, .argument = OPP_FRAME},
    [91] = {count_at_least, .argument = OWN_FRAME2}, [92] = {count_below, .argument = OWN_FRAME2}, [93] = {count_is, .argument = OWN_FRAME2},
    [94] = {count_at_least, .argument = OWN_MOVE_FRAMES}, [95] = {count_below, .argument = OWN_MOVE_FRAMES},
    [96] = {count_is, .argument = OWN_MOVE_FRAMES},
    // 97..112: juggle, push, down, counter, punch latch, health
    [97] = {not_juggled}, [98] = {juggled}, [99] = {is_pushed}, [100] = {pushed_by_grounded}, [101] = {opponent_down},
    [102] = {opponent_up}, [103] = {opponent_down_near}, [104] = {opponent_down_behind}, [105] = {opponent_counter_hit_grounded},
    [106] = {.draw = first_punch, .argument = LATCH_1}, [107] = {.draw = first_punch, .argument = LATCH_2},
    [108] = {.draw = first_punch, .argument = LATCH_BOTH}, [109] = {always}, [110] = {no_health}, [111] = {opponent_no_health},
    [112] = {opponent_below_half_health},
    // 113..127: side, first frames, the id pool, the cancel scan ahead
    [113] = {on_left_side}, [114] = {on_right_side}, [115] = {on_left_back_turned}, [116] = {on_right_back_turned},
    [117] = {on_left_facing}, [118] = {on_right_facing}, [119] = {forced_counter}, [120] = {no_forced_counter},
    [121] = {fighter_first_frame}, [122] = {any_fighter_first_frame}, [123] = {opponent_move_in_pool}, [124] = {scanning_ahead},
    [125] = {not_scanning_ahead}, [126] = {in_ahead_window}, [127] = {never},
    // 128..142: wall bits of the joints, all or one, twice
    [128] = {at_wall, .argument = ALL_WALL_JOINTS}, [129] = {at_wall, .argument = 0}, [130] = {at_wall, .argument = 1},
    [131] = {at_wall, .argument = 2}, [132] = {at_wall, .argument = 3}, [133] = {at_wall, .argument = 4}, [134] = {at_wall, .argument = 5},
    [135] = {at_wall, .argument = ALL_WALL_JOINTS}, [136] = {at_wall, .argument = 0}, [137] = {at_wall, .argument = 1},
    [138] = {at_wall, .argument = 2}, [139] = {at_wall, .argument = 3}, [140] = {at_wall, .argument = 4}, [141] = {at_wall, .argument = 5},
    [142] = {always},
    // 143..167: character, control, battle globals; 158, 163, 164, 166 and 167 are false
    [143] = {chara_is}, [144] = {chara_is_not}, [145] = {opponent_chara_is}, [146] = {opponent_chara_is_not}, [147] = {model_is},
    [148] = {model_is_not}, [149] = {opponent_model_is}, [150] = {opponent_model_is_not}, [151] = {control_is},
    [152] = {opponent_control_is}, [153] = {chara_in_fight}, [154] = {model_in_fight}, [155] = {costume_variant_is},
    [156] = {ai_signal_is}, [157] = {never}, [158] = {never}, [159] = {practice_16_is},
    [160] = {match_setting_at_least}, [161] = {match_setting_at_most}, [162] = {match_setting_is}, [163] = {never}, [164] = {never},
    [165] = {roll_frame_reached}, [166] = {never}, [167] = {never},
    // 168..191: the move variables of f; 192..209: of the opponent
    [168] = {var_at_least, .argument = MOVE_VAR_COUNT_UP_A}, [169] = {var_at_least, .argument = MOVE_VAR_COUNT_DOWN_A},
    [170] = {var_at_least, .argument = MOVE_VAR_COUNT_DOWN_B}, [171] = {var_at_least, .argument = MOVE_VAR_D},
    [172] = {var_at_least, .argument = MOVE_VAR_E}, [173] = {var_at_least, .argument = MOVE_VAR_LOCAL},
    [174] = {var_at_least, .argument = MOVE_VAR_COUNT_UP_B}, [175] = {var_at_least, .argument = MOVE_VAR_G},
    [176] = {var_at_most, .argument = MOVE_VAR_COUNT_UP_A}, [177] = {var_at_most, .argument = MOVE_VAR_COUNT_DOWN_A},
    [178] = {var_at_most, .argument = MOVE_VAR_COUNT_DOWN_B}, [179] = {var_at_most, .argument = MOVE_VAR_D},
    [180] = {var_at_most, .argument = MOVE_VAR_E}, [181] = {var_at_most, .argument = MOVE_VAR_LOCAL},
    [182] = {var_at_most, .argument = MOVE_VAR_COUNT_UP_B}, [183] = {var_at_most, .argument = MOVE_VAR_G},
    [184] = {var_is, .argument = MOVE_VAR_COUNT_UP_A}, [185] = {var_is, .argument = MOVE_VAR_COUNT_DOWN_A},
    [186] = {var_is, .argument = MOVE_VAR_COUNT_DOWN_B}, [187] = {var_is, .argument = MOVE_VAR_D}, [188] = {var_is, .argument = MOVE_VAR_E},
    [189] = {var_is, .argument = MOVE_VAR_LOCAL}, [190] = {var_is, .argument = MOVE_VAR_COUNT_UP_B}, [191] = {var_is, .argument = MOVE_VAR_G},
    [192] = {opponent_var_at_least, .argument = MOVE_VAR_COUNT_UP_A}, [193] = {opponent_var_at_least, .argument = MOVE_VAR_COUNT_DOWN_A},
    [194] = {opponent_var_at_least, .argument = MOVE_VAR_COUNT_DOWN_B}, [195] = {opponent_var_at_least, .argument = MOVE_VAR_D},
    [196] = {opponent_var_at_least, .argument = MOVE_VAR_E}, [197] = {opponent_var_at_least, .argument = MOVE_VAR_LOCAL},
    [198] = {opponent_var_at_most, .argument = MOVE_VAR_COUNT_UP_A}, [199] = {opponent_var_at_most, .argument = MOVE_VAR_COUNT_DOWN_A},
    [200] = {opponent_var_at_most, .argument = MOVE_VAR_COUNT_DOWN_B}, [201] = {opponent_var_at_most, .argument = MOVE_VAR_D},
    [202] = {opponent_var_at_most, .argument = MOVE_VAR_E}, [203] = {opponent_var_at_most, .argument = MOVE_VAR_LOCAL},
    [204] = {opponent_var_is, .argument = MOVE_VAR_COUNT_UP_A}, [205] = {opponent_var_is, .argument = MOVE_VAR_COUNT_DOWN_A},
    [206] = {opponent_var_is, .argument = MOVE_VAR_COUNT_DOWN_B}, [207] = {opponent_var_is, .argument = MOVE_VAR_D},
    [208] = {opponent_var_is, .argument = MOVE_VAR_E}, [209] = {opponent_var_is, .argument = MOVE_VAR_LOCAL},
    // 210..218: frame speed, facing hit tests on a grounded opponent
    [210] = {speed_at_least}, [211] = {speed_at_most}, [212] = {speed_is},
    [213] = {grounded_face_attack, .levels = LEVELS_NONE}, [214] = {grounded_face_attack, .levels = LEVELS_HIGH},
    [215] = {grounded_face_attack, .levels = LEVELS_MID}, [216] = {grounded_face_attack, .levels = LEVELS_LOW},
    [217] = {grounded_face_attack, .levels = LEVELS_HIGH_MID}, [218] = {grounded_face_pool},
    // 219..226: the first target hit by this move
    [219] = {target_guarded}, [220] = {target_first_frame}, [221] = {target_down}, [222] = {target_downed},
    [223] = {target_up}, [224] = {target_move_is}, [225] = {target_pending_is}, [226] = {target_thrown},
    // 227..238: rng draws and cycles of the roll and the frame
    [227] = {.draw = chance}, [228] = {cycle_at, .argument = 2}, [229] = {cycle_at, .argument = 3}, [230] = {cycle_at, .argument = 4},
    [231] = {cycle_at, .argument = 5}, [232] = {cycle_at, .argument = 6}, [233] = {cycle_at, .argument = 7}, [234] = {cycle_at, .argument = 8},
    [235] = {cycle_at, .argument = 9}, [236] = {cycle_at, .argument = 10}, [237] = {.draw = chance_per_mille}, [238] = {roll_one_in},
    // 239..261: game globals, score, stubs; 257 and 258 are false
    [239] = {match_ending}, [240] = {battle_state_is}, [241] = {in_phases}, [242] = {in_phases}, [243] = {score_is},
    [244] = {last_round_is}, [245] = {option_on}, [246] = {round_is}, [247] = {match_point}, [248] = {scene_state_is},
    [249] = {mode_is_f9}, [250] = {mode_30_is}, [251] = {stage_is}, [252] = {stage_is_not}, [253] = {start_record_is},
    [254] = {start_record_is_not}, [255] = {param_is_one}, [256] = {param_is_zero_or_two}, [257] = {never}, [258] = {never},
    [259] = {param_is_103}, [260] = {skip_motion_is}, [261] = {input_mode_is},
    // 262..284: heights over the stage, the feet; 276..281 are false
    [262] = {joint_on_floor}, [263] = {joint_low, .argument = BONE_HIPS}, [264] = {joint_low, .argument = BONE_L_HAND},
    [265] = {joint_low, .argument = BONE_R_HAND}, [266] = {joint_low, .argument = BONE_L_FOOT}, [267] = {joint_low, .argument = BONE_R_FOOT},
    [268] = {joint_low, .argument = BONE_NECK}, [269] = {feet_rose, .argument = FEET}, [270] = {feet_rose, .argument = L_FOOT},
    [271] = {feet_rose, .argument = R_FOOT}, [272] = {feet_below, .argument = FEET}, [273] = {feet_below, .argument = L_FOOT},
    [274] = {feet_below, .argument = R_FOOT}, [275] = {joint_under_ceiling}, [276] = {never}, [277] = {never}, [278] = {never},
    [279] = {never}, [280] = {never}, [281] = {never}, [282] = {height_below}, [283] = {height_at_least},
    [284] = {base_y_at_most},
    // 285..326: hits taken; 287..290 are false
    [285] = {opponent_off_ground}, [286] = {opponent_off_ground}, [287] = {never}, [288] = {never}, [289] = {never}, [290] = {never},
    [291] = {hit_facing, .argument = FACE_TO_FACE}, [292] = {attack_facing, .argument = FACE_TO_FACE, .levels = LEVELS_HIGH},
    [293] = {attack_facing, .argument = FACE_TO_FACE, .levels = LEVELS_MID}, [294] = {attack_facing, .argument = FACE_TO_FACE, .levels = LEVELS_LOW},
    [295] = {attack_facing, .argument = FACE_TO_FACE, .levels = LEVELS_HIGH_MID}, [296] = {pool_facing, .argument = FACE_TO_FACE},
    [297] = {hit_facing, .argument = FACING_BACK}, [298] = {attack_facing, .argument = FACING_BACK, .levels = LEVELS_HIGH},
    [299] = {attack_facing, .argument = FACING_BACK, .levels = LEVELS_MID}, [300] = {attack_facing, .argument = FACING_BACK, .levels = LEVELS_LOW},
    [301] = {attack_facing, .argument = FACING_BACK, .levels = LEVELS_HIGH_MID}, [302] = {pool_facing, .argument = FACING_BACK},
    [303] = {hit_facing, .argument = OPP_FACING}, [304] = {attack_facing, .argument = OPP_FACING, .levels = LEVELS_HIGH},
    [305] = {attack_facing, .argument = OPP_FACING, .levels = LEVELS_MID}, [306] = {attack_facing, .argument = OPP_FACING, .levels = LEVELS_LOW},
    [307] = {attack_facing, .argument = OPP_FACING, .levels = LEVELS_HIGH_MID}, [308] = {pool_facing, .argument = OPP_FACING},
    [309] = {hit_facing, .argument = FACE_TO_FACE}, [310] = {attack_facing, .argument = FACE_TO_FACE, .levels = LEVELS_HIGH},
    [311] = {attack_facing, .argument = FACE_TO_FACE, .levels = LEVELS_MID}, [312] = {attack_facing, .argument = FACE_TO_FACE, .levels = LEVELS_LOW},
    [313] = {attack_facing, .argument = FACE_TO_FACE, .levels = LEVELS_HIGH_MID}, [314] = {pool_facing, .argument = FACE_TO_FACE},
    [315] = {hit_facing, .argument = FACING_BACK}, [316] = {attack_facing, .argument = FACING_BACK, .levels = LEVELS_HIGH},
    [317] = {attack_facing, .argument = FACING_BACK, .levels = LEVELS_MID}, [318] = {attack_facing, .argument = FACING_BACK, .levels = LEVELS_LOW},
    [319] = {attack_facing, .argument = FACING_BACK, .levels = LEVELS_HIGH_MID}, [320] = {pool_facing, .argument = FACING_BACK},
    [321] = {hit_facing, .argument = OPP_FACING}, [322] = {attack_facing, .argument = OPP_FACING, .levels = LEVELS_HIGH},
    [323] = {attack_facing, .argument = OPP_FACING, .levels = LEVELS_MID}, [324] = {attack_facing, .argument = OPP_FACING, .levels = LEVELS_LOW},
    [325] = {attack_facing, .argument = OPP_FACING, .levels = LEVELS_HIGH_MID}, [326] = {pool_facing, .argument = OPP_FACING},
    // 327..351: new in TK6
    [327] = {bound_allowed},
    [328] = {health_at_least, .argument = OWN_HEALTH}, [329] = {health_below, .argument = OWN_HEALTH},
    [330] = {health_at_least, .argument = OPPONENT_HEALTH}, [331] = {health_below, .argument = OPPONENT_HEALTH},
    [332] = {health_percent_at_least, .argument = OWN_HEALTH}, [333] = {health_percent_below, .argument = OWN_HEALTH},
    [334] = {health_percent_at_least, .argument = OPPONENT_HEALTH}, [335] = {health_percent_below, .argument = OPPONENT_HEALTH},
    [336] = {var_at_least, .argument = MOVE_VAR_H}, [337] = {var_at_least, .argument = MOVE_VAR_I},
    [338] = {var_at_least, .argument = MOVE_VAR_J}, [339] = {var_at_most, .argument = MOVE_VAR_H},
    [340] = {var_at_most, .argument = MOVE_VAR_I}, [341] = {var_at_most, .argument = MOVE_VAR_J},
    [342] = {var_is, .argument = MOVE_VAR_H}, [343] = {var_is, .argument = MOVE_VAR_I}, [344] = {var_is, .argument = MOVE_VAR_J},
    [345] = {opponent_on_ground},
    [346] = {opponent_chara_variant}, [347] = {opponent_chara_variant_not},
    [348] = {opponent_model_variant}, [349] = {opponent_model_variant_not},
    [350] = {costume_pair}, [351] = {opponent_costume_pair},
    [352] = {hit_this_move},
    [353] = {parts_swapped, .argument = PARTS_FIRST}, [354] = {parts_not_swapped, .argument = PARTS_FIRST},
    [355] = {parts_swapped, .argument = PARTS_SECOND}, [356] = {parts_not_swapped, .argument = PARTS_SECOND},
    [357] = {attack_facing_unless_harmless, .argument = FACE_TO_FACE, .levels = LEVELS_HIGH},
    [358] = {attack_facing_unless_harmless, .argument = FACE_TO_FACE, .levels = LEVELS_MID},
    [359] = {attack_facing_unless_harmless, .argument = FACE_TO_FACE, .levels = LEVELS_LOW},
    [360] = {attack_facing_unless_harmless, .argument = FACE_TO_FACE, .levels = LEVELS_HIGH_MID},
    [361] = {attack_facing_unless_harmless, .argument = FACING_BACK, .levels = LEVELS_HIGH},
    [362] = {attack_facing_unless_harmless, .argument = FACING_BACK, .levels = LEVELS_MID},
    [363] = {attack_facing_unless_harmless, .argument = FACING_BACK, .levels = LEVELS_LOW},
    [364] = {attack_facing_unless_harmless, .argument = FACING_BACK, .levels = LEVELS_HIGH_MID},
    [365] = {attack_facing_unless_harmless, .argument = OPP_FACING, .levels = LEVELS_HIGH},
    [366] = {attack_facing_unless_harmless, .argument = OPP_FACING, .levels = LEVELS_MID},
    [367] = {attack_facing_unless_harmless, .argument = OPP_FACING, .levels = LEVELS_LOW},
    [368] = {attack_facing_unless_harmless, .argument = OPP_FACING, .levels = LEVELS_HIGH_MID},
};

bool t6_requirement(T6World *w, const T6Requirement *req, T6Fighter *f, const T6Fighter *opponent) {
    if (req->id >= T6_PROPERTY_BASE) return true;  // an instant property
    if (req->id >= T6_REQUIREMENT_COUNT) return false;
    Row row = REQUIREMENTS[req->id];
    Ask ask = {w, f, opponent, t6_move_at(w, f->move), t6_move_at(w, opponent->move), req->id, (uint16_t)req->param, req->param, (float)(uint16_t)req->param,
               row.argument, row.levels};
    if (row.draw != NULL) return row.draw(w, f, ask);
    if (row.test != NULL) return row.test(ask);
    return false;
}

bool t6_requirements(T6World *w, const T6Requirement *list, T6Fighter *f, const T6Fighter *opponent) {
    for (; list->id != T6_REQ_END; list++)
        if (!t6_requirement(w, list, f, opponent)) return false;
    return true;
}

float t6_fall_dy(const T6Fighter *f) {
    float y = f->position.y;
    float next = y;
    if (y > 0.0f && !f->no_gravity) next = y + (f->velocity.y - GRAVITY);
    return next - y;
}

// --- hit conditions

// The first hit condition of the move whose requirements pass (the list always ends in one that does). The defender
// keeps which of the reach and air-reaction requirements the condition held.
const T6HitCondition *t6_hit_condition(T6World *w, T6Fighter *attacker, T6Fighter *defender, const T6Motbin *data, const T6Move *move) {
    attacker->air_reaction_list = 0;
    for (const T6HitCondition *condition = &data->hit_conditions[move->hit_conditions];; condition++) {
        bool passed = true;
        int16_t has_reach = 0, has_air_reaction = 0;
        for (const T6Requirement *requirement = &data->requirements[condition->requirements]; requirement->id != T6_REQ_END; requirement++) {
            bool met = t6_requirement(w, requirement, attacker, defender);
            if (requirement->id == REQ_NEAR) has_reach = 1;
            if (requirement->id == REQ_AIR_REACTION || requirement->id == REQ_BOUND_ALLOWED) has_air_reaction = 1;
            if (!met) {
                passed = false;
                break;
            }
        }
        if (passed) {
            defender->reach_hit = has_reach;
            defender->air_reaction_list = has_air_reaction;
            attacker->damage = t6_hit_condition_damage(condition);
            return condition;
        }
    }
}

const T6HitCondition *t6_hit_condition_query(T6World *w, T6Fighter *attacker, const T6Fighter *defender, const T6Motbin *data,
                                            const T6Move *move) {
    for (const T6HitCondition *condition = &data->hit_conditions[move->hit_conditions];; condition++)
        if (t6_requirements(w, &data->requirements[condition->requirements], attacker, defender)) return condition;
}
