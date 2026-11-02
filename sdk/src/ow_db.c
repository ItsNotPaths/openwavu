// The SDK's SQLite: a read-only VFS named "ow" over ow_content_read, so a module reads only the pages its queries need.
// No locks, no journal, fixed randomness and time: the sim must be deterministic.
#include <string.h>

#include "ow_db.h"
#include "../../vendor/sqlite/sqlite3.h"

enum { PATH_MAX_BYTES = 512 };

typedef struct {
	sqlite3_file base;
	char path[PATH_MAX_BYTES];
	uint32_t path_len;
} PackFile;

static int file_close(sqlite3_file *file) { return SQLITE_OK; }

static int file_read(sqlite3_file *file, void *buf, int amount, sqlite3_int64 offset) {
	PackFile *f = (PackFile *)file;
	int32_t got = ow_content_read_raw(f->path, f->path_len, (uint32_t)offset, buf, (uint32_t)amount);
	if (got < 0) return SQLITE_IOERR_READ;
	if (got < amount) {
		memset((char *)buf + got, 0, (size_t)(amount - got));
		return SQLITE_IOERR_SHORT_READ;
	}
	return SQLITE_OK;
}

static int file_write(sqlite3_file *file, const void *buf, int amount, sqlite3_int64 offset) { return SQLITE_READONLY; }
static int file_truncate(sqlite3_file *file, sqlite3_int64 size) { return SQLITE_READONLY; }
static int file_sync(sqlite3_file *file, int flags) { return SQLITE_OK; }

static int file_size(sqlite3_file *file, sqlite3_int64 *size) {
	PackFile *f = (PackFile *)file;
	int32_t bytes = ow_content_size_raw(f->path, f->path_len);
	if (bytes < 0) return SQLITE_IOERR_FSTAT;
	*size = bytes;
	return SQLITE_OK;
}

static int file_lock(sqlite3_file *file, int level) { return SQLITE_OK; }
static int file_check_lock(sqlite3_file *file, int *out) { return *out = 0, SQLITE_OK; }
static int file_control(sqlite3_file *file, int op, void *arg) { return SQLITE_NOTFOUND; }
static int file_sector_size(sqlite3_file *file) { return 4096; }
static int file_device(sqlite3_file *file) { return SQLITE_IOCAP_IMMUTABLE; }

static const sqlite3_io_methods PACK_FILE_METHODS = {
	.iVersion = 1,
	.xClose = file_close,
	.xRead = file_read,
	.xWrite = file_write,
	.xTruncate = file_truncate,
	.xSync = file_sync,
	.xFileSize = file_size,
	.xLock = file_lock,
	.xUnlock = file_lock,
	.xCheckReservedLock = file_check_lock,
	.xFileControl = file_control,
	.xSectorSize = file_sector_size,
	.xDeviceCharacteristics = file_device,
};

static int vfs_open(sqlite3_vfs *vfs, const char *name, sqlite3_file *file, int flags, int *out_flags) {
	PackFile *f = (PackFile *)file;
	f->base.pMethods = NULL;  // SQLite skips xClose on a failed open
	if (!name || (flags & SQLITE_OPEN_READWRITE) || !(flags & SQLITE_OPEN_MAIN_DB)) return SQLITE_CANTOPEN;
	size_t len = strlen(name);
	if (len >= PATH_MAX_BYTES) return SQLITE_CANTOPEN;
	memcpy(f->path, name, len);
	f->path_len = (uint32_t)len;
	if (ow_content_size_raw(f->path, f->path_len) < 0) return SQLITE_CANTOPEN;
	f->base.pMethods = &PACK_FILE_METHODS;
	if (out_flags) *out_flags = SQLITE_OPEN_READONLY;
	return SQLITE_OK;
}

static int vfs_delete(sqlite3_vfs *vfs, const char *name, int sync_dir) { return SQLITE_READONLY; }

static int vfs_access(sqlite3_vfs *vfs, const char *name, int flags, int *out) {
	*out = 0;  // no journals or WAL files exist
	return SQLITE_OK;
}

static int vfs_full_pathname(sqlite3_vfs *vfs, const char *name, int out_size, char *out) {
	sqlite3_snprintf(out_size, out, "%s", name);
	return SQLITE_OK;
}

static int vfs_randomness(sqlite3_vfs *vfs, int bytes, char *out) {
	memset(out, 0, (size_t)bytes);
	return bytes;
}

static int vfs_sleep(sqlite3_vfs *vfs, int microseconds) { return 0; }
static int vfs_current_time(sqlite3_vfs *vfs, sqlite3_int64 *out) { return *out = 0, SQLITE_OK; }
static int vfs_last_error(sqlite3_vfs *vfs, int size, char *out) { return 0; }

static sqlite3_vfs PACK_VFS = {
	.iVersion = 2,
	.szOsFile = sizeof(PackFile),
	.mxPathname = PATH_MAX_BYTES,
	.zName = "ow",
	.xOpen = vfs_open,
	.xDelete = vfs_delete,
	.xAccess = vfs_access,
	.xFullPathname = vfs_full_pathname,
	.xRandomness = vfs_randomness,
	.xSleep = vfs_sleep,
	.xGetLastError = vfs_last_error,
	.xCurrentTimeInt64 = vfs_current_time,
};

int sqlite3_os_init(void) { return sqlite3_vfs_register(&PACK_VFS, 1); }
int sqlite3_os_end(void) { return SQLITE_OK; }

sqlite3 *ow_db_open(const char *path, uint32_t path_len) {
	char uri[PATH_MAX_BYTES + 32];
	if (path_len >= PATH_MAX_BYTES) return NULL;
	sqlite3_snprintf(sizeof uri, uri, "file:%.*s?immutable=1", (int)path_len, path);
	sqlite3 *db = NULL;
	if (sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, "ow") != SQLITE_OK) {
		sqlite3_close(db);
		return NULL;
	}
	return db;
}
