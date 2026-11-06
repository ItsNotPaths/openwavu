// Fighters: clearing refs, reaction lists and move lookups. Their data is built in fighter_data.c.
#include "sim/fighter.h"

#include <stdbool.h>
#include <string.h>

const uint32_t t5_fighter_size = sizeof(T5Fighter), t5_fighter_data_size = sizeof(T5FighterData),
               t5_world_size = sizeof(T5World), t5_motbin_size = sizeof(T5Motbin);

void t5_fighter_clear_refs(T5Fighter *f) {
    const T5Ref none = t5_ref(0, -1);  // a ref with index -1 points at nothing
    f->alternate_move = f->pending_move = f->pushback = f->pushback_curve = none;  // clear all move and pushback refs
    f->blend.previous_move = f->blend.from.move = f->blend.to.move = none;
    f->hit_targets[0] = f->hit_targets[1] = f->hit_targets[2] = -1;  // -1 means no target
    f->throw.partner = -1;  // -1 means no throw partner
    f->pivot_bone = -1;  // -1 means no pivot bone
    f->hit_record = -1;  // -1 means no hit record
}

const T5Reaction *t5_reaction_list(void *world, uint32_t set, uint32_t index) {
    const T5Motbin *motbin = t5_set(world, set);
    return index < (uint32_t)motbin->reaction_count ? &motbin->reactions[index] : NULL;  // NULL when index is out of range
}

T5Ref t5_move_lookup(const T5World *w, const T5Fighter *f, int32_t id) {
    const T5Motbin *own = t5_set(w, f->data);
    if (id & T5_ALIAS_BASE) return t5_ref(f->data, own->aliases[(uint32_t)id & ~(uint32_t)T5_ALIAS_BASE]);  // alias lookup
    if (id < t5_set(w, f->moveset)->move_count) return t5_ref(f->moveset, id);  // ids below the moveset count use the moveset
    const T5Fighter *opponent = t5_object(w, f->opponent);
    if (own->move_count > t5_set(w, opponent->moveset)->move_count) return t5_ref(f->data, id);  // own data has more moves
    return t5_ref(opponent->data, id);
}

int32_t t5_move_alias(const T5World *w, const T5Fighter *f, uint32_t index) {
    return t5_set(w, f->data)->aliases[index];
}

T5Ref t5_own_move(const T5World *w, const T5Fighter *f, int32_t id) {
    int32_t index = id;
    if (id & T5_ALIAS_BASE) index = t5_move_alias(w, f, (uint32_t)id & ~(uint32_t)T5_ALIAS_BASE);  // resolve the alias
    return t5_ref(f->data, index);
}
