// Fighter data from the bytes of the .t5m and .t5b files of tools/*2bin.py and the caller's anim banks; load.c reads the
// same from the pack db and shares the steps after the parse.
#include <string.h>

#include "sim/fighter.h"

static uint32_t anim_count(const T5FighterFiles *files) {
    return files->character.anim_count + files->common.anim_count + files->embedded.anim_count;
}

size_t t5_fighter_finish_storage(uint32_t anim_count, int32_t move_count) {
    return t5_arena_round(anim_count * sizeof(T5Anim *)) +  // room for anim pointers
           t5_arena_round((size_t)move_count * sizeof(T5Move));    // and the copy of the moves
}

bool t5_fighter_storage(const T5FighterFiles *files, size_t *bytes) {
    if (!t5_motbin_storage(files->moves, bytes)) return false;  // bad moves
    *bytes += t5_fighter_finish_storage(anim_count(files), t5_motbin_move_count(files->moves));
    return true;
}

static int list_anims(T5FighterData *data, const T5FighterFiles *files, T5Arena *arena) {
    data->character = files->character, data->common = files->common, data->embedded = files->embedded;
    const T5AnimBank *banks[3] = {&data->character, &data->common, &data->embedded};
    for (int bank = 0; bank < 3; bank++) data->anim_count += banks[bank]->anim_count;  // total anims across banks
    data->anims = t5_arena_take(arena, data->anim_count * sizeof *data->anims);  // room for one pointer per anim
    if (!data->anims) return -1;
    uint32_t count = 0;
    for (int bank = 0; bank < 3; bank++)  // point the list at every anim
        for (uint32_t index = 0; index < banks[bank]->anim_count; index++) data->anims[count++] = &banks[bank]->anims[index];
    return 0;
}

int t5_fighter_finish(T5FighterData *data, const T5FighterFiles *files, T5Arena *arena) {
    if (!data->moves.start_properties || !data->moves.hit_conditions) return -1;  // both move tables are required
    if (list_anims(data, files, arena)) return -1;
    t5_rig_load(&data->bind, &data->skeleton);
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

int t5_fighter_build(T5FighterData *data, const T5FighterFiles *files, T5Arena *arena) {
    memset(data, 0, sizeof *data);
    if (t5_motbin_parse(&data->moves, files->moves, arena)) return -1;
    if (t5_skeleton_parse(&data->skeleton, files->skeleton)) return -1;
    return t5_fighter_finish(data, files, arena);
}
