package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import tk5 "../src/convert/tk5"
import "../src/db"
import formats "../src/formats/tk5"

LOAD_LISTS :: "build/load_lists"
LOAD_LISTS_DB :: "build/load_lists.db"

// A grown list moves the lists after it; references by list id follow. -1 stays none, a missing list fails the load.
@(test)
list_ids_become_indices :: proc(t: ^testing.T) {
	built := build_sim_tool(LOAD_LISTS, "-Ivendor/sqlite", "tests/ref/load_lists.c", "modules/tk5/load.c", "modules/tk5/sim/stage_file.c", "modules/tk5/sim/anim.c",
		"vendor/sqlite/libsqlite3.a", "-lpthread")
	if !testing.expect(t, built, "tests/ref/load_lists.c did not build") do return
	defer os.remove(LOAD_LISTS_DB)

	testing.expect_value(t, load_lists(t, 2), "3 -1 0 0 0 0 ")  // list 0 has three rows now, so list 2 starts at row 3
	testing.expect(t, strings.contains(load_lists(t, 7), "no requirement list 7"))
}

TEXT_KEYS :: "build/load_text_keys"
TEXT_KEYS_DB :: "build/load_text_keys.db"

// A mod's rows have text keys and are laid out after the stock rows, in key order; references by key follow, also
// through a param whose code names a table (code_ref). Text in a plain number column fails the load.
@(test)
text_keys_follow_stock_rows :: proc(t: ^testing.T) {
	built := build_sim_tool(TEXT_KEYS, "-Ivendor/sqlite", "tests/ref/load_lists.c", "modules/tk5/load.c", "modules/tk5/sim/stage_file.c", "modules/tk5/sim/anim.c",
		"vendor/sqlite/libsqlite3.a", "-lpthread")
	if !testing.expect(t, built, "tests/ref/load_lists.c did not build") do return
	defer os.remove(TEXT_KEYS_DB)

	w, err := db.create(TEXT_KEYS_DB, TK5_SCHEMA)
	testing.expect_value(t, err, "")
	db.insert(&w, "code_ref", i64(123), "move_pool")
	db.insert(&w, "code_ref", i64(0x8000 + 163), "pushback")
	for pos in i64(0) ..< 2 do db.insert(&w, "requirement", "x", "mod/b", pos, i64(1), i64(0))
	db.insert(&w, "requirement", "x", "mod/a", i64(0), i64(1), i64(0))
	db.insert(&w, "requirement", "x", i64(0), i64(0), i64(123), "mod/pool")
	for list in ([]db.Value{i64(0), "mod/pool"}) do for pos in i64(0) ..< 2 do db.insert(&w, "move_pool", "x", list, pos, i64(7))
	db.insert(&w, "extra_prop", "x", i64(0), i64(0), i64(0), i64(0x8000 + 163), "mod/p", db.Null{})
	db.insert(&w, "hit_condition", "x", i64(0), i64(0), "mod/b", i64(10), i64(0), i64(0))
	for key in ([]db.Value{i64(0), "mod/p", "mod/o"}) do db.insert(&w, "pushback", "x", key, i64(1), i64(0), i64(0), db.Null{}, i64(-1))
	reaction := make([]db.Value, 35, context.temp_allocator)
	for &v in reaction do v = i64(0)
	reaction[0], reaction[2], reaction[3] = "x", "mod/p", i64(0)
	db.insert(&w, "reaction", ..reaction)
	testing.expect_value(t, db.finish(&w), "")
	state, stdout, _, exec_err := os.process_exec({command = {TEXT_KEYS, TEXT_KEYS_DB, "x"}}, context.temp_allocator)
	testing.expect(t, exec_err == nil && state.exit_code == 0)
	// requirement rows: list 0, then mod/a, then mod/b at row 2; pushbacks: 0, then mod/o, then mod/p at 2;
	// pools: list 0, then mod/pool at row 2
	testing.expect_value(t, string(stdout), "2 2 0 2 0 0 0 2 ")

	w, err = db.create(TEXT_KEYS_DB, TK5_SCHEMA)
	db.insert(&w, "requirement", "x", i64(0), i64(0), i64(5), "mod/pool")
	testing.expect_value(t, db.finish(&w), "")
	_, stdout, _, _ = os.process_exec({command = {TEXT_KEYS, TEXT_KEYS_DB, "x"}}, context.temp_allocator)
	testing.expect_value(t, string(stdout), "requirement.param: text in a number column\n")
}

