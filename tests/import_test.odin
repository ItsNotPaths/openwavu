package tests

import "core:fmt"
import "core:image/png"
import "core:os"
import "core:testing"
import "../src/convert"
import "../src/db"
import tk5 "../src/importer/tk5"

// Full import of the reference game: every character, costume, anim and stage lands in the pack.
@(test)
import_writes_full_pack :: proc(t: ^testing.T) {
	game, err := tk5.find_game({TK5 + "/game"})
	if err == "no supported game found (Tekken 5 DR, NPUB30009)" || !os.exists(TK5 + "/game") do return
	testing.expect_value(t, err, "")
	if err != "" do return
	defer tk5.destroy_game(game)
	os.remove_all("build/test_content")
	defer os.remove_all("build/test_content")
	testing.expect_value(t, tk5.run(game, "build/test_content"), "")

	handle: ^db.Sqlite
	if !testing.expect(t, db.open_v2("build/test_content/tk5/tk5.db", &handle, db.OPEN_READWRITE, nil) == db.OK) do return
	defer db.close_v2(handle)
	count :: proc(h: ^db.Sqlite, sql: cstring) -> i64 {
		s: ^db.Stmt
		db.prepare_v2(h, sql, -1, &s, nil)
		defer db.finalize(s)
		db.step(s)
		return db.column_int64(s, 0)
	}
	testing.expect_value(t, count(handle, "SELECT count(*) FROM character"), 36)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM part WHERE slot = 'body'"), 85)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM anim"), 15421)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM stage"), 37)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM image"), 4)
	images: ^db.Stmt
	if !testing.expect_value(t, db.prepare_v2(handle, "SELECT id, file FROM image ORDER BY id", -1, &images, nil), db.OK) do return
	defer db.finalize(images)
	for index in 33 ..< 37 {
		if !testing.expect_value(t, db.step(images), db.ROW) do break
		file := fmt.tprintf("images/%d.png", index)
		testing.expect_value(t, string(db.column_text(images, 0)), fmt.tprintf("%d", index))
		testing.expect_value(t, string(db.column_text(images, 1)), file)
		data, read_err := os.read_entire_file(fmt.tprintf("build/test_content/tk5/%s", file), context.temp_allocator)
		if !testing.expect_value(t, read_err, nil) do continue
		image, png_err := png.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
		testing.expect_value(t, png_err, nil)
		testing.expect(t, png_err == nil && image.width > 0 && image.height > 0, file)
	}
	testing.expect_value(t, db.step(images), db.DONE)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM move m LEFT JOIN anim a ON a.character = m.anim_owner AND a.idx = m.anim_idx WHERE a.idx IS NULL AND m.anim_owner NOT LIKE '%/embedded'"), 0)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM part p WHERE NOT EXISTS (SELECT 1 FROM costume_part c WHERE c.part = p.id)"), 0)

	data, read_err := os.read_entire_file("build/test_content/tk5/anims/kazuya/0.anim", context.temp_allocator)
	if !testing.expect_value(t, read_err, nil) do return
	a, ok := convert.read_anim(data, context.temp_allocator)
	testing.expect(t, ok && a.layout == "tk5" && len(a.channels) == 23 && a.frames > 0, "kazuya anim 0 is not a tk5 .anim")
}
