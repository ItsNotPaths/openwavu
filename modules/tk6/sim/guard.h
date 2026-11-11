// Guard: the guard stance a fighter takes from the held direction, their guard mask, and whether
// they guard an attack. guard.c.
#ifndef T6_GUARD_H
#define T6_GUARD_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/world.h"

// T6Fighter.stance_rule: how the movement step finds the stance. A move change resets it to by input; `PROP_STANCE_RULE` and the
// next-move transition class set the others.
enum T6StanceRule : uint8_t {
    STANCE_BY_INPUT,     // the held direction picks standing or crouching guard (moves with T6_MOVE_GUARD_BY_INPUT)
    STANCE_HELD,         // the held direction picks one of the alternative stances
    STANCE_HELD_LOW,     // as STANCE_HELD, and every attack also hits the fighter low
    STANCE_BY_OPPONENT,  // the opponent's attack kind picks standing or no guard
};

// T6Fighter.attack_kind (the high byte of the hit level of the move). The kinds the stance and the wall code tell apart.
enum : uint8_t {
    ATTACK_KIND_LOW = 1,
    ATTACK_KIND_STAND_FIRST = 2, ATTACK_KIND_STAND_LAST = 4,  // the opponent's stance rule makes them stand against these
    ATTACK_KIND_KEEPS_HEADING = 12,                           // a wall slide keeps the pushback heading of the hit
};

// Steps 14 and 15 of the movement step: the stance, then the guard mask. Runs after the counters (airborne).
void t6_move_guard(const T6World *w, T6Fighter *f, const T6Fighter *opponent);

// The guard mask of the state word (also the end of the move change). A state with STATE_GUARD_LOCKED does not guard,
// unless the fighter has neutral guard.
void t6_state_guard(T6Fighter *f);

// The opponent is in front: an angle from the facing (opp_angle, angle_84) under a quarter turn.
[[nodiscard]] bool t6_in_front(int16_t angle);

// The defender guards the attack: their guard mask holds a height of the attack and the attacker is in front of them.
[[nodiscard]] bool t6_guards_attack(const T6Fighter *defender, const T6Fighter *attacker);

#endif
