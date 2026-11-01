package tests

import "core:fmt"
import "core:os"
import "core:testing"
import convert "../src/convert/tk5"
import "../src/db"
import formats "../src/formats/tk5"
import tk5 "../src/importer/tk5"

STOCK_DB :: "build/stock_test.db"

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

	built := build_sim_tool(LOAD_PARITY, "-Ivendor/sqlite", "tests/ref/load_parity.c", "modules/tk5/load.c", "modules/tk5/sim/motbin.c",
		"modules/tk5/sim/anim.c", "modules/tk5/sim/skel.c", "vendor/sqlite/libsqlite3.a", "-lpthread")
	if !testing.expect(t, built, "tests/ref/load_parity.c did not build") do return
	for name in MOTBIN_NAMES {
		defer free_all(context.temp_allocator)
		expect_loads_like_sim_files(t, name)
	}
}

LOAD_PARITY :: "build/load_parity"

// The sim's structs loaded from the db (modules/tk5/load.c) equal the ones it parses from the character's sim files.
@(private = "file")
expect_loads_like_sim_files :: proc(t: ^testing.T, name: string) {
	data :: TK5 + "/data/"
	command := []string{LOAD_PARITY, STOCK_DB, name, fmt.tprintf(data + "%s.t5m", name), fmt.tprintf(data + "%s.t5a", name), data + "common.t5a",
		fmt.tprintf(data + "%s.t5b", name)}
	state, stdout, _, err := os.process_exec({command = command}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "%s: db load differs from the sim file:\n%s", name, string(stdout))
}
