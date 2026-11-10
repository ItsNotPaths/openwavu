// Loads a character from a db (modules/tk5/load.c) and prints one line per non-empty table of what the sim reads, or the
// load error. Usage: load_lists db character
#include <stdio.h>
#include <stdlib.h>

#include "load.h"
#include "sqlite3.h"

#define LINE(name, count, format, ...)                                                                                     \
    if (count) {                                                                                                           \
        printf(name ":");                                                                                                  \
        for (int32_t index = 0; index < count; index++) printf(" " format, __VA_ARGS__);                                  \
        printf("\n");                                                                                                      \
    }

int main(int argc, char **argv) {
    sqlite3 *db;
    if (argc != 3 || sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return 2;
    size_t bytes;
    const char *failed = t5_load_motbin_storage(db, argv[2], &bytes);
    T5Arena arena = {malloc(bytes), bytes, 0};
    T5Motbin m;
    if (!failed) failed = t5_load_motbin(&m, db, argv[2], argv[2], (T5AnimBases){}, &arena);
    if (failed) return printf("%s\n", failed), 1;
    LINE("move", m.move_count, "%d/%u/%d/%d/%#x/%#x/%#x", m.moves[index].compare_id, m.moves[index].anim, m.moves[index].next_move,
         m.moves[index].extra_props, m.moves[index].vuln, m.moves[index].hit_level, m.moves[index].flags);
    LINE("cancel", m.cancel_count, "%#x/%d/%d/%#x", m.cancels[index].command.code, m.cancels[index].move, m.cancels[index].tracking_pick,
         m.cancels[index].extradata);
    LINE("requirement", m.requirement_count, "%d/%d", m.requirements[index].id, m.requirements[index].param);
    LINE("start_prop", m.start_property_count, "%d/%d", (int32_t)m.start_properties[index].requirements, m.start_properties[index].id);
    LINE("extra_prop", m.property_count, "%d", m.properties[index].value);
    LINE("move_pool", m.id_pool_count, "%d", m.id_pool[index]);
    return 0;
}
