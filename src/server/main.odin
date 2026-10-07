// openwavu-server: hosts lobbies that run title packs. It has no game data and runs no sim.
package server

import "core:fmt"

// (hole server-lobby :tags server :needs (titlepack-hash mode-host) :sev blocker) no lobby list, matchmaking, file service for packs, or relay.
main :: proc() {
	fmt.eprintln("openwavu-server: not built")
}

// (hole match-reports :tags (server net) :needs event-stream) peers do not report match events, and the server does not cross-check them.
cross_check :: proc(a, b: []u8) -> (agree: bool) {
	return false
}
