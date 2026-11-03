// A character's move data, skeleton and anims, and a stage's collision, from the pack database (src/db/tk5/schema.sql) into the sim's structs. Init only.
#ifndef T5_LOAD_H
#define T5_LOAD_H

#include "sim/fighter.h"
#include "sim/stage.h"

typedef struct sqlite3 sqlite3;

// Where each anim bank starts in the fighter's anim list (T5FighterData.anims): character, common, embedded.
// A mod's anims are text ids in these banks, after the numbered ones.
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
// A bank of clips by its owner in the anim table: one record of `size` bytes per id, read from its file by `parse`
// (0 = ok). Ids without a row stay zero; rows that name one file share one record.
typedef struct {
    size_t size;
    int (*parse)(void *clip, T5Bytes file);
    const char *what;  // for errors
} T5ClipKind;
const char *t5_load_clips_storage(sqlite3 *db, const char *owner, T5ClipKind kind, size_t *bytes);
const char *t5_load_clips(void **clips, uint32_t *count, T5ClipKind kind, sqlite3 *db, const char *owner, T5ReadFile read,
                          void *context, T5Arena *arena);
enum { T5_OWNER_BYTES = 128 };
// The owner of the character's own anim bank: the one its moves name that is neither common nor embedded.
const char *t5_own_anim_bank(sqlite3 *db, const char *character, char owner[T5_OWNER_BYTES]);
// The whole fighter of a character: its anim banks, moves and skeleton, and the steps after them (t5_fighter_finish).
const char *t5_load_fighter_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t5_load_fighter takes
const char *t5_load_fighter(T5FighterData *data, sqlite3 *db, const char *character, T5ReadFile read, void *context, T5Arena *arena);
// A character's move set id and body model id (T5Fighter.chara, chara_40).
const char *t5_load_character(sqlite3 *db, const char *character, uint8_t *chara, int16_t *model);
// A stage's collision: the collision glb and .surfaces file of its stage row.
const char *t5_load_stage_storage(sqlite3 *db, const char *stage, T5ReadFile read, void *context, size_t *bytes);
const char *t5_load_stage(T5Stage *out, sqlite3 *db, const char *stage, T5ReadFile read, void *context, T5Arena *arena);

#endif
