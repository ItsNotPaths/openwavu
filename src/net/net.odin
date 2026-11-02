// Online play: sessions between peers or through a server, and lobbies that run one title pack.
package net

import "../sim"

Session :: struct {}

// P2P rollback between the players, through a server relay when they can not connect directly.
session_create :: proc(host: string) -> (s: ^Session, ok: bool) {
	return nil, false
}

// (hole net-session :tags net :needs module-snapshot :sev blocker) no rollback session (our own loop, not GGPO): input exchange, prediction, resimulation, state checksums.
session_step :: proc(s: ^Session, w: ^sim.World, local: sim.Input) {}

// (hole lobby-join :tags net :needs (pack-base net-session server-lobby content-cache registry-verify titlepack-hash content-view loadout-blob)) joining a lobby does not fetch its title pack and its bases from the registry, apply the params the server passes down, or check the lobby hash.
join_lobby :: proc(s: ^Session, lobby: string) -> (ok: bool) {
	return false
}

// A player's loadout: pack format, opaque to the engine. Sent at join, passed to sim init, kept in replays.
LOADOUT_MAX :: 4096

// (hole loadout-blob :tags (net sim) :needs net-session) loadout blobs are not exchanged at join or capped.
send_loadout :: proc(s: ^Session, blob: []byte) -> (ok: bool) {
	return false
}
