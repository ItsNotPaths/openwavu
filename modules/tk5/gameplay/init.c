// TK5 sim init: reads the loadouts and params, and loads each side's move sets and the stage from the pack database.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gameplay/bot.h"
#include "gameplay/match.h"
#include "load.h"
#include "ow_db.h"
#include "pack_file.h"
#include "sim/constants.h"
#include "sqlite3.h"

static const char DB_PATH[] = "tk5.db";

T5MatchData t5_match_data;

// Loaded on the heap: it stays as loaded, a round copies it in.
static const char *load_moveset(sqlite3 *db, const char *character, const char *body, const T5Moveset **loaded) {
    T5Moveset *moveset = calloc(1, sizeof *moveset);
    if (!moveset) return "out of memory for a move set";
    *loaded = moveset;
    snprintf(moveset->character, sizeof moveset->character, "%s", character);
    int16_t model;
    size_t bytes;
    T5Arena arena;
    const char *failed = t5_load_character(db, character, &moveset->chara, &model);
    if (!failed) failed = t5_load_fighter_storage(db, character, &bytes);
    if (!failed) failed = t5_new_arena(&arena, bytes);
    if (!failed) failed = t5_load_fighter(&moveset->data, db, character, body, t5_read_pack_file, NULL, &arena);
    return failed;
}

// Mokujin's move set of each round: one mix step of the match seed, side and round over the characters with moves.
static const char *pick_rounds(sqlite3 *db, uint64_t seed, uint32_t side, char picks[ROUNDS_MAX][T5_NAME_BYTES]) {
    enum { CANDIDATES_MAX = 64 };
    const uint64_t GOLDEN_MIX = 0x9e3779b97f4a7c15u;  // 2^64 / golden ratio: spreads close seeds apart
    char candidates[CANDIDATES_MAX][T5_NAME_BYTES];
    sqlite3_stmt *rows;
    const char *sql = "SELECT id FROM character WHERE game_index IS NOT NULL AND id NOT IN ('jinpachi', 'jinpachi2') ORDER BY rowid";
    if (sqlite3_prepare_v2(db, sql, -1, &rows, NULL) != SQLITE_OK) return "the character table does not read";
    uint32_t count = 0;
    while (count < CANDIDATES_MAX && sqlite3_step(rows) == SQLITE_ROW)
        snprintf(candidates[count++], T5_NAME_BYTES, "%s", (const char *)sqlite3_column_text(rows, 0));
    sqlite3_finalize(rows);
    if (count == 0) return "no character has a move set to lend";
    for (uint32_t round = 0; round < ROUNDS_MAX; round++) {
        uint64_t mixed = (seed + side * ROUNDS_MAX + round + 1) * GOLDEN_MIX;
        memcpy(picks[round], candidates[(mixed >> 32) % count], T5_NAME_BYTES);
    }
    return NULL;
}

static const char *load_side(sqlite3 *db, uint64_t seed, uint32_t side) {
    T5SideData *picked = &t5_match_data.sides[side];
    if (ow_loadout(side, &picked->loadout, sizeof picked->loadout) != (int32_t)sizeof picked->loadout) return "a loadout is missing or not a T5Loadout";
    const char *character = picked->loadout.character;
    picked->loadout.character[T5_NAME_BYTES - 1] = 0;
    uint8_t chara;
    const char *failed = t5_load_character(db, character, &chara, &picked->model);
    if (failed) return failed;
    char picks[ROUNDS_MAX][T5_NAME_BYTES];
    if (chara == T5_CHARA_NONE) failed = pick_rounds(db, seed, side, picks);
    else for (uint32_t round = 0; round < ROUNDS_MAX; round++) memcpy(picks[round], character, T5_NAME_BYTES);
    uint32_t wins_needed = (uint32_t)ow_param(OW_STR("rounds_to_win"), DEFAULT_WINS_NEEDED);
    uint32_t rounds = wins_needed * 2 - 1 < ROUNDS_MAX ? wins_needed * 2 - 1 : ROUNDS_MAX;
    for (uint32_t round = rounds; round < ROUNDS_MAX; round++) memcpy(picks[round], picks[rounds - 1], T5_NAME_BYTES);  // rounds past the last: no extra load
    for (uint32_t round = 0; round < ROUNDS_MAX && !failed; round++) {
        const T5Moveset **moveset = &picked->round_movesets[round];
        for (uint32_t earlier = 0; earlier < round && !*moveset; earlier++)
            if (strcmp(picks[earlier], picks[round]) == 0) *moveset = picked->round_movesets[earlier];
        if (!*moveset) failed = load_moveset(db, picks[round], character, moveset);
    }
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

static const char *load(uint64_t seed) {
    sqlite3 *db = ow_db_open(DB_PATH, sizeof DB_PATH - 1);
    if (!db) return "the pack has no tk5.db";
    const char *failed = NULL;
    for (uint32_t side = 0; side < T5_FIGHTER_COUNT && !failed; side++) failed = load_side(db, seed, side);
    if (!failed) failed = load_stage(db);
    sqlite3_close(db);
    return failed;
}

OW_EXPORT(ow_sim_init) int32_t ow_sim_init(void) {
    uint64_t seed = ow_match_seed();
    const char *failed = load(seed);
    if (!failed) {
        t5_match_begin(seed);
        failed = t5_bots_begin(seed);
    }
    if (!failed) failed = t5_view_begin();
    if (failed) {
        ow_log((OwStr){(uint32_t)strlen(failed), failed});
        return -1;
    }
    return 0;
}
