package tests

import "core:hash/xxhash"
import "core:log"
import "core:testing"
import "../src/imports"
import "../src/sim"
import "../src/wasm"

ROLLBACK :: 8  // the rollback cutoff (ws.md Workstream Q)

// The heap after the state, hashed: load data, it must not change after init. (The stack before the state holds
// nothing between ticks.)
heap_hash :: proc(w: ^sim.World) -> u64 {
	return xxhash.XXH3_64(wasm.bytes(w.module.store, w.memory)[w.state_at + w.state_size:])
}

// A match that goes back ROLLBACK frames every ROLLBACK frames, so each frame runs again once from a restored
// snapshot, has the state of the same match played straight, frame by frame, to the match end. The bots play once
// per real tick, in the straight match.
@(test)
rollback_keeps_the_match_state :: proc(t: ^testing.T) {
	stock, opened := stock_sim_open(t)
	if !opened do return
	defer stock_sim_close(stock)
	straight, straight_created := stock_world(t, stock)
	if !straight_created do return
	defer sim.destroy(straight)
	rolled, rolled_created := stock_world(t, stock)
	if !rolled_created do return
	defer sim.destroy(rolled)

	snapshots: [ROLLBACK][]byte  // the state before each of the last ROLLBACK frames, by frame % ROLLBACK
	for &snapshot in snapshots do snapshot = make([]byte, sim.snapshot_size(rolled), context.temp_allocator)
	pads: [ROLLBACK][2]sim.Input
	heap := heap_hash(rolled)
	err: string

	MATCH_FRAMES_MAX :: 40_000
	frame := 0
	for ; frame < MATCH_FRAMES_MAX; frame += 1 {
		slot := frame % ROLLBACK
		for side in 0 ..< 2 {
			pads[slot][side], err = sim.bot_pad(straight, side)
			if !testing.expect_value(t, err, "") do return
		}
		if !testing.expect_value(t, sim.step(straight, pads[slot]), "") do return
		sim.save(rolled, snapshots[slot])
		if !testing.expect_value(t, sim.step(rolled, pads[slot]), "") do return

		if frame % ROLLBACK == ROLLBACK - 1 {
			first := frame - (ROLLBACK - 1)
			sim.restore(rolled, snapshots[first % ROLLBACK])
			for again in first ..= frame {
				sim.save(rolled, snapshots[again % ROLLBACK])
				if !testing.expectf(t, sim.step(rolled, pads[again % ROLLBACK]) == "", "frame %d: resimulation trapped", again) do return
			}
		}
		if !testing.expectf(t, sim.state_hash(rolled) == sim.state_hash(straight), "frame %d: the rolled back state differs", frame) do return
		events := straight.inputs.events
		if len(events) > 0 && events[len(events) - 1].kind == imports.Event_Kind.Match_End do break
	}
	testing.expect(t, frame < MATCH_FRAMES_MAX, "the match did not end")
	testing.expect(t, heap_hash(rolled) == heap, "the heap changed after init")
	log.infof("%d frames, rolled back %d frames at a time, state %d bytes", frame + 1, ROLLBACK, sim.snapshot_size(rolled))
}
