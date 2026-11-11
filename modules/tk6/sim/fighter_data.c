// The steps after load.c has read a fighter's moves and skeleton from the pack db: the anim list, the rig, the move lengths.
#include "sim/fighter.h"

size_t t6_fighter_finish_storage(uint32_t anim_count) {
    return t6_arena_round(anim_count * sizeof(T6Anim *));  // room for anim pointers
}

static int list_anims(T6FighterData *data, const T6FighterFiles *files, T6Arena *arena) {
    data->character = files->character, data->common = files->common, data->embedded = files->embedded;
    const T6AnimBank *banks[3] = {&data->character, &data->common, &data->embedded};
    for (int bank = 0; bank < 3; bank++) data->anim_count += banks[bank]->anim_count;  // total anims across banks
    data->anims = t6_arena_take(arena, data->anim_count * sizeof *data->anims);  // room for one pointer per anim
    if (!data->anims) return -1;
    uint32_t count = 0;
    for (int bank = 0; bank < 3; bank++)  // point the list at every anim
        for (uint32_t index = 0; index < banks[bank]->anim_count; index++) data->anims[count++] = &banks[bank]->anims[index];
    return 0;
}

int t6_fighter_finish(T6FighterData *data, const T6FighterFiles *files, T6Arena *arena) {
    if (!data->moves.start_properties || !data->moves.hit_conditions) return -1;  // both move tables are required
    if (list_anims(data, files, arena)) return -1;
    t6_rig_load(&data->bind, &data->skeleton);
    t6_rig_bind(&data->bind, &data->skeleton);
    // The game's bank loader supplies lengths; the raw extracted move records have zero here.
    // An anim index the lists do not hold is a bad export.
    for (int32_t index = 0; index < data->moves.move_count; index++) {  // set each move's length from its anim
        const T6Anim *anim = t6_fighter_anim(data, data->moves.moves[index].anim);
        if (!anim || !anim->frame_count) return -1;
        data->moves.moves[index].length = anim->frame_count;
    }
    return 0;
}
