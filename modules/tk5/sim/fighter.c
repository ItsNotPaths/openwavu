// Fighter data from the bytes of the .t5m, .t5a and .t5b files of tools/*2bin.py; move lookups.
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

// An absent embedded bank has no bytes.
static int32_t bank_count(T5Bytes bytes) { return bytes.size ? t5_anim_bank_count(bytes) : 0; }

bool t5_fighter_storage(const T5FighterFiles *files, size_t *bytes) {
    int32_t counts[3] = {bank_count(files->character), bank_count(files->common), bank_count(files->embedded)};
    if (!t5_motbin_storage(files->moves, bytes) || counts[0] < 0 || counts[1] < 0 || counts[2] < 0)  // bad moves or banks
        return false;
    const T5Bytes banks[3] = {files->character, files->common, files->embedded};
    uint32_t anims = 0;
    for (int bank = 0; bank < 3; bank++) {  // sum storage for each bank
        if (banks[bank].size) *bytes += t5_arena_round(t5_anim_bank_bytes((uint32_t)counts[bank]));  // absent banks take no space
        anims += (uint32_t)counts[bank];
    }
    *bytes += t5_arena_round(anims * sizeof(T5Anim *)) +  // room for anim pointers
              t5_arena_round((size_t)t5_motbin_move_count(files->moves) * sizeof(T5Move));
    return true;
}

static int parse_banks(T5FighterData *data, const T5FighterFiles *files, T5Arena *arena) {
    if (t5_anim_bank_parse(&data->character, files->character, arena)) return -1;
    if (t5_anim_bank_parse(&data->common, files->common, arena)) return -1;
    if (files->embedded.size && t5_anim_bank_parse(&data->embedded, files->embedded, arena)) return -1;  // embedded is optional
    const T5AnimBank *banks[3] = {&data->character, &data->common, &data->embedded};
    for (int bank = 0; bank < 3; bank++) data->anim_count += banks[bank]->anim_count;  // total anims across banks
    data->anims = t5_arena_take(arena, data->anim_count * sizeof *data->anims);  // room for one pointer per anim
    if (!data->anims) return -1;
    uint32_t count = 0;
    for (int bank = 0; bank < 3; bank++)  // point the list at every anim
        for (uint32_t index = 0; index < banks[bank]->anim_count; index++) data->anims[count++] = &banks[bank]->anims[index];
    return 0;
}

int t5_fighter_build(T5FighterData *data, const T5FighterFiles *files, T5Arena *arena) {
    memset(data, 0, sizeof *data);
    if (t5_motbin_parse(&data->moves, files->moves, arena)) return -1;
    if (!data->moves.start_properties || !data->moves.hit_conditions) return -1;  // both move tables are required
    if (parse_banks(data, files, arena)) return -1;
    if (t5_skeleton_parse(&data->skeleton, &data->bind, files->skeleton)) return -1;
    t5_rig_bind(&data->bind, &data->skeleton);
    // The game's bank loader supplies lengths; the raw extracted move records have zero here.
    // An anim index the lists do not hold is a bad export.
    for (int32_t index = 0; index < data->moves.move_count; index++) {  // set each move's length from its anim
        const T5Anim *anim = t5_fighter_anim(data, data->moves.moves[index].anim);
        if (!anim || !anim->frame_count) return -1;
        data->moves.moves[index].length = anim->frame_count;
    }
    size_t moves_bytes = (size_t)data->moves.move_count * sizeof(T5Move);
    data->original_moves = t5_arena_take(arena, moves_bytes);
    if (!data->original_moves) return -1;
    memcpy(data->original_moves, data->moves.moves, moves_bytes);  // keep a copy of the moves as built
    return 0;
}

const T5Reaction *t5_reaction_list(void *world, uint32_t set, uint32_t index) {
    T5Motbin *motbin = t5_set_mutable(world, set);
    if (index >= (uint32_t)motbin->reaction_count) return NULL;  // NULL when index is out of range
    T5Reaction *reaction = &motbin->reactions[index];
    for (int slot = 0; slot < 7; slot++) reaction->pushback[slot].set = (uint8_t)set;  // tag each pushback slot with the set
    return reaction;
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
