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
	if !testing.expect_value(t, tk5.build_pack({TK5 + "/game"}, "build/test_packs"), "") do return
	check_stock_pack(t)

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
	testing.expect_value(t, count(handle, "SELECT count(*) FROM character"), 37)
	// Mokujin's costumes hide the sword and tail meshes, the sword shown only with Yoshimitsu's moves, the tail with Roger's.
	testing.expect_value(t, count(handle, "SELECT count(*) FROM part_moveset_mesh WHERE part = 'mokujin_1' AND character IS NULL"), 7)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM part_moveset_mesh WHERE part = 'mokujin_1' AND character = 'yoshimitsu'"), 1)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM part_moveset_mesh WHERE part = 'mokujin_1' AND character = 'roger'"), 6)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM part_moveset_mesh WHERE character IS NOT NULL AND node NOT IN (SELECT node FROM part_moveset_mesh AS hidden WHERE hidden.part = part_moveset_mesh.part AND hidden.character IS NULL)"), 0)
	// A fighter with no body row would have no hurtboxes; Mokujin has his own whatever move set he takes.
	testing.expect_value(t, count(handle, "SELECT count(*) FROM character WHERE id NOT IN (SELECT character FROM body)"), 0)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM part WHERE slot = 'body'"), 85)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM anim"), 19439)  // 783 of them camera tracks, 1100 face clips
	testing.expect_value(t, count(handle, "SELECT count(*) FROM move_camera"), 342)  // every intro and win pose
	testing.expect_value(t, count(handle, "SELECT count(*) FROM stage"), 37)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM sound WHERE bank = 'common'"), 79)  // hits, announcer, system
	testing.expect_value(t, count(handle, "SELECT count(*) FROM sound WHERE bank = 'round_calls'"), 21)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM sound WHERE bank = 'names'"), 37)
	testing.expect_value(t, count(handle, "SELECT count(DISTINCT file) FROM sound WHERE bank = 'menu'"), 16)  // 22 records on 16 samples
	testing.expect_value(t, count(handle, "SELECT count(*) FROM costume_part WHERE part NOT GLOB '*_lod' AND part || '/voices' NOT IN (SELECT bank FROM sound)"), 0)  // every costume speaks
	testing.expect_value(t, count(handle, "SELECT count(*) FROM costume WHERE (character, id) NOT IN (SELECT character, costume FROM costume_voice)"), 0)  // Mokujin's voice character has no lines
	testing.expect_value(t, count(handle, "SELECT count(*) FROM voice"), 589)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM voice_name"), 36)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM special_sound"), 25)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM stage_sound WHERE (stage, record) NOT IN (SELECT bank, idx FROM sound)"), 0)  // stage sounds play from the stage's bank
	testing.expect_value(t, count(handle, "SELECT count(*) FROM music"), 44)  // track 18's entry is empty
	testing.expect_value(t, count(handle, "SELECT count(*) FROM stage WHERE music IS NULL"), 1)  // ground_zero fades out
	testing.expect_value(t, count(handle, "SELECT count(*) FROM stage WHERE music NOT IN (SELECT id FROM music)"), 0)
	audio_files: ^db.Stmt
	if !testing.expect_value(t, db.prepare_v2(handle, "SELECT DISTINCT file FROM sound UNION SELECT file FROM music", -1, &audio_files, nil), db.OK) do return
	defer db.finalize(audio_files)
	for db.step(audio_files) == db.ROW {
		file := string(db.column_text(audio_files, 0))
		data, read_err := os.read_entire_file(fmt.tprintf("build/test_packs/tekken5dr/%s", file), context.temp_allocator)
		if !testing.expect(t, read_err == nil && len(data) > 42 && string(data[:4]) == "fLaC", file) do break
	}
	testing.expect_value(t, count(handle, "SELECT count(*) FROM image"), 1913)  // 1773 files, 140 names for one fighter's or stage's art
	// The stock menus find art by stage and character id.
	testing.expect_value(t, count(handle, "SELECT count(*) FROM image WHERE id GLOB 'stage/*' AND substr(id, 7) NOT IN (SELECT id FROM stage)"), 0)
	testing.expect_value(t, count(handle, "SELECT count(*) FROM image WHERE id GLOB 'face/*' AND substr(id, 6) NOT IN (SELECT id FROM character UNION VALUES ('random'))"), 0)
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
	testing.expect_value(t, count(handle, "SELECT count(*) FROM texture"), 11038)
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

// The stock pack opens as a pack, holds the root files every pack needs, and its front names only files it has.
check_stock_pack :: proc(t: ^testing.T) {
	files, opened := titlepack.open_files("build/test_packs/" + tk5.STOCK_PACK)
	if !testing.expect(t, opened, "stock pack did not open") do return
	defer titlepack.close_files(&files)
	for path in ([]string{"pack.toml", titlepack.FRONT, "gameplay.wasm", "gamerender.wasm", "app.wasm", "tk5.db", "ui/pic1.png", "anims/kazuya/0.anim"}) {
		testing.expect(t, path in files.files, path)
	}
	manifest, has_manifest := titlepack.read_manifest("build/test_packs/" + tk5.STOCK_PACK, context.temp_allocator)
	tp, read := titlepack.read_titlepack(manifest, context.temp_allocator)
	testing.expect(t, has_manifest && read && tp.main == "app.wasm", "pack.toml names its entry module")
	testing.expect(t, len(tp.modes) == 1 && tp.modes[0] == {"versus", "gameplay.wasm", "gamerender.wasm"}, "pack.toml has the versus mode")

	front_text, has_front := titlepack.read_file(files, titlepack.FRONT)
	if !testing.expect(t, has_front, "no front") do return
	front, front_err := titlepack.read_front(string(front_text), context.temp_allocator)
	testing.expect_value(t, front_err, "")
	for element in front.elements do if element.file != "" do testing.expect(t, element.file in files.files, element.file)
}
