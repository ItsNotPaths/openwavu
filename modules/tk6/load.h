// A character's move data, skeleton and anims, and a stage's collision, from the pack database (src/db/tk6/schema.sql) into the sim's structs. Init only.
#ifndef T6_LOAD_H
#define T6_LOAD_H

#include "sim/fighter.h"
#include "sim/stage.h"

typedef struct sqlite3 sqlite3;

// Where each anim bank starts in the fighter's anim list (T6FighterData.anims): character, common, embedded.
// A mod's anims are text ids in these banks, after the numbered ones.
typedef struct {
    uint32_t character, common, embedded;
} T6AnimBases;

static inline T6AnimBases t6_anim_bases(const T6FighterFiles *files) {
    uint32_t common = files->character.anim_count;
    return (T6AnimBases){0, common, common + files->common.anim_count};
}

// The bytes of a pack file (a path from the anim table); size 0 when it is missing. They must outlive the banks.
typedef T6Bytes (*T6ReadFile)(void *context, const char *path);

// Each returns NULL on success, else what went wrong.
const char *t6_load_motbin_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t6_load_motbin takes
const char *t6_load_motbin(T6Motbin *motbin, sqlite3 *db, const char *character, const char *body, T6AnimBases anims, T6Arena *arena);
const char *t6_load_skeleton(T6Skeleton *skeleton, sqlite3 *db, const char *character);
// One anim bank by its owner (a character, common, <character>/embedded). Rows with the same file share one anim.
const char *t6_load_anim_bank_storage(sqlite3 *db, const char *owner, size_t *bytes);
const char *t6_load_anim_bank(T6AnimBank *bank, sqlite3 *db, const char *owner, T6ReadFile read, void *context, T6Arena *arena);
// The three anim banks of the character into files->character, common and embedded.
const char *t6_load_anims_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t6_load_anims takes
const char *t6_load_anims(T6FighterFiles *files, sqlite3 *db, const char *character, T6ReadFile read, void *context, T6Arena *arena);
// A bank of clips by its owner in the anim table: one record of `size` bytes per id, read from its file by `parse`
// (0 = ok). Ids without a row stay zero; rows that name one file share one record.
typedef struct {
    size_t size;
    int (*parse)(void *clip, T6Bytes file);
    const char *what;  // for errors
} T6ClipKind;
const char *t6_load_clips_storage(sqlite3 *db, const char *owner, T6ClipKind kind, size_t *bytes);
const char *t6_load_clips(void **clips, uint32_t *count, T6ClipKind kind, sqlite3 *db, const char *owner, T6ReadFile read,
                          void *context, T6Arena *arena);
enum { T6_OWNER_BYTES = 128 };
// The owner of the character's own anim bank: the one its moves name that is neither common nor embedded.
const char *t6_own_anim_bank(sqlite3 *db, const char *character, char owner[T6_OWNER_BYTES]);
// A fighter: the anim banks and moves of one character on the skeleton and body row of `body`, and the steps after them (t6_fighter_finish).
const char *t6_load_fighter_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t6_load_fighter takes
const char *t6_load_fighter(T6FighterData *data, sqlite3 *db, const char *character, const char *body, T6ReadFile read, void *context,
                            T6Arena *arena);
enum { T6_CHARA_NONE = 0xff };  // a character with no move set of its own (Mokujin): he takes another's each round
// A character's move set id (or T6_CHARA_NONE) and body model id (T6Fighter.chara, chara_40).
const char *t6_load_character(sqlite3 *db, const char *character, uint8_t *chara, int16_t *model);
// A stage's collision: the collision glb and .surfaces file of its stage row.
const char *t6_load_stage_storage(sqlite3 *db, const char *stage, T6ReadFile read, void *context, size_t *bytes);
const char *t6_load_stage(T6Stage *out, sqlite3 *db, const char *stage, T6ReadFile read, void *context, T6Arena *arena);

#endif
