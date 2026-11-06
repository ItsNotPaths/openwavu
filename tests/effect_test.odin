package tests

import "core:os"
import "core:strings"
import "core:testing"
import "../src/db"
import formats "../src/formats/tk5"
import "../src/fx"
import tk5 "../src/importer/tk5"

EFFECT_ROOT :: "build/effect_test"

// The importer's effect files load in the host's reader: the shared hit spark is a baked sprite (3 particles, 25 ticks),
// and Kazuya's electric record keeps its blue (seen in game).
@(test)
imported_effects_load :: proc(t: ^testing.T) {
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	file, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(file)
	defer free_all(context.temp_allocator)

	im := tk5.Import{archive = {table, file}, root = EFFECT_ROOT}
	writer, create_err := db.create(EFFECT_ROOT + ".db", TK5_SCHEMA)
	if !testing.expect_value(t, create_err, "") do return
	im.w = writer
	defer {
		for key in im.textures do delete(key)
		delete(im.textures)
	}
	testing.expect(t, tk5.import_shared_effects(&im))
	kazuya: formats.Character
	for character in formats.CHARACTERS do if character.id == "kazuya" do kazuya = character
	testing.expect(t, tk5.import_character_effects(&im, kazuya, "kazuya"))

	spark, spark_read := read_effect(EFFECT_ROOT + "/effects/common/0.fx")
	if testing.expect(t, spark_read, "hit spark") {
		element := spark.elements[0]
		testing.expect_value(t, element.kind, fx.Element_Kind.Sprite)
		testing.expect_value(t, len(element.tracks), 3)
		testing.expect_value(t, len(element.tracks[0].positions), 25)
		testing.expect_value(t, len(element.frames), 16)
		for frame in element.frames do testing.expect(t, os.exists(strings.concatenate({EFFECT_ROOT + "/", frame}, context.temp_allocator)), frame)
	}
	electric, electric_read := read_effect(EFFECT_ROOT + "/effects/kazuya/0.fx")
	if testing.expect(t, electric_read, "kazuya record 0") {
		color := electric.elements[0].color
		testing.expect(t, color.b > color.r && color.b > color.g, "blue")
	}
	// A heavy hit plays row 0 of the attacker's table: for Kazuya it holds the blue record.
	testing.expect_value(t, db.finish(&im.w), "")
	im.w = {}
	handle: ^db.Sqlite
	if !testing.expect_value(t, db.open_v2(EFFECT_ROOT + ".db", &handle, db.OPEN_READWRITE, nil), db.OK) do return
	defer db.close_v2(handle)
	testing.expect_value(t, count_rows(handle, "SELECT count(*) FROM character_effect_row WHERE character = 'kazuya' AND row = 0 AND records & 1"), 1)
	testing.expect_value(t, count_rows(handle, "SELECT count(*) FROM character_effect WHERE character = 'kazuya' AND record = 0 AND file = 'effects/kazuya/0.fx'"), 1)
}

@(private = "file")
count_rows :: proc(handle: ^db.Sqlite, sql: cstring) -> i64 {
	statement: ^db.Stmt
	db.prepare_v2(handle, sql, -1, &statement, nil)
	defer db.finalize(statement)
	db.step(statement)
	return db.column_int64(statement, 0)
}

@(private = "file")
read_effect :: proc(path: string) -> (effect: fx.Effect, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	return fx.read(data, context.temp_allocator)
}
