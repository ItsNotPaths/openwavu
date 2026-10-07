// openwavu: the game.
package game

import "core:fmt"
import "core:os"
import "../content"
import "../input"
import "../render"
import "../sim"

// (hole client-menus :tags game :needs (render-gpu pack-open render-api)) no client menus: lobby browser, character select (characters and costumes from the pack database), settings.
// (hole game-loop :tags game :needs (pack-open fighter-data-load seam-wiring mode-host render-fighter render-stage input-pad mod-frame) :sev blocker) no playable local match.
main :: proc() {
	pack, ok := content.open_pack("content/tk5")
	if !ok {
		fmt.eprintln("openwavu: no content pack; run openwavu-import first")
		os.exit(1)
	}
	defer content.close_pack(&pack)
	r, _ := render.init(1280, 720)
	w := sim.create({}, nil)
	for {
		sim.step(w, {input.poll(0), input.poll(1)})
		render.draw_fighter(r, nil, nil)
	}
}
