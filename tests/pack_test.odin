package tests

import "core:os"
import "core:testing"
import "../src/content"
import "../src/db"
import "../src/titlepack"

// A packed folder opens in place: its database reads back as a database, other files read at an offset,
// and paths outside the pack are not found.
@(test)
pack_serves_its_files_and_db :: proc(t: ^testing.T) {
	DIR :: "build/pack_test"
	TAR :: DIR + ".tar"
	os.make_directory(DIR)
	defer {
		os.remove_all(DIR)
		os.remove(TAR)
	}
	w, err := db.create(DIR + "/game.db", "CREATE TABLE t (key TEXT PRIMARY KEY, value INTEGER);")
	testing.expect_value(t, err, "")
	db.insert(&w, "t", "answer", i64(42))
	testing.expect_value(t, db.finish(&w), "")
	_ = os.write_entire_file(DIR + "/notes.txt", transmute([]byte)string("hello pack"))
	_ = os.write_entire_file(DIR + "/" + titlepack.MANIFEST, transmute([]byte)string("id = \"x\"\nversion = \"1\"\n"))
	if !testing.expect_value(t, titlepack.write_tar(DIR, TAR), "") do return

	p, ok := content.open_pack(TAR)
	if !testing.expect(t, ok, "the pack did not open") do return
	defer content.close_pack(&p)

	size, has_db := content.pack_size(p, "game.db")
	if !testing.expect(t, has_db) do return
	bytes := make([]byte, size, context.temp_allocator)
	n, _ := content.pack_read(p, "game.db", 0, bytes)
	testing.expect_value(t, n, size)
	testing.expect_value(t, query_value(bytes, "SELECT value FROM t WHERE key = 'answer'"), 42)

	buf: [16]byte
	n, ok = content.pack_read(p, "notes.txt", 6, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(buf[:n]), "pack")

	_, ok = content.pack_size(p, "../x")
	testing.expect(t, !ok, "../x must not be found")
	_, ok = content.pack_size(p, "missing.txt")
	testing.expect(t, !ok, "missing.txt must not be found")
}

// The first column of the first row, from a database given as its file bytes; -1 when the query fails.
@(private = "file")
query_value :: proc(file: []byte, sql: cstring) -> i64 {
	handle: ^db.Sqlite
	defer db.close_v2(handle)
	if db.open_v2(":memory:", &handle, db.OPEN_READWRITE, nil) != db.OK do return -1
	if db.deserialize(handle, "main", raw_data(file), i64(len(file)), i64(len(file)), 0) != db.OK do return -1
	stmt: ^db.Stmt
	defer db.finalize(stmt)
	if db.prepare_v2(handle, sql, -1, &stmt, nil) != db.OK || db.step(stmt) != db.ROW do return -1
	return db.column_int64(stmt, 0)
}
