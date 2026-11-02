// openwavu database helper: SQLite built for wasm32, linked into a pack's modules (libow_db.a). Opens a pack file
// read-only through a VFS on ow_content_read. Query at init only, never in a sim step.
#ifndef OW_DB_H
#define OW_DB_H

#include "openwavu.h"

typedef struct sqlite3 sqlite3;

// The pack file at path, read-only; NULL if it is missing or not a database. Close it with sqlite3_close.
sqlite3 *ow_db_open(const char *path, uint32_t path_len);

#endif
