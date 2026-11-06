// openwavu-server: one binary for a whole network, roles set in network.toml (docs/network.md). files: store, pack
// files, releases, regions, submits, review CLI. lobbies: lobbies of the hosted packs and the match relay. Relay mode
// runs no pack code; authority mode runs only a mode's sim module, on confirmed frames.
package server

import "core:fmt"
import "core:os"
import "../net/relay"

// (hole server-lobby :tags server :needs (titlepack-hash param-layers) :sev blocker) no lobbies role: no lobby list per pack, match start, input relay, spectator feed or region check-in to the files host; no network.toml.
// (hole server-authority :tags server :needs server-lobby) no authority mode: the server does not run the mode's sim on confirmed inputs, compare the clients' hashes with its own, or send a client its snapshot.
main :: proc() {
	r, ok := relay_open(relay.PORT)
	if !ok {
		fmt.eprintfln("openwavu-server: can not listen on udp %d", relay.PORT)
		os.exit(1)
	}
	defer relay_close(&r)
	fmt.eprintfln("openwavu-server: relay on udp %d", relay.PORT)
	stop: bool
	relay_serve(&r, &stop)
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

// (hole match-reports :tags (server net)) clients do not report match events or state hashes, and the server does not cross-check them or set the end frame.
cross_check :: proc(a, b: []u8) -> (agree: bool) {
	return false
}
