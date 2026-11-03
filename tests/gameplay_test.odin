package tests

import "core:log"
import "core:os"
import "core:testing"
import "../src/content"
import "../src/imports"
import "../src/sim"
import "../src/wasm"

STOCK_PACK :: "packs/tekken5dr.tar"
GAMEPLAY :: "build/modules/gameplay.wasm"

// modules/tk5/loadout.h
T5_Loadout :: struct {
	character: [32]u8,
	costume:   u32,
}

loadout_bytes :: proc(character: string) -> []byte {
	l := new(T5_Loadout, context.temp_allocator)
	copy(l.character[:], character)
	l.costume = 1
	return ([^]byte)(l)[:size_of(T5_Loadout)]
}

stage_params :: proc() -> map[string]string {
	params := make(map[string]string, context.temp_allocator)
	params["stage"] = "dragons_nest"
	return params
}

// Two bots play an offline match to its end in the stock sim module, on the stock pack. Needs an import.
@(test)
stock_sim_plays_a_match :: proc(t: ^testing.T) {
	if !os.exists(STOCK_PACK) do return
	pack, opened := content.open_pack(STOCK_PACK)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&pack)
	code, read_err := os.read_entire_file(GAMEPLAY, context.temp_allocator)
	if !testing.expect(t, read_err == nil, "build.sh builds " + GAMEPLAY) do return

	engine := wasm.engine_create()
	defer wasm.engine_destroy(engine)
	module, compile_err := wasm.compile(engine, code)
	if !testing.expect_value(t, compile_err, "") do return
	defer wasm.module_destroy(module)
	w, err := sim.create(engine, module, &pack, stage_params(), {loadout_bytes("paul"), loadout_bytes("kazuya")}, 7)
	if !testing.expect_value(t, err, "") do return
	defer sim.destroy(w)

	MATCH_FRAMES_MAX :: 40_000  // five full rounds with their intros and win poses
	frames := 0
	for ; frames < MATCH_FRAMES_MAX; frames += 1 {
		pads: [2]sim.Input
		for side in 0 ..< 2 {
			pads[side], err = sim.bot_pad(w, side)
			if !testing.expect_value(t, err, "") do return
		}
		if !testing.expect_value(t, sim.step(w, pads), "") do return
		if len(w.inputs.events) > 0 && w.inputs.events[len(w.inputs.events) - 1].kind == .Match_End do break
	}
	if !testing.expect(t, len(w.inputs.events) > 0, "the match did not end") do return
	end := w.inputs.events[len(w.inputs.events) - 1]
	testing.expect_value(t, end.kind, imports.Event_Kind.Match_End)
	testing.expect(t, end.a >= -1 && end.a <= 1, "the winner is a side or a draw")
	log.infof("the match ended after %d frames, winner side %d", frames, end.a)
	view, view_err := sim.view(w)
	testing.expect_value(t, view_err, "")
	T5_VIEW_VERSION :: 2  // modules/tk5/view.h, its first field
	testing.expect(t, len(view) >= 4 && (^u32le)(raw_data(view))^ == T5_VIEW_VERSION, "the view starts with its version")
}
