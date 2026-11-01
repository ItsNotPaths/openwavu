// openwavu: the game.
package game

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"
import "../render"
import "../titlepack"
import "../ui"

VERSION :: "openwavu 0.0.0-dev"

// (hole app-shell :tags game :needs (render-gpu content-cache registry-verify)) no ROM import, join path for lobby links, or system overlay (controls, video, audio, leave pack).
// (hole app-host :tags (game wasm) :needs (module-memory render-api)) the pack's app module is not run: no instance, no frame export call, no events from host requests.
main :: proc() {
	r, ok := render.init("openwavu", 1280, 720)
	if !ok {
		fmt.eprintln("openwavu:", sdl.GetError())
		os.exit(1)
	}
	defer render.destroy(&r)
	u: ui.Ui
	ui.init(&u, r.r2d, render.size(&r))
	defer ui.destroy(&u)
	l := Launcher{packs = titlepack.installed()}
	defer launcher_destroy(&l)

	last := sdl.GetTicksNS()
	for !l.quit {
		defer free_all(context.temp_allocator)
		e: sdl.Event
		for sdl.PollEvent(&e) {
			sdl.ConvertEventToRenderCoordinates(r.r2d, &e)
			#partial switch e.type {
			case .QUIT:
				l.quit = true
			case .GAMEPAD_ADDED:
				sdl.OpenGamepad(e.gdevice.which)
			}
			ui.handle_event(&u, e)
		}
		now := sdl.GetTicksNS()
		dt := f32(now - last) / 1e9
		last = now

		ui.begin(&u, render.size(&r), dt)
		launcher(&l, &u, &r)
		commands := ui.end(&u)
		render.begin_frame(&r, ui.color(ui.BACKGROUND))
		ui.draw(&u, commands)
		render.end_frame(&r)

		if pack, picked := l.play.?; picked {
			l.play = nil
			play(&r, l.packs[pack])
		}
	}
}