// hit_condition 0 points to requirement list `target`; start_prop 0 has none.
@(private = "file")
load_lists :: proc(t: ^testing.T, target: i64) -> string {
	w, err := db.create(LOAD_LISTS_DB, TK5_SCHEMA)
	testing.expect_value(t, err, "")
	for pos in i64(0) ..< 3 do db.insert(&w, "requirement", "x", i64(0), pos, i64(1), i64(0))
	db.insert(&w, "requirement", "x", i64(2), i64(0), i64(1), i64(0))
	db.insert(&w, "hit_condition", "x", i64(0), i64(0), target, i64(10), i64(0), i64(0))
	db.insert(&w, "start_prop", "x", i64(0), i64(0), i64(-1), i64(0), i64(0))
	testing.expect_value(t, db.finish(&w), "")
	state, stdout, _, exec_err := os.process_exec({command = {LOAD_LISTS, LOAD_LISTS_DB, "x"}}, context.temp_allocator)
	testing.expect(t, exec_err == nil && state.exit_code <= 1)
	return string(stdout)
}

LOAD_ANIMS :: "build/load_anims"
LOAD_ANIMS_ROOT :: "build/load_anims_pack"

// Rows that name one file are one anim; an id without a row is a zero anim; a file that is not a tk5 .anim fails the load.
@(test)
anims_share_by_file :: proc(t: ^testing.T) {
	built := build_sim_tool(LOAD_ANIMS, "-Ivendor/sqlite", "tests/ref/load_anims.c", "modules/tk5/load.c", "modules/tk5/sim/stage_file.c", "modules/tk5/sim/anim.c",
		"vendor/sqlite/libsqlite3.a", "-lpthread")
	if !testing.expect(t, built, "tests/ref/load_anims.c did not build") do return
	os.make_directory(LOAD_ANIMS_ROOT)
	defer os.remove_all(LOAD_ANIMS_ROOT)
	write_test_anim(t, "a.anim", 2, 1.5)
	write_test_anim(t, "b.anim", 3, 7)
	testing.expect(t, os.write_entire_file(LOAD_ANIMS_ROOT + "/bad.anim", []byte{1, 2, 3}) == nil)

	testing.expect_value(t, load_anims(t, "b.anim"), "2:1.5 0:0 2:1.5 3:7 same 1 0")
	testing.expect(t, strings.contains(load_anims(t, "bad.anim"), "bad file bad.anim"))
}

// Channel 0 of the last frame holds `last`.
@(private = "file")
write_test_anim :: proc(t: ^testing.T, file: string, frames: int, last: f32) {
	values := make([][formats.CHANNELS][3]f32, frames, context.temp_allocator)
	values[frames - 1][0][0] = last
	testing.expect(t, tk5.write_anim(fmt.tprintf("%s/%s", LOAD_ANIMS_ROOT, file), {frames = frames, values = values}))
}

// Bank x: ids 0 and 2 on a.anim, 3 on `third`, 1 without a row.
@(private = "file")
load_anims :: proc(t: ^testing.T, third: string) -> string {
	path :: LOAD_ANIMS_ROOT + "/pack.db"
	w, err := db.create(path, TK5_SCHEMA)
	testing.expect_value(t, err, "")
	db.insert(&w, "anim", "x", i64(0), i64(2), "a.anim")
	db.insert(&w, "anim", "x", i64(2), i64(2), "a.anim")
	db.insert(&w, "anim", "x", i64(3), i64(3), third)
	testing.expect_value(t, db.finish(&w), "")
	state, stdout, _, exec_err := os.process_exec({command = {LOAD_ANIMS, path, LOAD_ANIMS_ROOT, "x"}}, context.temp_allocator)
	testing.expect(t, exec_err == nil && state.exit_code <= 1)
	return string(stdout)
}
