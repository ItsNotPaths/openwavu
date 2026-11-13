// Requirements: the conditions of cancels, hit conditions and conditional properties.
#ifndef T6_REQUIREMENTS_H
#define T6_REQUIREMENTS_H

#include <stdbool.h>

#include "sim/input.h"
#include "sim/world.h"

// Requirement ids are 0..T6_REQUIREMENT_COUNT - 1; the next id ends a list. Ids from T6_PROPERTY_BASE on are instant
// properties and pass. Ids from REQ_TK6_FIRST on are new in TK6 (docs/requirements.md "NEW TK6 ids").
enum : uint16_t {
    REQ_NEAR = 34,           // the distance is at most the param; a hit condition that holds it is a reach hit (reach_hit)
    REQ_AIR_REACTION = 286,  // the opponent is off the ground; a hit condition that holds it reacts in the air from its own list
    REQ_TK6_FIRST = 327,
    REQ_BOUND_ALLOWED = REQ_TK6_FIRST,  // like REQ_AIR_REACTION, a hit condition that holds it reacts in the air from its own list
    REQ_THIRD_FACING_FIRST = 357, REQ_THIRD_FACING_LAST = 368,  // TK6 0x181..0x18c: the loader options of the facing tests
    T6_REQUIREMENT_COUNT = 369,
    T6_REQ_END = T6_REQUIREMENT_COUNT,
};

// f owns the list, `opponent` is the other object (the opponent for cancels). f is written by the throw requirements
// (2..33: the cache of t6_throw_look) and the punch latch requirements (106..108); 227 and 237 draw from w->rng.
bool t6_requirement(T6World *w, const T6Requirement *requirement, T6Fighter *f, const T6Fighter *opponent);
bool t6_requirements(T6World *w, const T6Requirement *list, T6Fighter *f, const T6Fighter *opponent); // stops at the first false
float t6_fall_dy(const T6Fighter *f);  // y change of the next gravity step, 0 on the ground

// First hit condition of the move whose requirements pass (both loop until one does, as in the game).
// t6_hit_condition also sets the defender's air_reaction_list and reach_hit, and the attacker's damage.
const T6HitCondition *t6_hit_condition(T6World *w, T6Fighter *attacker, T6Fighter *defender, const T6Motbin *data,
                                      const T6Move *move);
const T6HitCondition *t6_hit_condition_query(T6World *w, T6Fighter *attacker, const T6Fighter *defender, const T6Motbin *data,
                                            const T6Move *move);  // first passing hit condition; no reach or air-reaction state

#endif
