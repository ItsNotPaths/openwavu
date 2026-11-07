package tests

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../src/content"
import "../src/db"
import "../src/titlepack"

LAYER_DIR :: "build/layer_test"

// The first cell of the first row, as text; "" for none.
cell :: proc(handle: ^db.Sqlite, sql: string) -> string {
	statement: ^db.Stmt
	if db.prepare_v2(handle, strings.clone_to_cstring(sql, context.temp_allocator), -1, &statement, nil) != db.OK do return ""
	defer db.finalize(statement)
	if db.step(statement) != db.ROW do return ""
	return strings.clone(string(db.column_text(statement, 0)), context.temp_allocator)
}

// A pack over the stock base: pack.toml with bases = ["tekken5dr"] and a tk5.db.patch made from the stock db by
// trimming it with edit (SQL run on a copy). The caller removes LAYER_DIR.
write_layer_pack :: proc(t: ^testing.T, stock_db: ^db.Sqlite, edit: string) -> (tar: string, ok: bool) {
	os.remove_all(LAYER_DIR)
	os.make_directory_all(LAYER_DIR + "/pack")
	size: i64
	bytes := db.serialize(stock_db, "main", &size, db.SERIALIZE_NOCOPY)
	patch_path := LAYER_DIR + "/pack/tk5.db.patch"
	if !testing.expect(t, os.write_entire_file(patch_path, bytes[:size]) == nil) do return
	handle: ^db.Sqlite
	if !testing.expect(t, db.open_v2(strings.clone_to_cstring(patch_path, context.temp_allocator), &handle, db.OPEN_READWRITE, nil) == db.OK) do return
	ok = testing.expect_value(t, db.exec(handle, strings.clone_to_cstring(edit, context.temp_allocator), nil, nil, nil), i32(db.OK))
	db.close_v2(handle)
	_ = os.write_entire_file(LAYER_DIR + "/pack/" + titlepack.MANIFEST, transmute([]byte)string("id = \"layer_test\"\nversion = \"1\"\nbases = [\"tekken5dr\"]\n"))
	tar = LAYER_DIR + "/layer_test.tar"
	return tar, ok && testing.expect_value(t, titlepack.write_tar(LAYER_DIR + "/pack", tar), "")
}

// SQL that empties every table of the patch except the ones keep names.
empty_tables_except :: proc(handle: ^db.Sqlite, keep: ..string) -> string {
	sql: strings.Builder
	strings.builder_init(&sql, context.temp_allocator)
	statement: ^db.Stmt
	db.prepare_v2(handle, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil)
	defer db.finalize(statement)
	outer: for db.step(statement) == db.ROW {
		table := string(db.column_text(statement, 0))
		for kept in keep do if table == kept do continue outer
		fmt.sbprintf(&sql, "DELETE FROM \"%s\";", table)
	}
	return strings.to_string(sql)
}

// A pack on the stock base sees the base's files under its own, and its db patch changes the base's database: a row
// is replaced in place (it keeps its spot in the game's order), a list is replaced whole, and a patch that adds a key
// in another pack's namespace does not open.
@(test)
pack_layers_over_its_stock_base :: proc(t: ^testing.T) {
	if !os.exists(STOCK_PACK) do return
	defer os.remove_all(LAYER_DIR)
	stock, opened := content.open_pack(STOCK_PACK)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&stock)
	stock_db := stock.dbs["tk5.db"]
	move := cell(stock_db, "SELECT key FROM move WHERE attack_kind != 'none' LIMIT 1")
	move_spot := cell(stock_db, fmt.tprintf("SELECT rowid FROM move WHERE key = '%s'", move))
	list := cell(stock_db, "SELECT list FROM pushback_curve GROUP BY list HAVING count(*) > 1 LIMIT 1")
	rows_before := cell(stock_db, "SELECT count(*) FROM pushback_curve")
	list_before := cell(stock_db, fmt.tprintf("SELECT count(*) FROM pushback_curve WHERE list = '%s'", list))

	edit := fmt.tprintf("%s DELETE FROM move WHERE key != '%s'; UPDATE move SET attack_kind = 'mid_unblockable'; DELETE FROM pushback_curve WHERE list != '%s' OR pos != 0; UPDATE pushback_curve SET value = 999;", empty_tables_except(stock_db, "move", "pushback_curve"), move, list)
	tar, written := write_layer_pack(t, stock_db, edit)
	if !written do return
	layered, layered_opened := content.open_pack(tar)
	if !testing.expect(t, layered_opened, "the pack did not open over its base") do return
	defer content.close_pack(&layered)
	_, has_module := titlepack.read_file(layered.files, "app.wasm")
	testing.expect(t, has_module, "the base's files show through")
	manifest, _ := titlepack.read_file(layered.files, titlepack.MANIFEST)
	testing.expect(t, strings.contains(string(manifest), "layer_test"), "the pack's own pack.toml wins")
	patched := layered.dbs["tk5.db"]
	testing.expect_value(t, cell(patched, fmt.tprintf("SELECT attack_kind FROM move WHERE key = '%s'", move)), "mid_unblockable")
	testing.expect_value(t, cell(patched, fmt.tprintf("SELECT rowid FROM move WHERE key = '%s'", move)), move_spot)
	testing.expect_value(t, cell(patched, fmt.tprintf("SELECT group_concat(value) FROM pushback_curve WHERE list = '%s'", list)), "999")
	rows, _ := strconv.parse_int(rows_before)
	list_rows, _ := strconv.parse_int(list_before)
	expected_rows := fmt.tprintf("%d", rows - list_rows + 1)
	testing.expect_value(t, cell(patched, "SELECT count(*) FROM pushback_curve"), expected_rows)

	outsider := fmt.tprintf("%s DELETE FROM move WHERE key != '%s'; UPDATE move SET key = 'someone_else/new_move';", empty_tables_except(stock_db, "move"), move)
	foreign_tar, foreign_written := write_layer_pack(t, stock_db, outsider)
	if !foreign_written do return
	refused, refused_opened := content.open_pack(foreign_tar)
	if refused_opened do content.close_pack(&refused)
	testing.expect(t, !refused_opened, "a patch adding a key outside its namespace opened")
}
