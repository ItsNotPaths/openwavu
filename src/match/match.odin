// An offline match: the mode's sim stepped at 60 Hz against display time, bots on their sides, the sim view to the
// presenter each display frame, until the sim reports the match end. Online play steps the same sim through src/net.
package match

import "../imports"
import "../presentation"
import "../sim"
import "../wasm"

TICK_NS :: 1_000_000_000 / 60
CATCH_UP_TICKS :: 4  // a slow display frame runs at most this many ticks and drops the rest of its time

Match :: struct {
	world:     ^sim.World,
	presenter: ^imports.Module,
	bot_sides: bit_set[0 ..< 2; u32],
	view:      [dynamic]byte,  // the sim view of the last tick: the presenter's ow_view
	behind:    u64,            // display time in ns not stepped yet
	ticked:    bool,           // the last frame ran a tick, so the presenter's scene is a new tick's
}

// Starts the mode's sim and presenter, compiled by the caller. The pack must outlive the match.
start :: proc(engine: wasm.Engine, sim_code, presenter_code: wasm.Module, pack: ^presentation.Pack, request: imports.Match_Request, seed: u64) -> (m: ^Match, err: string) {
	m = new(Match)
	m.bot_sides = request.bot_sides
	m.view = make([dynamic]byte)
	if err = start_modules(m, engine, sim_code, presenter_code, pack, request, seed); err != "" {
		stop(m)
		return nil, err
	}
	return m, ""
}

@(private = "file")
start_modules :: proc(m: ^Match, engine: wasm.Engine, sim_code, presenter_code: wasm.Module, pack: ^presentation.Pack, request: imports.Match_Request, seed: u64) -> (err: string) {
	if m.world, err = sim.create(engine, sim_code, pack.content, request.params, request.loadouts, seed); err != "" do return
	if err = copy_view(m); err != "" do return  // the presenter's init reads the match start's view
	if m.presenter, err = presentation.create(engine, request.mode.presenter, pack); err != "" do return
	if err = imports.define_view(m.presenter.linker, &m.view); err != "" do return
	return presentation.start(m.presenter, presenter_code)
}

stop :: proc(m: ^Match) {
	if m.presenter != nil do imports.module_destroy(m.presenter)
	if m.world != nil do sim.destroy(m.world)
	delete(m.view)
	free(m)
}

// One display frame dt_ns long: the ticks it is worth, then the presenter's frame. pads: the newest input of each
// player side, the same for every tick of this frame. ended: the sim reported the match end; winner is a side, or -1
// for a draw. A trap in either module comes back as err.
frame :: proc(m: ^Match, pack: ^presentation.Pack, dt_ns: u64, pads: [2]sim.Input) -> (ended: bool, winner: i32, err: string) {
	m.behind += dt_ns
	m.ticked = m.behind >= TICK_NS
	for ticks := 0; m.behind >= TICK_NS; ticks += 1 {
		if ticks == CATCH_UP_TICKS {
			m.behind = 0
			break
		}
		m.behind -= TICK_NS
		if err = tick(m, pads); err != "" do return
		if winner, ended = match_end(m.world); ended do return
	}
	if err = copy_view(m); err != "" do return
	err = presentation.frame(m.presenter, pack, f32(dt_ns) / 1e9)
	return
}

@(private = "file")
copy_view :: proc(m: ^Match) -> (err: string) {
	bytes: []byte
	if bytes, err = sim.view(m.world); err != "" do return
	resize(&m.view, len(bytes))
	copy(m.view[:], bytes)
	return
}

// How far the display is from the last tick to the next, 0 to 1.
tick_alpha :: proc(m: ^Match) -> f32 {
	return f32(m.behind) / TICK_NS
}

@(private = "file")
tick :: proc(m: ^Match, pads: [2]sim.Input) -> (err: string) {
	pads := pads
	for side in m.bot_sides do if pads[side], err = sim.bot_pad(m.world, side); err != "" do return
	return sim.step(m.world, pads)
}

@(private = "file")
match_end :: proc(w: ^sim.World) -> (winner: i32, ended: bool) {
	events := w.inputs.events[:]
	if len(events) == 0 || events[len(events) - 1].kind != .Match_End do return
	return events[len(events) - 1].a, true
}
