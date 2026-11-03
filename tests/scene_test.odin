package tests

import "core:os"
import "core:strings"
import "core:testing"
import "../src/content"
import "../src/imports"
import "../src/presentation"
import "../src/render"
import "../src/wasm"

// A scene a C module builds with ow_scene.h reads back field for field (the last field of each struct proves the two
// layouts agree), asset ids name pack files, and a block that does not read stops the module.
@(test)
scene_from_a_module_reads_back :: proc(t: ^testing.T) {
	bytes, built := build_module(t, "tests/ref/scene_probe.c")
	if !built do return
	tar, written := write_test_pack(t, #procedure)
	if !written do return
	defer os.remove(tar)
	pack, opened := content.open_pack(tar)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&pack)
	running := presentation.pack_create(&pack, nil)
	defer presentation.pack_destroy(running)
	r := rig_create(64 << 20)
	defer rig_destroy(r)
	testing.expect_value(t, imports.define_scene(r.linker, &running.scene), "")
	code, compile_err := wasm.compile(r.engine, bytes)
	if !testing.expect_value(t, compile_err, "") do return
	defer wasm.module_destroy(code)
	inst, inst_err := wasm.instantiate(r.linker, r.store, code)
	if !testing.expect_value(t, inst_err, "") do return

	assets_ok := []wasm.Val{{}}
	testing.expect_value(t, wasm.call(r.store, inst, "send", nil, assets_ok), "")
	testing.expect_value(t, assets_ok[0].of.i32, 1)
	s := &running.scene.scene
	testing.expect(t, running.scene.sent)
	testing.expect_value(t, s.camera.roll, 0.5)
	testing.expect_value(t, s.fog.end, 30)
	testing.expect_value(t, len(s.lights), 1)
	testing.expect_value(t, s.lights[0].range, 7)
	if !testing.expect_value(t, len(s.nodes), 2) do return
	fighter, prop := s.nodes[0], s.nodes[1]
	testing.expect_value(t, string(cstring(&fighter.id[0])), "fighter")
	testing.expect_value(t, running.scene.assets.paths[fighter.asset - 1], "notes.txt")
	testing.expect_value(t, len(fighter.bones), 3)
	testing.expect_value(t, fighter.bones[2].scale.z, 2)
	testing.expect_value(t, fighter.flags, bit_set[render.Node_Flag; u32]{.No_Blend})
	testing.expect_value(t, fighter.class, render.Node_Class.Scenery)
	testing.expect_value(t, string(cstring(&prop.id[0])), "broken_prop")
	testing.expect_value(t, prop.part, 9)
	testing.expect_value(t, prop.flags, bit_set[render.Node_Flag; u32]{.Hidden})
	if testing.expect_value(t, len(s.fx), 1) {
		testing.expect_value(t, s.fx[0].node, 1)
		testing.expect_value(t, s.fx[0].age, 1.5)
		testing.expect_value(t, s.fx[0].seed, 77)
	}

	message := wasm.call(r.store, inst, "send_broken")
	testing.expectf(t, strings.contains(message, "ow_scene_submit: a node list is outside the scene"), "got %q", message)
}
