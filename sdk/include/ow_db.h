// openwavu database helper: SQLite built for wasm32, linked into a pack's modules. Opens a pack file
// read-only through a VFS on ow_content_read. Query at init only, never in a sim step.
#ifndef OW_DB_H
#define OW_DB_H

#include "openwavu.h"

typedef struct sqlite3 sqlite3;

// (hole sdk-sqlite :tags (sdk mech)) no SQLite build for wasm32 in the SDK, no read-only VFS on ow_content_read, and ow build does not link it by itself.
static inline sqlite3 *ow_db_open(const char *path, uint32_t path_len) {
	return 0;
}

#endif
