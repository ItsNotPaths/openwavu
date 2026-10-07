// Runs a pack's mode module: match flow between rounds. On the server online, on the client offline.
package mode

import "../wasm"

Round_Setup :: struct {
	stage:      string,
	characters: [2]string,
	costumes:   [2]string,
	seed:       u32,
	rules:      map[string]string,  // the rules block for this round
}

// (hole mode-host :tags (server sim) :needs (mod-mode event-stream) :sev blocker) no host for mode modules: settings in, events in, round setups out.
next_round :: proc(m: ^wasm.Instance, events: []u8) -> (setup: Round_Setup, match_over: bool) {
	return {}, true
}
