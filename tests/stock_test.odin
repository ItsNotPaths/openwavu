package tests

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:testing"
import convert "../src/convert/tk5"
import "../src/db"
import formats "../src/formats/tk5"
import tk5 "../src/importer/tk5"

STOCK_DB :: "build/stock_test.db"

Packer :: #type proc(s: ^db.Stmt, out: ^[dynamic]byte)

// The db the importer writes loads into the tables and skeletons tk5decomp's sim files give the sim, for every character.
@(test)
db_loads_like_sim_files :: proc(t: ^testing.T) {
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)

	im := tk5.Import{archive = {table, f}}
	characters := formats.CHARACTERS
	w, create_err := db.create(STOCK_DB, TK5_SCHEMA)
	if !testing.expect_value(t, create_err, "") do return
	for name, i in MOTBIN_NAMES {
		defer free_all(context.temp_allocator)
		packed, _ := tk5.read_entry(im.archive, formats.MOTBIN_FIRST + 2 * i)
		data, unpacked := formats.unlz(packed, context.temp_allocator)
		m, read := formats.read_motbin(data, context.temp_allocator)
		if !testing.expect(t, unpacked && read, name) do continue
		testing.expect_value(t, convert.write_moveset_rows(&w, name, formats.container_owner(characters[i].container), i, m), "")
		skeleton, has_skeleton := tk5.character_skeleton(&im, characters[i])
		if !testing.expect(t, has_skeleton, name) do continue
		convert.write_skeleton_rows(&w, name, skeleton)
		top, measured := tk5.idle_head_top(&im, characters[i], m, data, &skeleton)
		testing.expect(t, measured, name)
		testing.expect_value(t, convert.write_stock_rows(&w, name, i, m, top), "")
	}
	if !testing.expect_value(t, db.finish(&w), "") do return
	defer os.remove(STOCK_DB)

	h: ^db.Sqlite
	if !testing.expect(t, db.open_v2(STOCK_DB, &h, db.OPEN_READWRITE, nil) == db.OK) do return
	defer db.close_v2(h)
	dumper_ok := build_sim_tool(SKELETON_DUMP, "tests/ref/skeleton_dump.c", "modules/tk5/sim/skel.c")
	testing.expect(t, dumper_ok, "tests/ref/skeleton_dump.c did not build")
	loader_ok := build_sim_tool(MOTBIN_LOAD, "-Ivendor/sqlite", "tests/ref/motbin_load.c", "modules/tk5/load.c", "modules/tk5/sim/motbin.c",
		"modules/tk5/sim/anim.c", "vendor/sqlite/libsqlite3.a", "-lpthread")
	testing.expect(t, loader_ok, "tests/ref/motbin_load.c did not build")
	for name in MOTBIN_NAMES {
		defer free_all(context.temp_allocator)
		if dumper_ok do check(t, name, "skeleton", sim_skeleton(name), skeleton_rows(h, name))
		if loader_ok do expect_loads_like_sim_file(t, name)
	}
}

MOTBIN_LOAD :: "build/motbin_load"

// The sim's tables loaded from the db (modules/tk5/load.c) equal the ones it parses from the character's .t5m.
@(private = "file")
expect_loads_like_sim_file :: proc(t: ^testing.T, name: string) {
	data :: TK5 + "/data/"
	command := []string{MOTBIN_LOAD, STOCK_DB, name, fmt.tprintf(data + "%s.t5m", name), fmt.tprintf(data + "%s.t5a", name), data + "common.t5a"}
	state, stdout, _, err := os.process_exec({command = command}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "%s: db load differs from the sim file:\n%s", name, string(stdout))
}

SKELETON_DUMP :: "build/skeleton_dump"

// What the sim's loader builds from the character's .t5b (tests/ref/skeleton_dump.c).
@(private = "file")
sim_skeleton :: proc(name: string) -> []byte {return run_sim_tool(SKELETON_DUMP, fmt.tprintf(TK5 + "/data/%s.t5b", name))}

@(private = "file")
skeleton_rows :: proc(h: ^db.Sqlite, char: string) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	append(&out, ..rows(h, char, "SELECT scale FROM skeleton WHERE character = ?", pack_f32))
	append(&out, ..rows(h, char, "SELECT parent, x, y, z, rx, ry, rz FROM skeleton_a WHERE character = ? ORDER BY slot", pack_bone))
	append(&out, ..rows(h, char, "SELECT parent, x, y, z FROM skeleton_b WHERE character = ? ORDER BY slot", pack_bone))
	return out[:]
}

@(private = "file")
check :: proc(t: ^testing.T, name, tag_name: string, want, got: []byte) {
	testing.expectf(t, bytes.equal(want, got), "%s %s: db rows differ from the sim file (%d vs %d bytes)", name, tag_name, len(got), len(want))
}

// Each row of the query packed by `pack`; the query's one parameter is the character.
@(private = "file")
rows :: proc(h: ^db.Sqlite, char: string, sql: cstring, pack: Packer) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	s: ^db.Stmt
	db.prepare_v2(h, sql, -1, &s, nil)
	defer db.finalize(s)
	db.bind_text(s, 1, raw_data(char), i32(len(char)), db.TRANSIENT)
	for db.step(s) == db.ROW do pack(s, &out)
	return out[:]
}

@(private = "file")
pack_f32 :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put_f32(out, column_f32(s, 0))}
@(private = "file")
pack_bone :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put(out, 1, column_u32(s, 0)); for c in i32(1) ..< db.column_count(s) do put_f32(out, column_f32(s, c))}

@(private = "file")
column_u32 :: proc(s: ^db.Stmt, column: i32) -> u32 {return u32(db.column_int64(s, column))}

@(private = "file")
column_f32 :: proc(s: ^db.Stmt, column: i32) -> f32 {return f32(db.column_double(s, column))}

@(private = "file")
put :: proc(out: ^[dynamic]byte, width: int, v: u32) {
	buf: [4]byte
	endian.put_u32(buf[:], .Little, v)
	append(out, ..buf[:width])
}

@(private = "file")
put_f32 :: proc(out: ^[dynamic]byte, v: f32) {
	buf: [4]byte
	endian.put_f32(buf[:], .Little, v)
	append(out, ..buf[:])
}

