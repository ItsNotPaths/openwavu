package game

import "../render"
import "../sim"

// The host's side of a match: the sim at 60 Hz, pads and bots in, the view to the presenter, until the match ends.
// (hole fixed-step :tags game) no fixed 60 Hz step with the display at the user's fps and input latched into the next tick.
// (hole bot-input :tags game) a bot side's pad does not come from ow_bot_pad.
run_match :: proc(r: ^render.Renderer, w: ^sim.World) {}
