// TK5 sim init: reads the loadouts and params, and loads each side's fighter and the stage from the pack database.
#include <stdlib.h>
#include <string.h>

#include "gameplay/bot.h"
#include "gameplay/match.h"
#include "load.h"
#include "ow_db.h"
#include "sqlite3.h"

static const char DB_PATH[] = "tk5.db";

T5MatchData t5_match_data;

// (hole snapshot-range :tags (tk5mod sim)) mutable state and read-only data (anims, motbin tables) share one range; the module does not export the range to snapshot.
// (hole mod-rounds :tags tk5mod :needs param-section) round flow is not from params: rounds to win, round time, round reset.

// A whole pack file. Anim banks point into it, so it is never freed: the module lives for one match.
static T5Bytes read_pack_file(void *context, const char *path) {
    uint32_t length = (uint32_t)strlen(path);
    int32_t size = ow_content_size_raw(path, length);
    uint8_t *data = size > 0 ? malloc((size_t)size) : NULL;
    if (!data || ow_content_read_raw(path, length, 0, data, (uint32_t)size) != size) {
        free(data);
        return (T5Bytes){};
    }
    return (T5Bytes){data, (size_t)size};
}

static const char *new_arena(T5Arena *arena, size_t bytes) {
    *arena = (T5Arena){calloc(1, bytes + 1), bytes, 0};  // + 1: calloc of 0 may give NULL
    return arena->base ? NULL : "out of memory";
}

static const char *load_side(sqlite3 *db, uint32_t side) {
    T5SideData *picked = &t5_match_data.sides[side];
    if (ow_loadout(side, &picked->loadout, sizeof picked->loadout) != (int32_t)sizeof picked->loadout) return "a loadout is missing or not a T5Loadout";
    picked->loadout.character[T5_NAME_BYTES - 1] = 0;
    size_t bytes;
    T5Arena arena;
    const char *failed = t5_load_character(db, picked->loadout.character, &picked->chara, &picked->model);
    if (!failed) failed = t5_load_fighter_storage(db, picked->loadout.character, &bytes);
    if (!failed) failed = new_arena(&arena, bytes);
    if (!failed) failed = t5_load_fighter(&picked->data, db, picked->loadout.character, read_pack_file, NULL, &arena);
    return failed;
}

// The stage param is a stage row's id.
static const char *load_stage(sqlite3 *db) {
    T5MatchData *match_data = &t5_match_data;
    int32_t length = ow_param_text(OW_STR("stage"), match_data->stage_id, sizeof match_data->stage_id - 1);
    if (length < 0 || length >= (int32_t)sizeof match_data->stage_id) return "the stage param is missing or too long";
    match_data->stage_id[length] = 0;
    size_t bytes;
    T5Arena arena;
    const char *failed = t5_load_stage_storage(db, match_data->stage_id, read_pack_file, NULL, &bytes);
    if (!failed) failed = new_arena(&arena, bytes);
    if (!failed) failed = t5_load_stage(&match_data->stage, db, match_data->stage_id, read_pack_file, NULL, &arena);
    return failed;
}

static const char *load(void) {
    sqlite3 *db = ow_db_open(DB_PATH, sizeof DB_PATH - 1);
    if (!db) return "the pack has no tk5.db";
    const char *failed = NULL;
    for (uint32_t side = 0; side < T5_FIGHTER_COUNT && !failed; side++) failed = load_side(db, side);
    if (!failed) failed = load_stage(db);
    sqlite3_close(db);
    return failed;
}

OW_EXPORT(ow_sim_init) int32_t ow_sim_init(void) {
    const char *failed = load();
    if (failed) {
        ow_log((OwStr){(uint32_t)strlen(failed), failed});
        return -1;
    }
    uint64_t seed = ow_match_seed();
    t5_match_begin(seed);
    t5_bots_begin(seed);
    return 0;
}
