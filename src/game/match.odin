package game

import "core:fmt"
import sdl "vendor:sdl3"
import "../content"
import "../input"
import "../render"
import "../sim"
import "../titlepack"

// Runs a match until Escape or window close, then returns to the launcher.
// (hole game-loop :tags game :needs (pack-open fighter-data-load sim-step render-fighter render-stage input-pad mod-scene mod-ui mod-menus match-local bot-input stock-modules) :sev blocker) no offline match vs the CPU in the stock pack, started from its menus.
play :: proc(r: ^render.Renderer, tp: titlepack.Title_Pack) {
	pack, ok := content.open_pack("packs/tekken5dr.tar")
	if !ok {
		fmt.eprintln("openwavu: playing a pack is not built yet (hole pack-open)")
		return
	}
	defer content.close_pack(&pack)
	w := sim.create(nil, nil, {})
	for {
		e: sdl.Event
		for sdl.PollEvent(&e) {
			if e.type == .QUIT || (e.type == .KEY_DOWN && e.key.key == sdl.K_ESCAPE) {
				return
			}
		}
		// (hole fixed-step :tags game :needs sim-step) the sim steps once per displayed frame; no fixed 60 Hz step with the display at the user's fps and input latched into the next tick.
		// (hole bot-input :tags game :needs (cpu-bot sim-step)) a bot side's pad does not come from ow_bot_pad.
		sim.step(w, {input.poll(0), input.poll(1)})
		render.begin_frame(r, {0, 0, 0, 1})
		render.draw_scene(r, 1)
		render.end_frame(r)
	}
}
