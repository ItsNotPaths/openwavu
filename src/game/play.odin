package game

import "core:fmt"
import "core:math/rand"
import sdl "vendor:sdl3"
import "../content"
import "../imports"
import "../match"
import "../presentation"
import "../render"
import "../titlepack"
import "../wasm"

// Runs the picked pack's entry module, one frame call per display frame, and the matches it starts, until the window
// closes (quit) or a module traps, which cuts off the whole pack and returns to the launcher.
// (hole game-loop :tags game :needs (render-fighter render-stage input-pad mod-scene mod-ui mod-menus stock-modules) :sev blocker) no offline match vs the CPU in the stock pack, started from its menus.
// (hole pack-leave :tags game :needs app-shell) the player can not leave a running pack for the launcher; only closing the window ends it.
play :: proc(r: ^render.Renderer, tp: titlepack.Title_Pack, frame_cap: int) -> (quit: bool) {
	if tp.main == "" {
		fmt.eprintfln("openwavu: %s has no entry module", tp.name)
		return
	}
	pack, opened := content.open_pack(tp.path)
	if !opened {
		fmt.eprintfln("openwavu: %s did not open", tp.path)
		return
	}
	defer content.close_pack(&pack)
	codes := Codes{engine = wasm.engine_create(), pack = &pack}
	defer codes_destroy(&codes)
	running := presentation.pack_create(&pack, r.r2d)
	defer presentation.pack_destroy(running)
	entry_state := imports.entry_create(tp.modes)
	defer if asked, has := &entry_state.asked.?; has do imports.match_request_destroy(asked, entry_state.allocator)
	entry, err := start_entry(&codes, tp.main, running, &entry_state)
	if err != "" {
		fmt.eprintfln("openwavu: %s did not start: %s", tp.main, err)
		return
	}
	defer imports.module_destroy(entry)
	game: ^match.Match
	defer if game != nil do match.stop(game)

	last := sdl.GetTicksNS()
	for {
		defer free_all(context.temp_allocator)
		e: sdl.Event
		for sdl.PollEvent(&e) do if e.type == .QUIT do return true
		now := sdl.GetTicksNS()
		dt := now - last
		last = now
		if asked, has := &entry_state.asked.?; has {
			game = start_match(&codes, running, asked^)
			imports.match_request_destroy(asked, entry_state.allocator)
			entry_state.asked = nil
			if game != nil do entry_state.view.match = .Running
		}
		render.begin_frame(r, {0, 0, 0, 1})
		if !render.queue_scene(r) {
			fmt.eprintfln("openwavu: the 3D did not draw: %s", sdl.GetError())
			return
		}
		if game != nil {
			// (hole match-pads :tags game :needs input-pad) player sides get no pad: their input is always 0.
			ended, winner, match_err := match.frame(game, running, dt, {})
			if match_err != "" {
				fmt.eprintfln("openwavu: the match stopped, so the pack is cut off: %s", match_err)
				return
			}
			if ended {
				match.stop(game)
				game = nil
				entry_state.view.match, entry_state.view.winner = .Ended, winner
			}
		}
		if err = presentation.frame(entry, running, f32(dt) / 1e9); err != "" {
			fmt.eprintfln("openwavu: %s stopped, so the pack is cut off: %s", tp.main, err)
			return
		}
		if running.scene.sent {
			render.show_scene(r, &running.scene.scene)
			running.scene.sent = false
		}
		if !render.draw_scene(r, 1) {
			fmt.eprintfln("openwavu: the 3D did not draw: %s", sdl.GetError())
			return
		}
		render.end_frame(r)
		pace(now, frame_cap)
	}
}

// The pack's modules, each compiled once per visit.
Codes :: struct {
	engine:  wasm.Engine,
	pack:    ^content.Pack,
	by_path: map[string]wasm.Module,  // keys live as long as the visit's Title_Pack
}

codes_destroy :: proc(c: ^Codes) {
	for _, code in c.by_path do wasm.module_destroy(code)
	delete(c.by_path)
	wasm.engine_destroy(c.engine)
}

code_of :: proc(c: ^Codes, path: string) -> (code: wasm.Module, err: string) {
	if known, has := c.by_path[path]; has do return known, ""
	bytes, found := content.pack_file(c.pack^, path)
	if !found do return {}, fmt.tprintf("the pack has no %s", path)
	if code, err = wasm.compile(c.engine, bytes); err != "" do return
	c.by_path[path] = code
	return code, ""
}

start_entry :: proc(c: ^Codes, path: string, running: ^presentation.Pack, state: ^imports.Entry) -> (m: ^imports.Module, err: string) {
	code: wasm.Module
	if code, err = code_of(c, path); err != "" do return
	if m, err = presentation.create(c.engine, path, running); err != "" do return
	if err = imports.define_entry(m.linker, state); err == "" do err = presentation.start(m, code)
	if err != "" {
		imports.module_destroy(m)
		return nil, err
	}
	return m, ""
}

// The asked match, or nil when its modules do not start; the entry module keeps running either way.
start_match :: proc(c: ^Codes, running: ^presentation.Pack, asked: imports.Match_Request) -> (m: ^match.Match) {
	sim_code, presenter_code: wasm.Module
	err: string
	defer if err != "" do fmt.eprintfln("openwavu: the %s match did not start: %s", asked.mode.name, err)
	if sim_code, err = code_of(c, asked.mode.sim); err != "" do return
	if presenter_code, err = code_of(c, asked.mode.presenter); err != "" do return
	m, err = match.start(c.engine, sim_code, presenter_code, running, asked, rand.uint64())
	return
}
