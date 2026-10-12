// openwavu: the game.
package game

import "core:fmt"
import "core:os"
import "../content"
import "../input"
import "../render"
import "../sim"

// (hole app-shell :tags game :needs (render-gpu content-cache registry-verify)) no launcher (installed packs, ROM import), join path for lobby links, or system overlay (controls, video, audio, leave pack).
// (hole app-host :tags (game wasm) :needs (module-memory render-api)) the pack's app module is not run: no instance, no frame export call, no events from host requests.
// (hole game-loop :tags game :needs (pack-open fighter-data-load sim-step render-fighter render-stage input-pad port-round port-movement port-motion) :sev blocker) no playable local match.
main :: proc() {
	pack, ok := content.open_pack("content/tk5")
	if !ok {
		fmt.eprintln("openwavu: no content pack; run openwavu-import first")
		os.exit(1)
	}
	defer content.close_pack(&pack)
	r, _ := render.init(1280, 720)
	w := sim.create(nil, nil, {})
	for {
		sim.step(w, {input.poll(0), input.poll(1)})
		render.draw_fighter(r, nil, nil)
	}
}
