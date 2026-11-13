// The damage pass: the hits of the frame become damage, health and KO, and pick the reaction list.
#ifndef T6_DAMAGE_H
#define T6_DAMAGE_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/hit.h"
#include "sim/world.h"

// T6Fighter.reaction_rule: how a hit of the move makes the defender react. The top two bits of the damage word of the move's
// hit condition.
enum T6ReactionRule : uint8_t {
    REACT_ALWAYS,    // the defender plays a reaction move
    REACT_HARMLESS,  // no damage and no reaction: the hit only touches
    REACT_GROUNDED,  // a reaction only on the ground, away from a wall
    REACT_NEVER,     // damage, but no reaction move
};

// Self damage of the move this frame (T6Fighter.self_damage): it hurts or heals its own fighter, or hurts the fighter it throws,
// by `points`; 0 points is the damage of the move. As a hit it also counts in damage_hits_frame. The decide pass ends it.
enum T6SelfDamageEffect : uint8_t { SELF_DAMAGE_NONE, SELF_DAMAGE_HURT, SELF_DAMAGE_HEAL, SELF_DAMAGE_HURT_THROWN };

typedef struct {
    enum T6SelfDamageEffect effect;  // none, hurt self, heal self, or hurt the fighter being thrown
    bool as_hit;                     // counts as a hit (also in damage_hits_frame) or as plain damage
    int16_t points;                  // health amount; 0 means use the damage of the move
} T6SelfDamage;

// `PROP_SELF_DAMAGE_FIRST`..`PROP_SELF_DAMAGE_LAST` start a self damage: the rows in id order, the property value is the points.
static constexpr uint16_t SELF_DAMAGE_PROPERTY_FIRST = 32827;
enum { SELF_DAMAGE_PROPERTIES = 6 };
extern const T6SelfDamage T6_SELF_DAMAGE_ROWS[SELF_DAMAGE_PROPERTIES];  // three effects as a hit, then the same as plain damage

// The record's flags and final damage copied to the result bytes of the defender and the attacker. The damage is the absolute
// value; guarded, clean hit and counter hit come from the record's flags.
void t6_hit_result(const T6World *w, T6Fighter *defender, const T6HitRecord *record);
// Classify the records of the defender, pick the main one and its reaction list, damage, health, KO.
void t6_damage_resolve(T6World *w, T6Fighter *defender);
void t6_damage_pass(T6World *w);  // once per frame: clear counters, resolve both fighters, then the extras

#endif
