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

// The stock menu starts on the stock pack, and Down then button 1 asks for a ghost match: two different db characters,
// no bot side. Needs an import.
@(test)
stock_menu_asks_for_a_ghost_match :: proc(t: ^testing.T) {
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
	state := imports.entry_create([]titlepack.Mode{{"versus", "gameplay.wasm", "gamerender.wasm"}})
	entry, err := presentation.create(engine, "app.wasm", running)
	if !testing.expect_value(t, err, "") do return
	defer imports.module_destroy(entry)
	testing.expect_value(t, imports.define_entry(entry.linker, &state), "")
	if !testing.expect_value(t, presentation.start(entry, code), "") do return

	DOWN :: 1 << 1
	BUTTON_1 :: 1 << 4
	for pad in ([]u32{0, DOWN, 0, BUTTON_1}) {
		running.pads[0] = pad
		if !testing.expect_value(t, presentation.frame(entry, running, 1.0 / 60), "") do return
	}
	asked, has := state.asked.?
	if !testing.expect(t, has, "no match was asked for") do return
	defer imports.match_request_destroy(&asked, state.allocator)
	testing.expect_value(t, asked.bot_sides, bit_set[0 ..< 2; u32]{})
	fighter, opponent := string(cstring(raw_data(asked.loadouts[0]))), string(cstring(raw_data(asked.loadouts[1])))
	testing.expect_value(t, fighter, "paul")
	testing.expect(t, opponent != "" && opponent != fighter, "the opponent is another character")
}
