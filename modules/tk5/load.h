// A character's move data, skeleton, anims and hand clips from the pack database (src/db/tk5/schema.sql) into the sim's structs. Init only.
#ifndef T5_LOAD_H
#define T5_LOAD_H

#include "sim/fighter.h"
#include "visual/hand_bank.h"

typedef struct sqlite3 sqlite3;

// Where each anim bank starts in the fighter's anim list (T5FighterData.anims): character, common, embedded.
typedef struct {
    uint32_t character, common, embedded;
} T5AnimBases;

static inline T5AnimBases t5_anim_bases(const T5FighterFiles *files) {
    uint32_t common = files->character.anim_count;
    return (T5AnimBases){0, common, common + files->common.anim_count};
}

// The bytes of a pack file (a path from the anim table); size 0 when it is missing. They must outlive the banks.
typedef T5Bytes (*T5ReadFile)(void *context, const char *path);

// Each returns NULL on success, else what went wrong.
const char *t5_load_motbin_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t5_load_motbin takes
const char *t5_load_motbin(T5Motbin *motbin, sqlite3 *db, const char *character, T5AnimBases anims, T5Arena *arena);
const char *t5_load_skeleton(T5Skeleton *skeleton, sqlite3 *db, const char *character);
// One anim bank by its owner (a character, common, <character>/embedded). Rows with the same file share one anim.
const char *t5_load_anim_bank_storage(sqlite3 *db, const char *owner, size_t *bytes);
const char *t5_load_anim_bank(T5AnimBank *bank, sqlite3 *db, const char *owner, T5ReadFile read, void *context, T5Arena *arena);
// The three anim banks of the character into files->character, common and embedded.
const char *t5_load_anims_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t5_load_anims takes
const char *t5_load_anims(T5FighterFiles *files, sqlite3 *db, const char *character, T5ReadFile read, void *context, T5Arena *arena);
// The finger pose library and gestures of the character (owners <character>/hand_poses, <its bank>/hand_gestures).
const char *t5_load_hands_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t5_load_hands takes
const char *t5_load_hands(T5HandBanks *banks, sqlite3 *db, const char *character, T5ReadFile read, void *context, T5Arena *arena);

#endif
