// Fighters: clearing refs, reaction lists and move lookups. Their data is built in fighter_data.c.
#include "sim/fighter.h"

#include <stdbool.h>
#include <string.h>

const uint32_t t6_fighter_size = sizeof(T6Fighter), t6_fighter_data_size = sizeof(T6FighterData),
               t6_world_size = sizeof(T6World), t6_motbin_size = sizeof(T6Motbin);

void t6_fighter_clear_refs(T6Fighter *f) {
    const T6Ref none = t6_ref(0, -1);  // a ref with index -1 points at nothing
    f->alternate_move = f->pending_move = f->pushback = f->pushback_curve = none;  // clear all move and pushback refs
    f->blend.previous_move = f->blend.from.move = f->blend.to.move = none;
    f->hit_targets[0] = f->hit_targets[1] = f->hit_targets[2] = -1;  // -1 means no target
    f->throw.partner = -1;  // -1 means no throw partner
    f->pivot_bone = -1;  // -1 means no pivot bone
    f->hit_record = -1;  // -1 means no hit record
}

const T6Reaction *t6_reaction_list(void *world, uint32_t set, uint32_t index) {
    const T6Motbin *motbin = t6_set(world, set);
    return index < (uint32_t)motbin->reaction_count ? &motbin->reactions[index] : NULL;  // NULL when index is out of range
}

T6Ref t6_move_lookup(const T6World *w, const T6Fighter *f, int32_t id) {
    const T6Motbin *own = t6_set(w, f->data);
    if (id & T6_ALIAS_BASE) return t6_ref(f->data, own->aliases[(uint32_t)id & ~(uint32_t)T6_ALIAS_BASE]);  // alias lookup
    if (id < t6_set(w, f->moveset)->move_count) return t6_ref(f->moveset, id);  // ids below the moveset count use the moveset
    const T6Fighter *opponent = t6_object(w, f->opponent);
    if (own->move_count > t6_set(w, opponent->moveset)->move_count) return t6_ref(f->data, id);  // own data has more moves
    return t6_ref(opponent->data, id);
}

int32_t t6_move_alias(const T6World *w, const T6Fighter *f, uint32_t index) {
    return t6_set(w, f->data)->aliases[index];
}

T6Ref t6_own_move(const T6World *w, const T6Fighter *f, int32_t id) {
    int32_t index = id;
    if (id & T6_ALIAS_BASE) index = t6_move_alias(w, f, (uint32_t)id & ~(uint32_t)T6_ALIAS_BASE);  // resolve the alias
    return t6_ref(f->data, index);
}
