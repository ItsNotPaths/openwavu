// A character's move data and skeleton from the pack database (src/db/tk5/schema.sql) into the sim's structs. Init only.
#ifndef T5_LOAD_H
#define T5_LOAD_H

#include "sim/motbin.h"
#include "sim/skel.h"

typedef struct sqlite3 sqlite3;

// Where each anim bank starts in the fighter's anim list (T5FighterData.anims): character, common, embedded.
typedef struct {
    uint32_t character, common, embedded;
} T5AnimBases;

// Each returns NULL on success, else what went wrong.
const char *t5_load_motbin_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t5_load_motbin takes
const char *t5_load_motbin(T5Motbin *motbin, sqlite3 *db, const char *character, T5AnimBases anims, T5Arena *arena);
const char *t5_load_skeleton(T5Skeleton *skeleton, sqlite3 *db, const char *character);

#endif
