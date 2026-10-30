// Requirements (code-map 6): the conditions of cancels, hit conditions and conditional properties.
#ifndef T5_REQUIREMENTS_H
#define T5_REQUIREMENTS_H

#include <stdbool.h>

#include "sim/input.h"
#include "sim/world.h"

// Requirement ids are 0..T5_REQUIREMENT_COUNT - 1; the next id ends a list. Ids from T5_PROPERTY_BASE on are instant
// properties and pass.
enum : uint16_t {
    T5_REQUIREMENT_COUNT = 327,
    T5_REQ_END = T5_REQUIREMENT_COUNT,
    REQ_NEAR = 34,           // the distance is at most the param; a hit condition that holds it is a reach hit (reach_hit)
    REQ_AIR_REACTION = 286,  // the opponent is off the ground; a hit condition that holds it reacts in the air from its own list
};

// f owns the list, `opponent` is the other object (the opponent for cancels). f is written by the throw requirements
// (2..33: the cache of t5_throw_look) and the punch latch requirements (106..108); 227 and 237 draw from w->rng.
bool t5_requirement(T5World *w, const T5Requirement *requirement, T5Fighter *f, const T5Fighter *opponent);
bool t5_requirements(T5World *w, const T5Requirement *list, T5Fighter *f, const T5Fighter *opponent); // stops at the first false
float t5_fall_dy(const T5Fighter *f);  // y change of the next gravity step, 0 on the ground

// First hit condition of the move whose requirements pass (both loop until one does, as in the game).
// t5_hit_condition also sets the defender's air_reaction_list and reach_hit, and the attacker's damage.
const T5HitCondition *t5_hit_condition(T5World *w, T5Fighter *attacker, T5Fighter *defender, const T5Motbin *data,
                                      const T5Move *move);
const T5HitCondition *t5_hit_condition_query(T5World *w, T5Fighter *attacker, const T5Fighter *defender, const T5Motbin *data,
                                            const T5Move *move);  // first passing hit condition; no reach or air-reaction state

#endif
