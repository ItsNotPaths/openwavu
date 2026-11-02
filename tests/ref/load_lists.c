// Loads a character from a db (modules/tk5/load.c) and prints the requirement index of each hit condition and start
// property, the first two pushback indices of each reaction, each requirement param, each extra property value, and each
// cancel's command code and tracking pick, each move's compare id and anim index, and each move pool value, or the load error. Usage: load_lists db character
#include <stdio.h>
#include <stdlib.h>

#include "load.h"
#include "sqlite3.h"

int main(int argc, char **argv) {
    sqlite3 *db;
    if (argc != 3 || sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return 2;
    size_t bytes;
    const char *failed = t5_load_motbin_storage(db, argv[2], &bytes);
    T5Arena arena = {malloc(bytes), bytes, 0};
    T5Motbin motbin;
    if (!failed) failed = t5_load_motbin(&motbin, db, argv[2], (T5AnimBases){}, &arena);
    if (failed) return printf("%s\n", failed), 1;
    for (int32_t index = 0; index < motbin.hit_condition_count; index++) printf("%d ", (int32_t)motbin.hit_conditions[index].requirements);
    for (int32_t index = 0; index < motbin.start_property_count; index++) printf("%d ", (int32_t)motbin.start_properties[index].requirements);
    for (int32_t index = 0; index < motbin.reaction_count; index++)
        printf("%d %d ", (int32_t)motbin.reactions[index].pushback[0].index, (int32_t)motbin.reactions[index].pushback[1].index);
    for (int32_t index = 0; index < motbin.requirement_count; index++) printf("%d ", motbin.requirements[index].param);
    for (int32_t index = 0; index < motbin.property_count; index++) printf("%d ", motbin.properties[index].value);
    for (int32_t index = 0; index < motbin.cancel_count; index++)
        printf("%#x %d ", motbin.cancels[index].command.code, motbin.cancels[index].tracking_pick);
    for (int32_t index = 0; index < motbin.move_count; index++) printf("%d/%u ", motbin.moves[index].compare_id, motbin.moves[index].anim);
    for (int32_t index = 0; index < motbin.id_pool_count; index++) printf("%d ", motbin.id_pool[index]);
    return 0;
}
