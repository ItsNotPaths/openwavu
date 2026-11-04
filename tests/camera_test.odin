package tests

import "core:math"
import "core:os"
import "core:testing"
import "../src/convert"
import tk5_convert "../src/convert/tk5"
import formats "../src/formats/tk5"
import tk5 "../src/importer/tk5"

CAMERA_FILE :: "build/camera_test.anim"

@(private = "file")
Camera_Check :: struct {
	eye, target: [3]f32,
	fov:         f32,
}

// Frame `frame` of clip `clip`, as the importer writes it.
@(private = "file")
camera_frame :: proc(t: ^testing.T, data: []byte, clip, frame: int, packing: tk5_convert.Camera_Packing) -> (check: Camera_Check, ok: bool) {
	bank, read := formats.read_camera_bank(data)
	if !testing.expect(t, read, "camera bank did not read") do return
	raw, decoded := formats.read_clip(bank, clip, context.temp_allocator)
	if !testing.expect(t, decoded, "camera clip did not decode") do return
	_, written := tk5_convert.write_camera_anim(CAMERA_FILE, raw, bank.channels, packing)
	if !testing.expect(t, written) do return
	defer os.remove(CAMERA_FILE)
	file, _ := os.read_entire_file(CAMERA_FILE, context.temp_allocator)
	a, parsed := convert.read_anim(file, context.temp_allocator)
	if !testing.expect(t, parsed && a.layout == "camera" && frame < a.frames) do return
	v := a.values[frame * 9:]
	return {{v[0], v[1], v[2]}, {v[3], v[4], v[5]}, v[6]}, true
}

@(private = "file")
expect_camera :: proc(t: ^testing.T, got, want: Camera_Check, name: string) {
	near :: proc(a, b: [3]f32) -> bool {return abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 && abs(a.z - b.z) < 1}
	testing.expectf(t, near(got.eye, want.eye) && near(got.target, want.target) && math.abs(got.fov - want.fov) < 0.0002, "%s: got %v, want %v", name, got, want)
}

// The camera tracks give the shots the game shows (values from tk5decomp docs/camera.md 2.1 and 2.2, read from the game).
@(test)
camera_tracks_match_the_game :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)
	archive := tk5.Archive{table, f}

	// Paul's first intro: a close shot from the front at head height.
	container, has := tk5.read_entry(archive, formats.CHARACTERS[0].container)
	sections, split := formats.sections(container, context.temp_allocator)
	if !testing.expect(t, has && split && len(sections) > formats.BANK_CAMERAS) do return
	if got, read := camera_frame(t, sections[formats.BANK_CAMERAS], 0, 0, .Scaled); read {
		expect_camera(t, got, {{-124, 1011, 1310}, {-135, 1675, -551}, 39.59 * math.RAD_PER_DEG}, "paul intro")
	}

	// The first throw camera, turned to the fighter tracks' frame: the game's (347, 1642, -5517) becomes (5517, 1642, 347).
	global, has_global := tk5.read_entry(archive, formats.GLOBAL_CAMERAS)
	if !testing.expect(t, has_global) do return
	if got, read := camera_frame(t, global, 0, 0, .Plain); read {
		expect_camera(t, got, {{5517, 1642, 347}, {200, 1200, 200}, 38 * math.RAD_PER_DEG}, "throw camera 0")
	}
}

// Every throw camera names a shot that exists: a clip of the global bank or a hand-coded id (counts from docs/camera.md 4.2).
@(test)
throw_cameras_name_real_tracks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	eboot, err := os.read_entire_file(TK5 + "/game/USRDIR/EBOOT.elf", context.temp_allocator)
	if err != nil do return
	build, _ := formats.find_build("NPUB30009")
	records, read := formats.read_throw_cameras(eboot, build, context.temp_allocator)
	if !testing.expect(t, read, "throw camera table did not read") do return
	categories := map[int]bool{}
	defer delete(categories)
	for r in records do categories[r.category] = true
	testing.expect_value(t, len(records), 782)
	testing.expect_value(t, len(categories), 229)

	table, has_table := read_table()
	if !has_table do return
	defer delete(table)
	f, open_err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if open_err != nil do return
	defer os.close(f)
	global, _ := tk5.read_entry(tk5.Archive{table, f}, formats.GLOBAL_CAMERAS)
	bank, bank_read := formats.read_camera_bank(global)
	if !testing.expect(t, bank_read) do return
	for r in records {
		for id in ([]u16{r.left, r.right}) {
			testing.expectf(t, id < formats.CODED_CAMERAS || int(id - formats.CODED_CAMERAS) < bank.count, "category %d: camera %d past the bank", r.category, id)
		}
	}
}
