package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "../src/content"
import "../src/imports"
import "../src/db"
import "../src/titlepack"
import "../src/wasm"

// <name>.tar in build/: game.db with t(key, value) = ('answer', 42), notes.txt and pack.toml. The caller removes it.
write_test_pack :: proc(t: ^testing.T, name: string) -> (tar: string, ok: bool) {
	dir := fmt.tprintf("build/%s", name)
	os.make_directory(dir)
	defer os.remove_all(dir)
	w, err := db.create(fmt.tprintf("%s/%s", dir, "game.db"), "CREATE TABLE t (key TEXT PRIMARY KEY, value INTEGER);")
	testing.expect_value(t, err, "")
	db.insert(&w, "t", "answer", i64(42))
	testing.expect_value(t, db.finish(&w), "")
	_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, "notes.txt"), transmute([]byte)string("hello pack"))
	_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, titlepack.MANIFEST), transmute([]byte)string("id = \"x\"\nversion = \"1\"\n"))
	tar = fmt.tprintf("%s.tar", dir)
	return tar, testing.expect_value(t, titlepack.write_tar(dir, tar), "")
}

// A packed folder opens in place: its database reads back as a database, other files read at an offset,
// and paths outside the pack are not found.
@(test)
pack_serves_its_files_and_db :: proc(t: ^testing.T) {
	tar, written := write_test_pack(t, #procedure)
	if !written do return
	defer os.remove(tar)
	p, ok := content.open_pack(tar)
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

// A module reads into its own memory only: a buffer past its end gets -1 and the host writes nothing.
@(test)
content_read_stays_in_module_memory :: proc(t: ^testing.T) {
	READER_WAT :: `(module
		(import "openwavu" "content_read" (func $read (param i32 i32 i32 i32 i32) (result i32)))
		(memory (export "memory") 1)
		(data (i32.const 0) "notes.txt")
		(func (export "read") (param $buf i32) (param $cap i32) (result i32)
			(call $read (i32.const 0) (i32.const 9) (i32.const 0) (local.get $buf) (local.get $cap))))`
	tar, written := write_test_pack(t, #procedure)
	if !written do return
	defer os.remove(tar)
	p, opened := content.open_pack(tar)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&p)
	r := rig_create()
	defer rig_destroy(r)
	testing.expect_value(t, imports.define_content(r.linker, &p), "")
	inst, ok := load(t, r, READER_WAT)
	if !ok do return

	got := []wasm.Val{{}}
	testing.expect_value(t, wasm.call(r.store, inst, "read", {wasm.i32_val(64), wasm.i32_val(16)}, got), "")
	testing.expect_value(t, got[0].of.i32, 10)
	testing.expect_value(t, wasm.call(r.store, inst, "read", {wasm.i32_val(wasm.PAGE - 4), wasm.i32_val(16)}, got), "")
	testing.expect_value(t, got[0].of.i32, -1)
	testing.expect_value(t, wasm.call(r.store, inst, "read", {wasm.i32_val(-1), wasm.i32_val(16)}, got), "")
	testing.expect_value(t, got[0].of.i32, -1)
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
