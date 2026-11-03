#include "catalog.h"
#include <stdio.h>
#include "openwavu.h"
#include "ow_db.h"
#include "sqlite3.h"

static const char DB_PATH[] = "tk5.db";

// Rows of (id, name, costumes); a row with no id is left out.
static int load_entries(sqlite3 *db, const char *sql, T5Entry *entries) {
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, sql, -1, &rows, NULL) != SQLITE_OK) return 0;
    int count = 0;
    while (count < CATALOG_ENTRIES_MAX && sqlite3_step(rows) == SQLITE_ROW) {
        const char *id = (const char *)sqlite3_column_text(rows, 0);
        const char *name = (const char *)sqlite3_column_text(rows, 1);
        if (!id) continue;
        T5Entry *entry = &entries[count++];
        snprintf(entry->id, sizeof entry->id, "%s", id);
        snprintf(entry->name, sizeof entry->name, "%s", name ? name : id);
        entry->costumes = (uint32_t)sqlite3_column_int(rows, 2);
    }
    sqlite3_finalize(rows);
    return count;
}

const char *catalog_load(T5Catalog *catalog) {
    sqlite3 *db = ow_db_open(DB_PATH, sizeof DB_PATH - 1);
    if (!db) return "the pack has no tk5.db";
    catalog->character_count = load_entries(db,
        "SELECT id, name, (SELECT count(*) FROM costume WHERE costume.character = character.id) FROM character ORDER BY rowid",
        catalog->characters);
    catalog->stage_count = load_entries(db, "SELECT id, name, 0 FROM stage ORDER BY rowid", catalog->stages);
    sqlite3_close(db);
    return catalog->character_count > 0 && catalog->stage_count > 0 ? NULL : "the db has no characters or no stages";
}
