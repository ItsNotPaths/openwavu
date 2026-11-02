package game

import "core:fmt"
import "../content"
import "../render"
import "../sim"
import "../titlepack"

// Opens the picked pack and runs its entry module, which starts matches.
// (hole game-loop :tags game :needs (render-fighter render-stage input-pad mod-scene mod-ui mod-menus match-local bot-input stock-modules) :sev blocker) no offline match vs the CPU in the stock pack, started from its menus.
play :: proc(r: ^render.Renderer, tp: titlepack.Title_Pack) {
	pack, ok := content.open_pack("packs/tekken5dr.tar")
	if !ok {
		fmt.eprintln("openwavu: the pack did not open")
		return
	}
	defer content.close_pack(&pack)
	fmt.eprintln("openwavu: the pack's entry module is not run yet (hole app-host)")
}

// The host's side of a match: the sim at 60 Hz, pads and bots in, the view to the presenter, until the match ends.
// (hole fixed-step :tags game) no fixed 60 Hz step with the display at the user's fps and input latched into the next tick.
// (hole bot-input :tags game) a bot side's pad does not come from ow_bot_pad.
run_match :: proc(r: ^render.Renderer, w: ^sim.World) {}
