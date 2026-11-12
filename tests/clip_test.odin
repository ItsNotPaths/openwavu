package tests

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import convert "../src/convert/tk5"
import "../src/db"
import formats "../src/formats/tk5"
import tk5 "../src/importer/tk5"
import "../vendor/cgltf"

CLIP_ROOT :: "build/clip_test"
CLIP_LOAD :: "build/clip_load"
NEUTRAL_FACE :: 1
NEUTRAL_TURN_LIMIT :: 30.0  // degrees off the bind rotation: neutral faces differ up to 18 (Marduk), a flipped rotation by ~120

// Every character's finger and face clips are valid glTF and load in the presenter (tests/ref/clip_load.c), and each
// neutral face sits on the bind pose: the clips and the model keep rotations the same way.
@(test)
clip_banks_load_for_every_character :: proc(t: ^testing.T) {
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)
	built := build_loader_tool(CLIP_LOAD, "tests/ref/clip_load.c", "-Ivendor/cgltf/src", "modules/tk5/gamerender/clip_bank.c",
		"modules/tk5/gamerender/hand_bank.c", "modules/tk5/gamerender/face_bank.c")
	if !testing.expect(t, built, "tests/ref/clip_load.c did not build") do return

	os.remove_all(CLIP_ROOT)
	defer os.remove_all(CLIP_ROOT)
	im := tk5.Import{archive = {table, f}, root = CLIP_ROOT}
	create_err: string
	im.w, create_err = db.create(CLIP_ROOT + ".db", TK5_SCHEMA)
	if !testing.expect_value(t, create_err, "") do return
	defer os.remove(CLIP_ROOT + ".db")

	characters := formats.CHARACTERS
	for name, i in MOTBIN_NAMES {
		defer free_all(context.temp_allocator)
		packed, _ := tk5.read_entry(&im, formats.MOTBIN_FIRST + 2 * i)
		data, unpacked := formats.unlz(packed, context.temp_allocator)
		m, read := formats.read_motbin(data, context.temp_allocator)
		container, has := tk5.read_entry(&im, characters[i].container)
		sections, split := formats.sections(container, context.temp_allocator)
		bones, has_bones := tk5.character_bones(&im, characters[i])
		face_poses, has_face_poses := formats.embedded_bank(m, data, formats.BANK_FACE)
		if !testing.expect(t, unpacked && read && has && split && has_bones && has_face_poses && len(sections) > formats.BANK_FACE, name) do continue
		owner := formats.container_owner(characters[i].container)
		testing.expect_value(t, convert.write_moveset_rows(&im.w, name, owner, i, m), "")  // the moves name the bank owner
		tk5.write_hand_bank(&im, fmt.tprintf("%s/hand_poses", name), data[m.bank_offsets[formats.BANK_HANDS]:], bones)
		tk5.write_face_bank(&im, fmt.tprintf("%s/face_poses", name), face_poses, bones)
		if owner != name do continue
		tk5.write_hand_bank(&im, fmt.tprintf("%s/hand_gestures", owner), sections[formats.BANK_HANDS], bones)
		if !formats.empty_bank(sections[formats.BANK_FACE]) {
			tk5.write_face_bank(&im, fmt.tprintf("%s/face_clips", owner), sections[formats.BANK_FACE], bones)
		}
	}
	testing.expect_value(t, im.failure, "")
	if !testing.expect_value(t, db.finish(&im.w), "") do return

	for name in MOTBIN_NAMES {
		state, stdout, stderr, exec_err := os.process_exec({command = {CLIP_LOAD, CLIP_ROOT + ".db", CLIP_ROOT, name}}, context.temp_allocator)
		if !testing.expectf(t, exec_err == nil && state.exit_code == 0, "%s: %s", name, string(stderr)) do continue
		counts := strings.fields(string(stdout), context.temp_allocator)
		testing.expectf(t, len(counts) == 4 && counts[0] != "0" && counts[1] != "0" && counts[2] != "0", "%s: clip counts %s", name, stdout)
		path := fmt.tprintf("%s/anims/%s/face_poses.glb", CLIP_ROOT, name)
		turn, read_turn := neutral_face_turn(path)
		testing.expectf(t, read_turn && turn < NEUTRAL_TURN_LIMIT, "%s: the neutral face is %.1f degrees off the bind pose", name, turn)
	}
}

// The largest angle between a face bone's rotation in the neutral face and its bind rotation; false if the file is not valid glTF.
@(private = "file")
neutral_face_turn :: proc(path: string) -> (degrees: f64, ok: bool) {
	file, parsed := cgltf.parse_file({}, strings.clone_to_cstring(path, context.temp_allocator))
	if parsed != .success do return
	defer cgltf.free(file)
	if cgltf.load_buffers({}, file, strings.clone_to_cstring(path, context.temp_allocator)) != .success || cgltf.validate(file) != .success do return
	if len(file.animations) == 0 do return
	for channel in file.animations[0].channels {
		if channel.target_path != .rotation do continue
		key: [4]f32
		if !cgltf.accessor_read_float(channel.sampler.output, NEUTRAL_FACE, raw_data(key[:]), 4) do return
		bind := channel.target_node.has_rotation ? channel.target_node.rotation : [4]f32{0, 0, 0, 1}
		alignment := abs(f64(key.x * bind.x + key.y * bind.y + key.z * bind.z + key.w * bind.w))
		degrees = max(degrees, 2 * math.to_degrees(math.acos(min(alignment, 1))))
	}
	return degrees, true
}
