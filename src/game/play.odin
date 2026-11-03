package game

import "core:fmt"
import sdl "vendor:sdl3"
import "../content"
import "../imports"
import "../presentation"
import "../render"
import "../titlepack"
import "../wasm"

// Runs the picked pack's entry module, one frame call per display frame, until the window closes (quit) or a module
// traps, which cuts off the whole pack and returns to the launcher.
// (hole game-loop :tags game :needs (render-fighter render-stage input-pad mod-scene mod-ui mod-menus match-local bot-input stock-modules) :sev blocker) no offline match vs the CPU in the stock pack, started from its menus.
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
	bytes, found := content.pack_file(pack, tp.main)
	if !found {
		fmt.eprintfln("openwavu: %s has no %s", tp.name, tp.main)
		return
	}
	engine := wasm.engine_create()
	defer wasm.engine_destroy(engine)
	code, compile_err := wasm.compile(engine, bytes)
	if compile_err != "" {
		fmt.eprintfln("openwavu: %s: %s", tp.main, compile_err)
		return
	}
	defer wasm.module_destroy(code)
	sdl_set := imports.sdl_set_create(r.r2d)
	defer imports.sdl_set_destroy(&sdl_set)
	entry, err := presentation.start(engine, code, tp.main, &pack, &sdl_set)
	if err != "" {
		fmt.eprintfln("openwavu: %s did not start: %s", tp.main, err)
		return
	}
	defer imports.module_destroy(entry)

	last := sdl.GetTicksNS()
	for {
		defer free_all(context.temp_allocator)
		e: sdl.Event
		for sdl.PollEvent(&e) do if e.type == .QUIT do return true
		now := sdl.GetTicksNS()
		dt := f32(now - last) / 1e9
		last = now
		render.begin_frame(r, {0, 0, 0, 1})
		if err = presentation.frame(entry, &sdl_set, dt); err != "" {
			fmt.eprintfln("openwavu: %s stopped, so the pack is cut off: %s", tp.main, err)
			return
		}
		render.end_frame(r)
		pace(now, frame_cap)
	}
}
