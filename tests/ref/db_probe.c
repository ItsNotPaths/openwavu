// A module that links the SDK's SQLite and reads one value from the pack file x.db.
#include <stddef.h>

#include "ow_db.h"
#include "sqlite3.h"

OW_EXPORT(probe) int32_t probe(void) {
	sqlite3 *db = ow_db_open("x.db", 4);
	if (!db) return -1;
	sqlite3_stmt *query;
	int32_t value = -2;
	if (sqlite3_prepare_v2(db, "SELECT value FROM t WHERE key = 'answer'", -1, &query, NULL) == SQLITE_OK && sqlite3_step(query) == SQLITE_ROW)
		value = sqlite3_column_int(query, 0);
	sqlite3_finalize(query);
	sqlite3_close(db);
	return value;
}
