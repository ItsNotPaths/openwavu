package tests

import "core:log"
import "core:os"
import "core:testing"
import "../src/content"
import "../src/imports"
import "../src/sim"
import "../src/wasm"

STOCK_PACK :: "packs/tekken5dr"
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

// The stock pack and the compiled stock sim module, for sim.create. Needs an import and build.sh.
Stock_Sim :: struct {
	pack:   content.Pack,
	engine: wasm.Engine,
	module: wasm.Module,
}

stock_sim_open :: proc(t: ^testing.T) -> (stock: ^Stock_Sim, ok: bool) {
	if !os.exists(STOCK_PACK) do return nil, false
	code, read_err := os.read_entire_file(GAMEPLAY, context.temp_allocator)
	if !testing.expect(t, read_err == nil, "build.sh builds " + GAMEPLAY) do return nil, false
	stock = new(Stock_Sim)
	opened: bool
	if stock.pack, opened = content.open_pack(STOCK_PACK); !testing.expect(t, opened) {
		free(stock)
		return nil, false
	}
	stock.engine = wasm.engine_create()
	compile_err: string
	if stock.module, compile_err = wasm.compile(stock.engine, code); !testing.expect_value(t, compile_err, "") {
		stock_sim_close(stock)
		return nil, false
	}
	return stock, true
}

stock_sim_close :: proc(stock: ^Stock_Sim) {
	if stock.module != {} do wasm.module_destroy(stock.module)
	wasm.engine_destroy(stock.engine)
	content.close_pack(&stock.pack)
	free(stock)
}

// Paul vs Kazuya on Dragon's Nest.
stock_world :: proc(t: ^testing.T, stock: ^Stock_Sim, seed: u64 = 7) -> (w: ^sim.World, ok: bool) {
	err: string
	w, err = sim.create(stock.engine, stock.module, &stock.pack, stage_params(), {loadout_bytes("paul"), loadout_bytes("kazuya")}, seed)
	return w, testing.expect_value(t, err, "")
}

// Two bots play an offline match to its end in the stock sim module, on the stock pack.
@(test)
stock_sim_plays_a_match :: proc(t: ^testing.T) {
	stock, opened := stock_sim_open(t)
	if !opened do return
	defer stock_sim_close(stock)
	w, created := stock_world(t, stock)
	if !created do return
	defer sim.destroy(w)
	err: string

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
	T5_VIEW_VERSION :: 4  // modules/tk5/view.h, its first field
	testing.expect(t, len(view) >= 4 && (^u32le)(raw_data(view))^ == T5_VIEW_VERSION, "the view starts with its version")
}

// The lobby's rule params reach the stock sim: at 1 health every clean hit ends a round, and at 0% damage no hit
// does, so the same bots play much longer.
@(test)
stock_sim_reads_rule_params :: proc(t: ^testing.T) {
	stock, opened := stock_sim_open(t)
	if !opened do return
	defer stock_sim_close(stock)
	fragile := stage_params()
	fragile["start_health"] = "1"
	fragile_frames, fragile_ended, _ := play_to_match_end(t, stock, fragile, 40_000)
	if !testing.expect(t, fragile_ended, "the match at 1 health did not end") do return
	unhurt := stage_params()
	unhurt["start_health"] = "1"
	unhurt["damage_percent"] = "0"
	_, unhurt_ended, _ := play_to_match_end(t, stock, unhurt, 2 * fragile_frames)
	testing.expect(t, !unhurt_ended, "the match at 0% damage ended as fast as one with damage")
}

// rounds_to_win sets how many rounds the winner wins, and each fall is reported as a KO.
@(test)
stock_sim_reads_round_params :: proc(t: ^testing.T) {
	stock, opened := stock_sim_open(t)
	if !opened do return
	defer stock_sim_close(stock)
	params := stage_params()
	params["start_health"] = "1"
	params["rounds_to_win"] = "3"
	params["round_time"] = "0"
	_, ended, events := play_to_match_end(t, stock, params, 60_000)
	if !testing.expect(t, ended, "the match to 3 wins did not end") do return
	winner := events[len(events) - 1].a
	kos, rounds_won: int
	for event in events {
		if event.kind == .KO do kos += 1
		if event.kind == .Round_End && event.a == winner do rounds_won += 1
	}
	testing.expect(t, winner == -1 || rounds_won == 3, "the winner of a match to 3 wins did not win 3 rounds")
	testing.expect(t, kos > 0, "no fall was reported at 1 health")
}

// Bots play until the match ends or frames_max passes. The events are a copy in the temp allocator.
play_to_match_end :: proc(t: ^testing.T, stock: ^Stock_Sim, params: map[string]string, frames_max: int) -> (frames: int, ended: bool, events: []imports.Event) {
	w, err := sim.create(stock.engine, stock.module, &stock.pack, params, {loadout_bytes("paul"), loadout_bytes("kazuya")}, 7)
	if !testing.expect_value(t, err, "") do return
	defer sim.destroy(w)
	for ; frames < frames_max; frames += 1 {
		pads: [2]sim.Input
		for side in 0 ..< 2 {
			pads[side], err = sim.bot_pad(w, side)
			if !testing.expect_value(t, err, "") do return
		}
		if !testing.expect_value(t, sim.step(w, pads), "") do return
		for event in w.inputs.events do if event.kind == .Match_End do return frames, true, events_copy(w)
	}
	return frames, false, events_copy(w)
}

events_copy :: proc(w: ^sim.World) -> []imports.Event {
	events := make([]imports.Event, len(w.inputs.events), context.temp_allocator)
	copy(events, w.inputs.events[:])
	return events
}
