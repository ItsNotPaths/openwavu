package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import tk5 "../src/convert/tk5"
import "../src/db"
import formats "../src/formats/tk5"


// Lists are laid out in sheet order, each with the end row the db leaves out; a reference names the list's first row,
// NULL is none, and a key no row has fails the load.
@(test)
lists_lay_out_in_sheet_order :: proc(t: ^testing.T) {
	if !build_load_lists(t, #procedure) do return
	rows :: `
		INSERT INTO requirement_list VALUES ('x/a', 'x'), ('x/b', 'x');
		INSERT INTO requirement (list, pos, id, param) VALUES ('x/a', 0, 1, 0), ('x/a', 1, 1, 0), ('x/a', 2, 1, 0), ('x/b', 0, 2, 0);
		INSERT INTO start_prop_list VALUES ('x/s', 'x');
		INSERT INTO start_prop (list, pos, requirements, id, value) VALUES ('x/s', 0, '%s', 5, 0);`
	// x/a takes rows 0..2 and its end row, so x/b starts at row 4; the start_prop list ends with a zero row; moves have none
	testing.expect_value(t, load_lists(t, #procedure, fmt.tprintf(rows, "x/b")),
		"move: 501/0/32769/-1/0x800/0/0\nrequirement: 1/0 1/0 1/0 327/0 2/0 327/0\nstart_prop: 4/5 0/0\n")
	testing.expect_value(t, load_lists(t, #procedure, fmt.tprintf(rows, "x/none")), "start_prop.requirements: no row x/none\n")
}

// Rows sit where the sheet puts them, whatever their key, so a mod's rows follow the game's; a param names a row in
// its table's column; aliases and tracking picks take the game's numbers. A text in a number column
// fails the load.
@(test)
mod_rows_follow_by_sheet_order :: proc(t: ^testing.T) {
	if !build_load_lists(t, #procedure) do return
	rows :: `
		INSERT INTO move_pool_list VALUES ('x/pool', 'x'), ('mod/pool', 'x');
		INSERT INTO move_pool VALUES ('x/pool', 0, 7), ('x/pool', 1, 7), ('mod/pool', 0, 7);
		INSERT INTO requirement_list VALUES ('x/r', 'x');
		INSERT INTO requirement (list, pos, id, param_move_pool, param_alias) VALUES ('x/r', 0, 123, 'mod/pool', NULL), ('x/r', 1, 148, NULL, 4);
		INSERT INTO pushback_curve_list VALUES ('x/curve', 'x');
		INSERT INTO pushback VALUES ('x/pushback/0', 'x', 1, 0, 0, 'x/curve'), ('mod/p', 'x', 1, 0, 0, 'x/curve');
		INSERT INTO extra_prop_list VALUES ('x/e', 'x');
		INSERT INTO extra_prop (list, pos, "when", id, value_pushback) VALUES ('x/e', 0, 1, 0x80a3, 'mod/p');
		INSERT INTO tracking_override VALUES ('x/o', 'x', 'x/t', 'x/t', 'never', 0), ('mod/t', 'x', 'x/t', 'x/t', 'never', 0);
		INSERT INTO cancel (list, pos, input, requirements, move, transition, start_align, motion, tracking_override)
			VALUES ('x/c', 0, '@0..0>0', 'x/r', 'x/m', 'start', 'keep', 'none', 'mod/t');
		INSERT INTO anim VALUES ('x', 0, 1, 'a.anim'), ('x', 'mod/z', 1, 'a.anim');
		UPDATE move SET anim_idx = 'mod/z', extra_props = 'x/e';`
	// pools: x/pool rows 0..1 and its end, mod/pool at 3; requirement 148 names alias 4 (0x8004); the pushback mod/p is row 1;
	// the cancel picks override 1 (counted from 1); anim mod/z follows anim 0 of its bank
	testing.expect_value(t, load_lists(t, #procedure, rows), "move: 501/1/32769/0/0x800/0/0\ncancel: 0/0/2/0\nrequirement: 123/3 148/32772 327/0\n" +
		"extra_prop: 1 0\nmove_pool: 7 7 0 7 0\n")
	testing.expect_value(t, load_lists(t, #procedure, "INSERT INTO requirement_list VALUES ('x/r', 'x'); INSERT INTO requirement (list, pos, id, param) VALUES ('x/r', 0, 5, 'mod/pool');"),
		"requirement.param: text in a number column\n")
	testing.expect_value(t, load_lists(t, #procedure, "INSERT INTO requirement_list VALUES ('x/r', 'x'); INSERT INTO requirement (list, pos, id, param_move) VALUES ('x/r', 0, 5, 3);"),
		"requirement.param_move: no row 3\n")
}

// A cancel's input text loads as the command the sim matches: the stock dash, a sequence of its own (':' ones too), a key
// command, a list's end row. Text that does not parse fails the load.
@(test)
cancel_inputs_load_as_commands :: proc(t: ^testing.T) {
	if !build_load_lists(t, #procedure) do return
	rows :: `
		INSERT INTO requirement_list VALUES ('x/r', 'x');
		INSERT INTO cancel (list, pos, kind, input, requirements, transition, start_align, motion) VALUES
			('x/c', 0, NULL, '{{^f:n:^f}}20@1..255>1', 'x/r', 'start', 'keep', 'none'),
			('x/c', 1, NULL, '{{f:n:^f}}20@1..255>1', 'x/r', 'start', 'keep', 'none'),
			('x/c', 2, NULL, '{{n,f+1}}10@1..255>1', 'x/r', 'start', 'keep', 'none'),
			('x/c', 3, NULL, '%s', 'x/r', 'start', 'keep', 'none'), ('x/c', 4, 'end', '@50..255>50', 'x/r', 'start', 'keep', 'none');`
	testing.expect_value(t, load_lists(t, #procedure, fmt.tprintf(rows, "f+1@1..1>1")), "move: 501/0/32769/-1/0x800/0/0\ncancel: 0x8001/0/0/0 0x8007/0/0/0 0x8008/0/0/0 0x40/0/0/0 0x8000/0/0/0\n" +
		"requirement: 327/0\n")
	testing.expect_value(t, load_lists(t, #procedure, fmt.tprintf(rows, "f+5@1..1>1")), "cancel.input f+5@1..1>1: a direction or button is unknown\n")
}

// A cancel's transition, start alignment and motion names and its flags load as the word the sim reads (transition.h):
// pass 9 << 10, to_opponent 4 << 6, sweep_locked 16, turn bit 15, root_hips bit 17. A name its sheet does not have fails
// the load, in a cancel or in any cell that names a code (tracking).
@(test)
codes_load_by_name :: proc(t: ^testing.T) {
	if !build_load_lists(t, #procedure) do return
	rows :: `
		INSERT INTO requirement_list VALUES ('x/r', 'x');
		INSERT INTO cancel (list, pos, input, requirements, transition, start_align, motion, turn, root_hips)
			VALUES ('x/c', 0, '@0..0>0', 'x/r', '%s', 'to_opponent', 'sweep_locked', 1, 1);`
	testing.expect_value(t, load_lists(t, #procedure, fmt.tprintf(rows, "pass")), "move: 501/0/32769/-1/0x800/0/0\ncancel: 0/0/0/0x2a510\nrequirement: 327/0\n")
	testing.expect_value(t, load_lists(t, #procedure, fmt.tprintf(rows, "passing")), "cancel.transition: no row passing\n")
	testing.expect_value(t, load_lists(t, #procedure, "INSERT INTO tracking_override VALUES ('x/o', 'x', 'x/t', 'x/t', 'sideways', 0);"),
		"tracking_override.far_source: no row sideways\n")
}

// A move's state, attack and flag cells and its move_ai row load as the words the sim reads (state.h, hit.h, motbin.h):
// launched 14 << 11 and downed bit 9, never picks bit 23; mid 2 << 8, hits standing bit 1, blocked by the stand guard bit 4,
// throw bit 22; looks at the opponent bit 2, follow-up input bit 27. A name its sheet does not have fails the load.
@(test)
move_words_load_by_column :: proc(t: ^testing.T) {
	if !build_load_lists(t, #procedure) do return
	rows :: `
		UPDATE move SET state_class = '%s', state_downed = 1, attack_kind = 'mid', attack_hits_standing = 1,
			attack_blocked_by_stand_guard = 1, looks_at_opponent = 1 WHERE key = 'x/m';
		INSERT INTO move_ai (move, ai_never_picks, ai_throw, ai_follow_up_input) VALUES ('x/m', 1, 1, 1);`
	testing.expect_value(t, load_lists(t, #procedure, fmt.tprintf(rows, "launched")), "move: 501/0/32769/-1/0x807200/0x400212/0x8000004\n")
	testing.expect_value(t, load_lists(t, #procedure, fmt.tprintf(rows, "flying")), "move.state_class: no row flying\n")
}

// A mod's move identity (compare id) is text, numbered after every stock one across all characters, so a pool or a
// requirement of one character can name a move of another. An identity no move has fails the load.
@(test)
compare_ids_are_global :: proc(t: ^testing.T) {
	if !build_load_lists(t, #procedure) do return
	rows :: `
		INSERT INTO move_pool_list VALUES ('x/pool', 'x');
		INSERT INTO move_pool VALUES ('x/pool', 0, 'mod/y_upper');
		INSERT INTO requirement_list VALUES ('x/r', 'x');
		INSERT INTO requirement (list, pos, id, param_compare_id) VALUES ('x/r', 0, 224, '%s');`
	// stock ids end at 500: mod/a_x is 501, mod/y_upper 502
	testing.expect_value(t, load_lists(t, #procedure, fmt.tprintf(rows, "mod/y_upper")), "move: 501/0/32769/-1/0x800/0/0\nrequirement: 224/502 327/0\nmove_pool: 502 0\n")
	testing.expect_value(t, load_lists(t, #procedure, fmt.tprintf(rows, "mod/nobody")), "requirement.param_compare_id: no compare_id mod/nobody\n")
}

@(private = "file")
build_load_lists :: proc(t: ^testing.T, test: string) -> bool {
	built := build_sim_tool(fmt.tprintf("build/%s", test), "-Ivendor/sqlite", "tests/ref/load_lists.c", "modules/tk5/load.c", "modules/tk5/sim/stage_file.c",
		"modules/tk5/sim/anim.c", "vendor/sqlite/libsqlite3.a", "-lpthread")
	return testing.expect(t, built, "tests/ref/load_lists.c did not build")
}

// Tests run at once: each builds the tool and its db under its own name.
// Each test builds the tool and its db under its own name: tests run at once.
// Character x with one move x/m (compare id mod/a_x, ends in alias 1) and its empty lists, then `rows`; character y has
// moves with compare ids mod/y_upper and 500.
@(private = "file")
load_lists :: proc(t: ^testing.T, test, rows: string) -> string {
	move :: `INSERT INTO move (key, character, name, anim_owner, anim_idx, anim, state_class, attack_kind, cancels, next_alias, end_yaw,
		compare_id, push_speed, hit_conditions, window_start, window_end, hold_frame, hit_category, first_active, last_active,
		push_shape, tracking_row, tracking_far_row, tracking_far_source, tracking_far_angle, rides_partner, hit_pair_end_kind_0,
		hit_pair_end_index_0, hit_pair_start_kind_0, hit_pair_start_index_0, hit_pair_end_kind_1, hit_pair_end_index_1,
		hit_pair_start_kind_1, hit_pair_start_index_1, hits_attack_bones, hits_slots, hits_launches)
		VALUES ('%s', '%s', 'm', '%s', 0, 0, 'stand_open', 'none', 'x/c', 1, 0, %s, 0, 'x/h', 0, 0, 0, 0, 0, 0, 0, 'x/t', 'x/t',
		'never', 0, 0, 'none', 0, 'none', 0, 'none', 0, 'none', 0, 0, 0, 0);`
	tool, path := fmt.tprintf("build/%s", test), fmt.tprintf("build/%s.db", test)
	defer os.remove(path)
	w, err := db.create(path, TK5_SCHEMA)
	testing.expect_value(t, err, "")
	db.exec_sql(&w, `INSERT INTO cancel_list VALUES ('x/c', 'x'); INSERT INTO hit_condition_list VALUES ('x/h', 'x');`)
	db.exec_sql(&w, `INSERT INTO tracking_row VALUES ('x/t', 'x', 'hold', 'running', 'none', 0, 'none', 0, 0, 0, 0, 0, 0, 0, 'none', 0,
		0, 0, 0, 0, 0, 'never', 'never', 0, 'running');`)
	db.exec_sql(&w, fmt.tprintf(move, "x/m", "x", "x", "'mod/a_x'"))
	db.exec_sql(&w, fmt.tprintf(move, "y/upper", "y", "y", "'mod/y_upper'"))
	db.exec_sql(&w, fmt.tprintf(move, "y/other", "y", "y", "500"))
	db.exec_sql(&w, rows)
	testing.expect_value(t, db.finish(&w), "")
	state, stdout, _, exec_err := os.process_exec({command = {tool, path, "x"}}, context.temp_allocator)
	testing.expect(t, exec_err == nil && state.exit_code <= 1)
	return string(stdout)
}

LOAD_ANIMS :: "build/load_anims"
LOAD_ANIMS_ROOT :: "build/load_anims_pack"

// Rows that name one file are one anim; an id without a row is a zero anim; a mod's text ids follow the numbered ones, in
// key order; a file that is not a tk5 .anim fails the load.
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

	testing.expect_value(t, load_anims(t, "b.anim"), "2:1.5 0:0 2:1.5 3:7 2:1.5 3:7 same 1 0")
	testing.expect(t, strings.contains(load_anims(t, "bad.anim"), "bad file bad.anim"))
}

// Channel 0 of the last frame holds `last`.
@(private = "file")
write_test_anim :: proc(t: ^testing.T, file: string, frames: int, last: f32) {
	values := make([][formats.CHANNELS][3]f32, frames, context.temp_allocator)
	values[frames - 1][0][0] = last
	testing.expect(t, tk5.write_anim(fmt.tprintf("%s/%s", LOAD_ANIMS_ROOT, file), {frames = frames, values = values}))
}

// Bank x: ids 0 and 2 on a.anim, 3 on `third`, 1 without a row; mod/a on a.anim, mod/z on b.anim.
@(private = "file")
load_anims :: proc(t: ^testing.T, third: string) -> string {
	path :: LOAD_ANIMS_ROOT + "/pack.db"
	w, err := db.create(path, TK5_SCHEMA)
	testing.expect_value(t, err, "")
	db.insert(&w, "anim", "x", i64(0), i64(2), "a.anim")
	db.insert(&w, "anim", "x", i64(2), i64(2), "a.anim")
	db.insert(&w, "anim", "x", i64(3), i64(3), third)
	db.insert(&w, "anim", "x", "mod/z", i64(3), "b.anim")
	db.insert(&w, "anim", "x", "mod/a", i64(2), "a.anim")
	testing.expect_value(t, db.finish(&w), "")
	state, stdout, _, exec_err := os.process_exec({command = {LOAD_ANIMS, path, LOAD_ANIMS_ROOT, "x"}}, context.temp_allocator)
	testing.expect(t, exec_err == nil && state.exit_code <= 1)
	return string(stdout)
}
