// The TK6 import of the whole roster and every stage gives a pack the TK6 sim plays and the host draws. Needs
// ../tk6decomp/game and build.sh's build/modules/tk6; skips without the game.
package tests

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "../src/content"
import "../src/imports"
import "../src/render"
import "../src/sim"
import "../src/titlepack"
import "../src/wasm"
import tk6 "../src/formats/tk6"
import tk6_importer "../src/importer/tk6"

TK6_GAME :: "../tk6decomp/game"
TK6_TEST_PACKS :: "build/tk6_test_packs"
TK6_GAMEPLAY :: "build/modules/tk6/gameplay.wasm"
TK6_STAGE :: "stage_00"

@(private = "file")
tk6_import: struct {
	once:  sync.Once,
	error: string,
}

// One import for every test of this file; "" when the game is not here.
@(private = "file")
tk6_pack :: proc(t: ^testing.T) -> (pack: string, ok: bool) {
	if !os.exists(TK6_GAME) do return
	sync.once_do(&tk6_import.once, proc() {tk6_import.error = tk6_importer.build_pack({TK6_GAME}, TK6_TEST_PACKS)})
	return TK6_TEST_PACKS + "/" + tk6_importer.STOCK_PACK, testing.expect_value(t, tk6_import.error, "")
}

TK6_POSE_TOOL :: "build/tk6_pose_check"
TK5_PACK :: "packs/tekken5dr"

// Frame 0 of an anim through the TK6 sim's pose code (tests/ref/tk6_pose_check.c): each bone's world position in mm.
@(private = "file")
pose_bones :: proc(database, character, anim: string) -> (bones: [dynamic][3]f32, ok: bool) {
	state, stdout, _, err := os.process_exec({command = {TK6_POSE_TOOL, database, character, anim}}, context.temp_allocator)
	if err != nil || state.exit_code != 0 do return
	bones.allocator = context.temp_allocator
	for line in strings.split_lines(string(stdout), context.temp_allocator) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) != 4 do continue
		position: [3]f32
		for axis in 0 ..< 3 do position[axis] = strconv.parse_f32(fields[axis + 1]) or_return
		append(&bones, position)
	}
	return bones, true
}

@(private = "file")
build_pose_tool :: proc() -> bool {
	sim :: "modules/tk6/sim/"
	state, _, _, err := os.process_exec({command = {"cc", "-std=c23", "-fwrapv", "-ffp-contract=off", "-Imodules/tk6", "-Isdk/include", "-Ivendor/sqlite", "-Ivendor/jsmn",
		"-o", TK6_POSE_TOOL, "tests/ref/tk6_pose_check.c", "modules/tk6/load.c", sim + "stage_file.c", sim + "anim.c", sim + "fighter_data.c", sim + "motbin.c",
		sim + "skel.c", sim + "math.c", sim + "quat.c", sim + "vec.c", "vendor/sqlite/libsqlite3.a", "-lpthread", "-lm"}}, context.temp_allocator)
	return err == nil && state.exit_code == 0
}

// Kazuya's standing idle stands: head over chest over hips over feet, feet on the floor, and within a few mm of TK5's
// idle through the same pose code (the two games share this clip).
// (hole tk6-scenario-tests :tags (tk6 sim) :sev gap) no scripted-input harness; must cover Kazuya counter hit d/f+2 into the just-frame electric, and d/f+1,2 bounding on hit two while d/f+1 alone gives no airborne status, one bound per combo.
@(test)
tk6_idle_stands :: proc(t: ^testing.T) {
	pack_dir, imported := tk6_pack(t)
	if !imported || !os.exists(TK5_PACK) do return
	if !testing.expect(t, build_pose_tool(), "tests/ref/tk6_pose_check.c did not build") do return
	IDLE_TK6 :: "/anims/kazuya/66.anim"
	IDLE_TK5 :: "/anims/kazuya/16.anim"
	HIPS, CHEST, HEAD, RIGHT_FOOT, LEFT_FOOT :: 0, 2, 4, 16, 20
	FOOT_HEIGHT_MAX :: 200
	CLOSE_TO_TK5 :: 20  // mm

	bones, posed := pose_bones(strings.concatenate({pack_dir, "/tk6.db"}, context.temp_allocator), "kazuya", strings.concatenate({pack_dir, IDLE_TK6}, context.temp_allocator))
	reference, reference_posed := pose_bones(TK5_PACK + "/tk5.db", "kazuya", TK5_PACK + IDLE_TK5)
	if !testing.expect(t, posed && reference_posed, "the pose tool failed") do return
	testing.expectf(t, bones[HEAD].y > bones[CHEST].y && bones[CHEST].y > bones[HIPS].y, "head %v chest %v hips %v", bones[HEAD].y, bones[CHEST].y, bones[HIPS].y)
	for foot in ([]int{RIGHT_FOOT, LEFT_FOOT}) {
		testing.expectf(t, bones[HIPS].y > bones[foot].y, "foot %d above the hips", foot)
		testing.expectf(t, bones[foot].y > 0 && bones[foot].y < FOOT_HEIGHT_MAX, "foot %d height %v", foot, bones[foot].y)
	}
	if !testing.expect_value(t, len(bones), len(reference)) do return
	for bone, slot in bones {
		apart := bone - reference[slot]
		distance := apart.x * apart.x + apart.y * apart.y + apart.z * apart.z
		testing.expectf(t, distance < CLOSE_TO_TK5 * CLOSE_TO_TK5, "bone %d: %v against TK5's %v", slot, bone, reference[slot])
	}
}

