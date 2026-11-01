// Loads a character from a db (modules/tk5/load.c) and prints the requirement index of each hit condition and start
// property, or the load error. Usage: load_lists db character
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
    return 0;
}
