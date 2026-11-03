package tests

import "core:log"
import "core:os"
import "core:testing"
import "../src/content"
import "../src/imports"
import "../src/match"
import "../src/presentation"
import "../src/titlepack"
import "../src/wasm"

// The entry module asks for a versus match of two bots: bad asks are refused, a good one is copied for the host, and
// the host view shows the phase and winner the host sets.
// The host plays it through match.frame on the stock pack to the sim's match end, and the presenter gets the sim
// view every frame. Needs an import.
@(test)
entry_module_starts_a_bot_match :: proc(t: ^testing.T) {
	if !os.exists(STOCK_PACK) do return
	entry_bytes, entry_built := build_module(t, "tests/ref/match_entry_probe.c")
	presenter_bytes, presenter_built := build_module(t, "tests/ref/match_presenter_probe.c")
	sim_bytes, read_err := os.read_entire_file(GAMEPLAY, context.temp_allocator)
	if !entry_built || !presenter_built || !testing.expect(t, read_err == nil, "build.sh builds " + GAMEPLAY) do return
	pack, opened := content.open_pack(STOCK_PACK)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&pack)
	running := presentation.pack_create(&pack, nil)
	defer presentation.pack_destroy(running)
	engine := wasm.engine_create()
	defer wasm.engine_destroy(engine)
	codes: [3]wasm.Module
	for bytes, i in ([][]byte{entry_bytes, presenter_bytes, sim_bytes}) {
		err: string
		codes[i], err = wasm.compile(engine, bytes)
		if !testing.expect_value(t, err, "") do return
	}
	defer for code in codes do wasm.module_destroy(code)

	modes := []titlepack.Mode{{"versus", "gameplay.wasm", "gamerender.wasm"}}
	state := imports.entry_create(modes)
	entry, err := presentation.create(engine, "entry", running)
	if !testing.expect_value(t, err, "") do return
	defer imports.module_destroy(entry)
	testing.expect_value(t, imports.define_entry(entry.linker, &state), "")
	if !testing.expect_value(t, presentation.start(entry, codes[0]), "") do return
	ask :: proc(t: ^testing.T, entry: ^imports.Module, name: string) -> i32 {
		result := []wasm.Val{{}}
		testing.expect_value(t, wasm.call(entry.store, entry.instance, name, nil, result), "")
		return result[0].of.i32
	}
	testing.expect_value(t, ask(t, entry, "read_view"), 0 * 10 + 0 + 1)  // no match yet
	testing.expect_value(t, ask(t, entry, "ask_unknown_mode"), -1)
	testing.expect_value(t, ask(t, entry, "ask_bad_params"), -1)
	testing.expect_value(t, ask(t, entry, "ask_versus"), 0)
	testing.expect_value(t, ask(t, entry, "ask_versus"), -1)  // one is asked for already
	asked, has := state.asked.?
	if !testing.expect(t, has) do return
	state.asked = nil  // the host has taken it
	defer imports.match_request_destroy(&asked, state.allocator)
	testing.expect_value(t, asked.mode.sim, "gameplay.wasm")
	testing.expect_value(t, asked.bot_sides, bit_set[0 ..< 2; u32]{0, 1})
	testing.expect_value(t, asked.params["rounds"], 2)
	testing.expect_value(t, string(cstring(raw_data(asked.loadouts[1]))), "kazuya")
	state.view.match = .Running
	testing.expect_value(t, ask(t, entry, "ask_versus"), -1)  // one is running
	state.view.match, state.view.winner = .Ended, 1
	testing.expect_value(t, ask(t, entry, "read_view"), 2 * 10 + 1 + 1)

	m, start_err := match.start(engine, codes[2], codes[1], running, asked, 7)
	if !testing.expect_value(t, start_err, "") do return
	defer match.stop(m)
	FRAMES_MAX :: 40_000
	frames := 0
	for ; frames < FRAMES_MAX; frames += 1 {
		ended, winner, frame_err := match.frame(m, running, match.TICK_NS, {})
		if !testing.expect_value(t, frame_err, "") do return
		if ended {
			testing.expect(t, winner >= -1 && winner <= 1, "the winner is a side or a draw")
			break
		}
	}
	testing.expect(t, frames < FRAMES_MAX, "the match did not end")
	views := []wasm.Val{{}}
	testing.expect_value(t, wasm.call(m.presenter.store, m.presenter.instance, "views", nil, views), "")
	testing.expect_value(t, views[0].of.i32, i32(frames))
	log.infof("the match ended after %d frames", frames)
}
