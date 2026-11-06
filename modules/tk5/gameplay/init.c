// TK5 sim init: reads the loadouts and params, and loads each side's fighter and the stage from the pack database.
#include <string.h>

#include "gameplay/bot.h"
#include "gameplay/match.h"
#include "load.h"
#include "ow_db.h"
#include "pack_file.h"
#include "sqlite3.h"

static const char DB_PATH[] = "tk5.db";

T5MatchData t5_match_data;

// (hole mod-rounds :tags tk5mod :needs param-section) round flow is not from params: rounds to win, round time, round reset.

static const char *load_side(sqlite3 *db, uint32_t side) {
    T5SideData *picked = &t5_match_data.sides[side];
    if (ow_loadout(side, &picked->loadout, sizeof picked->loadout) != (int32_t)sizeof picked->loadout) return "a loadout is missing or not a T5Loadout";
    picked->loadout.character[T5_NAME_BYTES - 1] = 0;
    size_t bytes;
    T5Arena arena;
    const char *failed = t5_load_character(db, picked->loadout.character, &picked->chara, &picked->model);
    if (!failed) failed = t5_load_fighter_storage(db, picked->loadout.character, &bytes);
    if (!failed) failed = t5_new_arena(&arena, bytes);
    if (!failed) failed = t5_load_fighter(&picked->data, db, picked->loadout.character, t5_read_pack_file, NULL, &arena);
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
    const char *failed = t5_load_stage_storage(db, match_data->stage_id, t5_read_pack_file, NULL, &bytes);
    if (!failed) failed = t5_new_arena(&arena, bytes);
    if (!failed) failed = t5_load_stage(&match_data->stage, db, match_data->stage_id, t5_read_pack_file, NULL, &arena);
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
    uint64_t seed = ow_match_seed();
    const char *failed = load();
    if (!failed) {
        t5_match_begin(seed);
        failed = t5_bots_begin(seed);
    }
    if (failed) {
        ow_log((OwStr){(uint32_t)strlen(failed), failed});
        return -1;
    }
    return 0;
}
