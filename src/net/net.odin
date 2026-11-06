// Online play: a session with a region's lobby server (ENet over UDP), and lobbies that run one title pack.
package net

import "../sim"

Session :: struct {}

// Rollback between the two players; every packet goes through the lobby server, never P2P.
session_create :: proc(host: string) -> (s: ^Session, ok: bool) {
	return nil, false
}

// (hole net-session :tags net :needs module-snapshot :sev blocker) no rollback session (our own loop, not GGPO, Odin's vendor:ENet): input exchange with resends, prediction, resimulation, time sync, state hashes, packet token.
session_step :: proc(s: ^Session, w: ^sim.World, local: sim.Input) {}

// (hole lobby-join :tags net :needs (pack-base net-session server-lobby content-cache registry-verify titlepack-hash content-view loadout-blob identity-key)) joining a lobby does not sign the server's challenge, fetch its title pack from the network (its base is a stock pack the player built), apply the params the server passes down, or check the lobby hash.
join_lobby :: proc(s: ^Session, lobby: string) -> (ok: bool) {
	return false
}

// A player's loadout: pack format, opaque to the engine. Sent at join, passed to sim init, kept in replays.
LOADOUT_MAX :: 4096

// (hole loadout-blob :tags (net sim) :needs net-session) loadout blobs are not exchanged at join or capped.
send_loadout :: proc(s: ^Session, blob: []byte) -> (ok: bool) {
	return false
}
