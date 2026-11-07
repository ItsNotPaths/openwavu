#include "catalog.h"
#include <stdio.h>
#include <string.h>
#include "openwavu.h"
#include "sqlite3.h"

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

// Panda is Kuma's buttons past his costumes, as in the game. The boss is not picked.
static const char *const ALTERNATES[][2] = {{"kuma", "panda"}};
#define HIDDEN "'panda', 'jinpachi2'"

const char *catalog_load(sqlite3 *db, T5Catalog *catalog) {
    catalog->character_count = load_entries(db,
        "SELECT id, name, (SELECT count(*) FROM costume WHERE costume.character = character.id) FROM character "
        "WHERE id NOT IN (" HIDDEN ") ORDER BY rowid",
        catalog->characters);
    for (int k = 0; k < catalog->character_count; k++) {
        for (size_t pair = 0; pair < sizeof ALTERNATES / sizeof ALTERNATES[0]; pair++) {
            if (strcmp(catalog->characters[k].id, ALTERNATES[pair][0]) == 0) snprintf(catalog->characters[k].alternate, T5_NAME_BYTES, "%s", ALTERNATES[pair][1]);
        }
    }
    catalog->stage_count = load_entries(db, "SELECT id, name, 0 FROM stage ORDER BY rowid", catalog->stages);
    return catalog->character_count > 0 && catalog->stage_count > 0 ? NULL : "the db has no characters or no stages";
}
