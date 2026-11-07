package tests

import "core:os"
import "core:testing"
import sdl "vendor:sdl3"
import "../src/content"
import "../src/imports"
import "../src/presentation"
import "../src/titlepack"
import "../src/wasm"

STOCK_APP :: "build/modules/app.wasm"

// Past the title, the stock menus (pick with button 3, back with button 4) leave the pack on Exit, and they ask for the
// match the player picked: Versus CPU, the player's fighter,
// the CPU's fighter with its costume button, then the stage. Needs an import.
@(test)
stock_menus_ask_for_the_picked_match :: proc(t: ^testing.T) {
	if !os.exists(STOCK_PACK) do return
	bytes, read_err := os.read_entire_file(STOCK_APP, context.temp_allocator)
	if !testing.expect(t, read_err == nil, "build.sh builds " + STOCK_APP) do return
	pack, opened := content.open_pack(STOCK_PACK)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&pack)
	surface := sdl.CreateSurface(320, 240, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	running := presentation.pack_create(&pack, renderer)
	defer presentation.pack_destroy(running)
	engine := wasm.engine_create()
	defer wasm.engine_destroy(engine)
	code, compile_err := wasm.compile(engine, bytes)
	if !testing.expect_value(t, compile_err, "") do return
	defer wasm.module_destroy(code)
	tp, read := titlepack.read_titlepack(PARAMS_MANIFEST, context.temp_allocator)
	if !testing.expect(t, read) do return
	state := imports.entry_create(tp)
	entry, err := presentation.create(engine, "app.wasm", running)
	if !testing.expect_value(t, err, "") do return
	defer imports.module_destroy(entry)
	testing.expect_value(t, imports.define_entry(entry.linker, &state), "")
	if !testing.expect_value(t, presentation.start(entry, code), "") do return

	UP :: 1 << 0
	DOWN :: 1 << 1
	RIGHT :: 1 << 3
	BUTTON_1 :: 1 << 4
	BUTTON_2 :: 1 << 5
	PICK :: 1 << 6  // button 3
	BACK :: 1 << 7  // button 4
	// Any button leaves the title; up wraps to Exit.
	for pad in ([]u32{BUTTON_1, 0, UP, 0, PICK, 0}) {
		running.pads[0] = pad
		if !testing.expect_value(t, presentation.frame(entry, running, 1.0 / 60), "") do return
	}
	testing.expect(t, state.exit, "Exit did not leave the pack")
	running.pads[0] = DOWN
	if !testing.expect_value(t, presentation.frame(entry, running, 1.0 / 60), "") do return
	// Versus CPU; paul with costume 1; one right to law, with costume 2, back out of law and pick him again; one right to
	// the second stage.
	for pad in ([]u32{0, PICK, 0, BUTTON_1, 0, RIGHT, 0, BUTTON_2, 0, BACK, 0, BUTTON_2, 0, RIGHT, 0, PICK}) {
		running.pads[0] = pad
		if !testing.expect_value(t, presentation.frame(entry, running, 1.0 / 60), "") do return
	}
	asked, has := state.asked.?
	if !testing.expect(t, has, "no match was asked for") do return
	defer imports.match_request_destroy(&asked, state.allocator)
	testing.expect_value(t, asked.bot_sides, bit_set[0 ..< 2; u32]{1})
	sides: [2]T5_Loadout
	for &side, i in sides do copy(([^]byte)(&side)[:size_of(T5_Loadout)], asked.loadouts[i])
	testing.expect_value(t, string(cstring(&sides[0].character[0])), "paul")
	testing.expect_value(t, sides[0].costume, 1)
	testing.expect_value(t, string(cstring(&sides[1].character[0])), "law")
	testing.expect_value(t, sides[1].costume, 2)
	testing.expect_value(t, asked.params["stage"], "burning_temple")
}