// Kazuya vs Kazuya on the stage: two bots play the match to its end in the TK6 sim. With no clock only falls end
// rounds, so the moves, anims and hit boxes connect.
@(test)
tk6_import_plays_a_match :: proc(t: ^testing.T) {
	pack_dir, imported := tk6_pack(t)
	if !imported do return
	code, read_err := os.read_entire_file(TK6_GAMEPLAY, context.temp_allocator)
	if !testing.expect(t, read_err == nil, "build.sh builds " + TK6_GAMEPLAY) do return
	pack, opened := content.open_pack(pack_dir)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&pack)
	engine := wasm.engine_create()
	defer wasm.engine_destroy(engine)
	module, compile_err := wasm.compile(engine, code)
	if !testing.expect_value(t, compile_err, "") do return
	defer wasm.module_destroy(module)

	params := make(map[string]string, context.temp_allocator)
	params["stage"] = TK6_STAGE
	params["round_time"] = "0"
	w, err := sim.create(engine, module, &pack, params, {loadout_bytes("kazuya"), loadout_bytes("kazuya")}, 7)
	if !testing.expect_value(t, err, "") do return
	defer sim.destroy(w)
	MATCH_FRAMES_MAX :: 60_000
	for _ in 0 ..< MATCH_FRAMES_MAX {
		pads: [2]sim.Input
		for side in 0 ..< 2 {
			pads[side], err = sim.bot_pad(w, side)
			if !testing.expect_value(t, err, "") do return
		}
		if !testing.expect_value(t, sim.step(w, pads), "") do return
		if len(w.inputs.events) > 0 && w.inputs.events[len(w.inputs.events) - 1].kind == .Match_End do break
	}
	kos := 0
	for event in w.inputs.events do if event.kind == .KO do kos += 1
	ended := len(w.inputs.events) > 0 && w.inputs.events[len(w.inputs.events) - 1].kind == imports.Event_Kind.Match_End
	testing.expect(t, ended && kos >= 2, "the match did not end in falls")
}

// Every character against itself, each on the next stage in turn: the sim starts and two bots fight for a while.
@(test)
tk6_roster_plays :: proc(t: ^testing.T) {
	pack_dir, imported := tk6_pack(t)
	if !imported do return
	code, read_err := os.read_entire_file(TK6_GAMEPLAY, context.temp_allocator)
	if !testing.expect(t, read_err == nil, "build.sh builds " + TK6_GAMEPLAY) do return
	pack, opened := content.open_pack(pack_dir)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&pack)
	engine := wasm.engine_create()
	defer wasm.engine_destroy(engine)
	module, compile_err := wasm.compile(engine, code)
	if !testing.expect_value(t, compile_err, "") do return
	defer wasm.module_destroy(module)

	FIGHT_FRAMES :: 600
	stages := tk6.STAGES
	for character, number in tk6.CHARACTERS {
		params := make(map[string]string, context.temp_allocator)
		params["stage"] = stages[number % len(stages)].id
		w, err := sim.create(engine, module, &pack, params, {loadout_bytes(character.id), loadout_bytes(character.id)}, 7)
		if !testing.expectf(t, err == "", "%s on %s: %s", character.id, params["stage"], err) do continue
		defer sim.destroy(w)
		for _ in 0 ..< FIGHT_FRAMES {
			pads: [2]sim.Input
			for side in 0 ..< 2 do pads[side], err = sim.bot_pad(w, side)
			if err == "" do err = sim.step(w, pads)
			if !testing.expectf(t, err == "", "%s: %s", character.id, err) do break
		}
	}
}

// The fighter's parts and the stage load in the host's model loader, with their textures.
@(test)
tk6_import_models_load :: proc(t: ^testing.T) {
	pack_dir, imported := tk6_pack(t)
	if !imported do return
	g, has_gpu := test_gpu_create(t)
	if !has_gpu do return
	defer test_gpu_destroy(&g)
	files, opened := titlepack.open_files(pack_dir)
	if !testing.expect(t, opened) do return
	defer titlepack.close_files(&files)
	assets := render.assets_create(files)
	defer render.assets_destroy(&assets, &g)
	for model in ([]string{"parts/kazuya/kazuya_1_body.glb", "parts/kazuya/kazuya_part_59.glb", "stages/" + TK6_STAGE + ".glb"}) {
		loaded := render.asset_model(&assets, &g, render.asset_id(&assets, model))
		if !testing.expectf(t, loaded != nil, "%s does not load", model) do continue
		textured := false
		for mesh in loaded.meshes do for primitive in mesh do textured ||= primitive.texture != nil
		testing.expectf(t, textured, "%s draws no texture", model)
	}
}
