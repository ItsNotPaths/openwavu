package tests

import "core:fmt"
import "core:image/png"
import "core:os"
import "core:testing"
import "../src/convert"
import "../src/db"
import tk5 "../src/importer/tk5"
import "../src/titlepack"

// Full import of the reference game: every character, costume, anim and stage lands in the stock pack.
@(test)
import_writes_full_pack :: proc(t: ^testing.T) {
	if !os.exists(TK5 + "/game") do return
	os.remove_all("build/test_packs")
	defer os.remove_all("build/test_packs")
	if !testing.expect_value(t, tk5.build_pack({TK5 + "/game"}, "build/test_packs", keep = true), "") do return
	check_stock_tar(t)

	handle: ^db.Sqlite
	if !testing.expect(t, db.open_v2("build/test_packs/tekken5dr/tk5.db", &handle, db.OPEN_READWRITE, nil) == db.OK) do return
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
	testing.expect_value(t, count(handle, "SELECT count(*) FROM anim"), 17556)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM stage"), 37)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM image"), 1773)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM image WHERE id GLOB 'select/*'"), 240)  // unlit menu entries
	testing.expect_value(t, count(handle, "SELECT count(*) FROM image WHERE id GLOB 'select_lit/*'"), 240)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM image WHERE id GLOB 'select_renders/*'"), 54)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM image WHERE id IN ('select_renders/paul_right', 'select_renders/paul_left', 'select_renders/xiaoyu_left')"), 3)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM font"), 8)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM glyph"), 14961)
	testing.expect_value(t, count(handle, "SELECT count(DISTINCT font) FROM glyph WHERE code = 0x41"), 8)  // every font has an A
	testing.expect_value(t, count(handle, "SELECT count(*) FROM glyph WHERE font = 'text_big' AND code IN (0x41F, 0x3066)"), 2)  // П, て
	testing.expect_value(t, count(handle, "SELECT count(*) FROM glyph WHERE font = 'wide' AND code = 0xE000"), 1)  // a button glyph
	all_images: ^db.Stmt
	if !testing.expect_value(t, db.prepare_v2(handle, "SELECT file FROM image", -1, &all_images, nil), db.OK) do return
	defer db.finalize(all_images)
	for db.step(all_images) == db.ROW {
		file := string(db.column_text(all_images, 0))
		data, read_err := os.read_entire_file(fmt.tprintf("build/test_packs/tekken5dr/%s", file), context.temp_allocator)
		if !testing.expect(t, read_err == nil && len(data) > 8 && string(data[:4]) == "\x89PNG", file) do break
	}
	images: ^db.Stmt
	if !testing.expect_value(t, db.prepare_v2(handle, "SELECT id, file FROM image WHERE id GLOB '[0-9]*' ORDER BY id", -1, &images, nil), db.OK) do return
	defer db.finalize(images)
	for index in 33 ..< 37 {
		if !testing.expect_value(t, db.step(images), db.ROW) do break
		file := fmt.tprintf("ui/%d.png", index)
		testing.expect_value(t, string(db.column_text(images, 0)), fmt.tprintf("%d", index))
		testing.expect_value(t, string(db.column_text(images, 1)), file)
		data, read_err := os.read_entire_file(fmt.tprintf("build/test_packs/tekken5dr/%s", file), context.temp_allocator)
		if !testing.expect_value(t, read_err, nil) do continue
		image, png_err := png.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
		testing.expect_value(t, png_err, nil)
		testing.expect(t, png_err == nil && image.width > 0 && image.height > 0, file)
	}
	testing.expect_value(t, db.step(images), db.DONE)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM texture"), 9616)
	textures: ^db.Stmt
	if !testing.expect_value(t, db.prepare_v2(handle, "SELECT file FROM texture", -1, &textures, nil), db.OK) do return
	defer db.finalize(textures)
	for db.step(textures) == db.ROW {
		file := string(db.column_text(textures, 0))
		data, read_err := os.read_entire_file(fmt.tprintf("build/test_packs/tekken5dr/%s", file), context.temp_allocator)
		if !testing.expect(t, read_err == nil && len(data) > 128 && string(data[:4]) == "DDS ", file) do break
	}
	testing.expect_value(t, count(handle, "SELECT count(*) FROM pragma_foreign_key_check"), 0)  // every cell that names a row finds it
	testing.expect_value(t, count(handle, "SELECT count(*) FROM part p WHERE NOT EXISTS (SELECT 1 FROM costume_part c WHERE c.part = p.id)"), 0)

	data, read_err := os.read_entire_file("build/test_packs/tekken5dr/anims/kazuya/0.anim", context.temp_allocator)
	if !testing.expect_value(t, read_err, nil) do return
	a, ok := convert.read_anim(data, context.temp_allocator)
	testing.expect(t, ok && a.layout == "tk5" && len(a.channels) == 23 && a.frames > 0, "kazuya anim 0 is not a tk5 .anim")
}

// The pack file holds the root files every pack needs, and the import's files byte for byte.
check_stock_tar :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("build/test_packs/" + tk5.STOCK_PACK, context.temp_allocator)
	if !testing.expect_value(t, err, nil) do return
	index, ok := titlepack.read_tar(data)
	if !testing.expect(t, ok, "stock pack did not read") do return
	defer titlepack.destroy_tar(index)
	for path in ([]string{"pack.toml", titlepack.FRONT, "gameplay.wasm", "gamerender.wasm", "app.wasm", "tk5.db", "ui/pic1.png", "anims/kazuya/0.anim"}) {
		entry, has := index[path]
		if !testing.expect(t, has, path) do continue
		file, _ := os.read_entire_file(fmt.tprintf("build/test_packs/tekken5dr/%s", path), context.temp_allocator)
		testing.expect(t, string(data[entry.offset:][:entry.size]) == string(file), path)
	}
	manifest := string(data[index["pack.toml"].offset:][:index["pack.toml"].size])
	tp, read := titlepack.read_titlepack(manifest, context.temp_allocator)
	testing.expect(t, read && tp.main == "app.wasm", "pack.toml names its entry module")
	testing.expect(t, len(tp.modes) == 1 && tp.modes[0] == {"versus", "gameplay.wasm", "gamerender.wasm"}, "pack.toml has the versus mode")

	// The stock front reads and shows: every file it names is in the pack.
	front_entry := index[titlepack.FRONT]
	front, front_err := titlepack.read_front(string(data[front_entry.offset:][:front_entry.size]), context.temp_allocator)
	testing.expect_value(t, front_err, "")
	for e in front.elements do if e.file != "" do testing.expect(t, e.file in index, e.file)
}
