package tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "../src/convert"
import "../src/db"
import formats "../src/formats/tk5"
import tk5 "../src/importer/tk5"

FACE_ROOT :: "build/face_test"

// Every character gets its face poses, and every face clip has the one channel layout the visual's fixed bone table reads
// (modules/tk5/gamerender/face_bank.c).
@(test)
face_banks_import_for_every_character :: proc(t: ^testing.T) {
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)

	os.remove_all(FACE_ROOT)
	defer os.remove_all(FACE_ROOT)
	im := tk5.Import{archive = {table, f}, root = FACE_ROOT}
	create_err: string
	im.w, create_err = db.create(FACE_ROOT + ".db", TK5_SCHEMA)
	if !testing.expect_value(t, create_err, "") do return
	defer os.remove(FACE_ROOT + ".db")

	characters := formats.CHARACTERS
	files: [dynamic]string
	defer delete(files)
	for name, i in MOTBIN_NAMES {
		packed, _ := tk5.read_entry(&im, formats.MOTBIN_FIRST + 2 * i)
		data, unpacked := formats.unlz(packed, context.temp_allocator)
		m, read := formats.read_motbin(data, context.temp_allocator)
		container, has := tk5.read_entry(&im, characters[i].container)
		sections, split := formats.sections(container, context.temp_allocator)
		if !testing.expect(t, unpacked && read && has && split && len(sections) > formats.BANK_FACE, name) do continue
		poses, has_poses := formats.embedded_bank(m, data, formats.BANK_FACE)
		if !testing.expect(t, has_poses, name) do continue
		tk5.write_face_bank(&im, fmt.tprintf("%s/face_poses", name), poses)
		append(&files, fmt.tprintf("%s/anims/%s/face_poses/0.anim", FACE_ROOT, name))
		if !formats.empty_bank(sections[formats.BANK_FACE]) {
			tk5.write_face_bank(&im, fmt.tprintf("%s/face_clips", name), sections[formats.BANK_FACE])
			append(&files, fmt.tprintf("%s/anims/%s/face_clips/0.anim", FACE_ROOT, name))
		}
	}
	testing.expect_value(t, im.failure, "")
	if !testing.expect_value(t, db.finish(&im.w), "") do return

	layout: []convert.Anim_Channel
	for file in files {
		data, read_err := os.read_entire_file(file, context.temp_allocator)
		if !testing.expectf(t, read_err == nil, "%s: missing", file) do continue
		a, parsed := convert.read_anim(data, context.temp_allocator)
		if !testing.expectf(t, parsed && a.layout == "tk5face" && len(a.channels) == formats.FACE_CHANNELS && a.frames > 0, "%s: not a face anim", file) do continue
		if layout == nil do layout = slice.clone(a.channels)
		testing.expectf(t, slice.equal(a.channels, layout), "%s: another channel layout", file)
	}
	delete(layout)
}
