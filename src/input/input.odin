// Pads and keyboards to the sim's raw pad bits.
package input

import "../sim"

// (hole input-pad :tags input :needs render-gpu) no SDL gamepad or keyboard read; no button config.
poll :: proc(player: int) -> sim.Input {
	return {}
}
