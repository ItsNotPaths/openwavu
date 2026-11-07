package game

import "core:fmt"
import "core:math/rand"
import "core:strings"
import sdl "vendor:sdl3"
import "../content"
import "../imports"
import "../input"
import "../match"
import "../online"
import "../presentation"
import "../render"
import "../titlepack"
import "../wasm"

// Runs the picked pack's entry module, one frame call per display frame, and the matches it starts, until the window
// closes (quit), the pack calls ow_exit, or a module traps, which cuts off the whole pack; the last two return to the launcher.
// identity: the player's key, for the pack's lobbies on the network's lobby server.
play :: proc(r: ^render.Renderer, tp: titlepack.Title_Pack, settings: Settings, identity: online.Identity) -> (quit: bool) {
	if base := titlepack.missing_base(tp); base != "" {
		fmt.eprintfln("openwavu: %s needs the stock pack %s; import it first", tp.name, base)
		return
	}
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
	defer render.forget_scenes(r)
	codes := Codes{engine = wasm.engine_create(), pack = &pack}
	defer codes_destroy(&codes)
	running := presentation.pack_create(&pack, r.renderer_2d, &r.gpu, volumes(settings))
	r.blend.fighters = settings.blend_fighters
	defer presentation.pack_destroy(running)
	entry_state := imports.entry_create(tp)
	defer if asked, has := &entry_state.asked.?; has do imports.match_request_destroy(asked, entry_state.allocator)
	defer {
		for intent in entry_state.intents do imports.lobby_intent_destroy(intent, entry_state.allocator)
		delete(entry_state.intents)
	}
	lobbies := Lobbies{host = relay_host(settings.network), identity = identity, name = strings.to_string(settings.name)}
	defer delete(lobbies.host)
	defer lobbies_close(&lobbies)
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
		for sdl.PollEvent(&e) {
			if e.type == .QUIT do return true
			input.handle_event(e)
		}
		pads := input.poll()
		running.pads = pads
		now := sdl.GetTicksNS()
		dt := now - last
		last = now
		lobbies_apply(&lobbies, tp, &entry_state)
		if game == nil do lobbies_pump(&lobbies)
		if asked, has := &entry_state.asked.?; has {
			game = start_match(&codes, running, asked^)
			imports.match_request_destroy(asked, entry_state.allocator)
			entry_state.asked = nil
			if game != nil do entry_state.view.match = .Running
		}
		if game == nil {
			if lobby := lobbies_new_match(&lobbies); lobby != nil {
				game = start_lobby_match(&codes, running, tp, &lobbies, lobby)
				if game != nil do entry_state.view.match = .Running
			}
		}
		lobbies_view(&lobbies, tp, &entry_state.view)
		render.begin_frame(r, {0, 0, 0, 1})
		if !render.queue_scene(r) {
			fmt.eprintfln("openwavu: the 3D did not draw: %s", sdl.GetError())
			return
		}
		if game != nil {
			ended, winner, match_err := match.frame(game, running, dt, {{pads[0]}, {pads[1]}})
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
			render.show_scene(r, &running.scene.scene, game == nil || game.ticked)
			running.scene.sent = false
		}
		alpha: f32 = game != nil && settings.frame_cap > 60 ? match.tick_alpha(game) : 1  // at 60 fps every frame is a tick: no blending
		if !render.draw_scene(r, &running.scene.assets, alpha) {
			fmt.eprintfln("openwavu: the 3D did not draw: %s", sdl.GetError())
			return
		}
		render.end_frame(r)
		pace(now, settings.frame_cap)
		if entry_state.exit do return
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

// The match of a lobby's match fact, or nil when it does not start; the lobby moves on once this player says DONE.
start_lobby_match :: proc(c: ^Codes, running: ^presentation.Pack, tp: titlepack.Title_Pack, lobbies: ^Lobbies, lobby: ^online.Lobby) -> (m: ^match.Match) {
	sim_code, presenter_code: wasm.Module
	err: string
	defer if err != "" {
		fmt.eprintfln("openwavu: the lobby match did not start: %s", err)
		online.lobby_done(lobbies.client)
	}
	mode, known := imports.find_mode(tp.modes, lobby.mode)
	if !known {
		err = "the lobby's mode is not in this pack"
		return
	}
	if sim_code, err = code_of(c, mode.sim); err != "" do return
	if presenter_code, err = code_of(c, mode.presenter); err != "" do return
	m, err = match.start_lobby_match(c.engine, sim_code, presenter_code, running, tp, lobbies.client, lobby)
	return
}
