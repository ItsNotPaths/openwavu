// Pads and keyboards to the sim's raw pad bits.
package input

import "../sim"

// (hole input-pad :tags input :needs render-gpu) no SDL gamepad or keyboard read; no button config.
// (hole stick-config :tags input :needs input-pad :sev polish) no analog deadzone or stick settings; one modern scheme for every title.
poll :: proc(player: int) -> sim.Input {
	return {}
}
