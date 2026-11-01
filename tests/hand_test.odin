package tests

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:testing"
import convert "../src/convert"
import "../src/db"
import formats "../src/formats/tk5"
import tk5 "../src/importer/tk5"

HAND_DUMP :: "build/hand_dump"
HAND_ROOT :: "build/hand_test"

// The finger anims hold every frame the sim's hand bank decoder reads from tk5decomp's .t5h, bit for bit.
@(test)
hand_anims_match_sim_files :: proc(t: ^testing.T) {
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)
	if !testing.expect(t, build_sim_tool(HAND_DUMP, "tests/ref/hand_dump.c"), "tests/ref/hand_dump.c did not build") do return

	os.remove_all(HAND_ROOT)
	defer os.remove_all(HAND_ROOT)
	im := tk5.Import{archive = {table, f}, root = HAND_ROOT}
	create_err: string
	im.w, create_err = db.create(HAND_ROOT + ".db", TK5_SCHEMA)
	if !testing.expect_value(t, create_err, "") do return
	defer os.remove(HAND_ROOT + ".db")
	defer db.finish(&im.w)

	characters := formats.CHARACTERS
	for name, i in MOTBIN_NAMES {
		defer free_all(context.temp_allocator)
		packed, _ := tk5.read_entry(im.archive, formats.MOTBIN_FIRST + 2 * i)
		data, unpacked := formats.unlz(packed, context.temp_allocator)
		m, read := formats.read_motbin(data, context.temp_allocator)
		container, has := tk5.read_entry(im.archive, characters[i].container)
		sections, split := formats.sections(container, context.temp_allocator)
		if !testing.expect(t, unpacked && read && has && split && len(sections) > formats.BANK_HANDS, name) do continue
		poses, gestures := fmt.tprintf("%s/hand_poses", name), fmt.tprintf("%s/hand_gestures", name)
		tk5.write_hand_bank(&im, poses, data[m.bank_offsets[formats.BANK_HANDS]:])
		tk5.write_hand_bank(&im, gestures, sections[formats.BANK_HANDS])

		got := make([dynamic]byte, context.temp_allocator)
		for owner in ([]string{poses, gestures}) do append_clips(&got, owner)
		want := run_sim_tool(HAND_DUMP, fmt.tprintf(TK5 + "/data/%s.t5h", name))
		testing.expectf(t, want != nil && bytes.equal(want, got[:]), "%s: hand anims differ from the sim file (%d vs %d bytes)", name, len(got), len(want))
	}
}

// Per clip file, in order: u32 frames, the values.
@(private = "file")
append_clips :: proc(out: ^[dynamic]byte, owner: string) {
	for i := 0; ; i += 1 {
		data, err := os.read_entire_file(fmt.tprintf(HAND_ROOT + "/anims/%s/%d.anim", owner, i), context.temp_allocator)
		if err != nil do return
		a, ok := convert.read_anim(data, context.temp_allocator)
		if !ok || a.layout != "tk5hand" do return
		buf: [4]byte
		endian.put_u32(buf[:], .Little, u32(a.frames))
		append(out, ..buf[:])
		for v in a.values {
			endian.put_f32(buf[:], .Little, v)
			append(out, ..buf[:])
		}
	}
}
