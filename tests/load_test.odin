package tests

import "core:os"
import "core:strings"
import "core:testing"
import "../src/db"

LOAD_LISTS :: "build/load_lists"
LOAD_LISTS_DB :: "build/load_lists.db"

// A grown list moves the lists after it; references by list id follow. -1 stays none, a missing list fails the load.
@(test)
list_ids_become_indices :: proc(t: ^testing.T) {
	built := build_sim_tool(LOAD_LISTS, "-Ivendor/sqlite", "tests/ref/load_lists.c", "modules/tk5/load.c", "vendor/sqlite/libsqlite3.a", "-lpthread")
	if !testing.expect(t, built, "tests/ref/load_lists.c did not build") do return
	defer os.remove(LOAD_LISTS_DB)

	testing.expect_value(t, load_lists(t, 2), "3 -1 ")  // list 0 has three rows now, so list 2 starts at row 3
	testing.expect(t, strings.contains(load_lists(t, 7), "no requirement list 7"))
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
