// openwavu-server: one binary for a whole network, roles set in network.toml (docs/network.md). files: store, pack
// files, releases, regions, submits, review CLI. lobbies: lobbies of the hosted packs and the match relay. Relay mode
// runs no pack code; authority mode runs only a mode's sim module, on confirmed frames.
package server

import "core:fmt"
import "core:os"
import "core:thread"
import "../online"
import "../online/lobbies"

// (hole lobby-regions :tags server) no region check-in to the files host, no spectator feed and no network.toml: one lobbies role on the files box.
// (hole orphan-refuse :tags (server saves)) the server does not refuse a pack version that is not the latest approved one (an orphaned tile) at lobby join.
// (hole server-authority :tags server) no authority mode: the server does not run the mode's sim on confirmed inputs, compare the clients' hashes with its own, or send a client its snapshot.
// (hole hosting-guide :tags server :sev polish) no hosting guide: DNS (serve.<domain> for files, region names for lobbies, grey records), TLS proxy, install-server.sh, firewall ports, network.toml.
// openwavu-server [--prep] [packs folder]: --prep incorporates the dropped tars and exits.
main :: proc() {
	args := os.args[1:]
	prep := len(args) > 0 && args[0] == "--prep"
	if prep do args = args[1:]
	dir := len(args) > 0 ? args[0] : PACKS_DIR
	incorporate_all(dir)
	if prep do return
	thread.create_and_start_with_poly_data(dir, proc(dir: string) {serve_files(dir)})
	lobby_server, ok := lobbies.open(online.PORT)
	if !ok {
		fmt.eprintfln("openwavu-server: can not listen on udp %d", online.PORT)
		os.exit(1)
	}
	defer lobbies.close(&lobby_server)
	fmt.eprintfln("openwavu-server: lobbies on udp %d", online.PORT)
	stop: bool
	lobbies.serve(&lobby_server, &stop)
}

Rotation :: enum {
	Winner_Stays,
	Round_Robin,
	Queue,
}

// (hole lobby-rotation :tags server :needs match-reports) the lobby does not pick the next players from the match result and its rotation param.
next_players :: proc(rotation: Rotation, players: []string, winner: int) -> (next: [2]string) {
	return {}
}

// (hole match-reports :tags (server net)) clients do not report match events or state hashes, and the server does not cross-check them or set the end frame.
cross_check :: proc(a, b: []u8) -> (agree: bool) {
	return false
}
