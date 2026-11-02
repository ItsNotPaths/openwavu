// openwavu-server: a daemon and CLI that hosts lobbies of title packs. Relay mode runs no pack code; authority mode
// runs only a mode's sim module and the files it reads.
package server

import "core:fmt"

// (hole server-lobby :tags server :needs (titlepack-hash param-layers) :sev blocker) no lobby list, matchmaking, relay or master server registration; no server.toml (pack hash, server params).
main :: proc() {
	fmt.eprintln("openwavu-server: not built")
}

Rotation :: enum {
	Winner_Stays,
	Round_Robin,
	Queue,
}

// (hole lobby-rotation :tags server :needs (server-lobby match-reports)) the lobby does not pick the next players from the match result and its rotation param.
next_players :: proc(rotation: Rotation, players: []string, winner: int) -> (next: [2]string) {
	return {}
}

// (hole match-reports :tags (server net)) peers do not report match events, and the server does not cross-check them.
cross_check :: proc(a, b: []u8) -> (agree: bool) {
	return false
}
