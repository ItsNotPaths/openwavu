// Online play: a connection to a network's lobby server (ENet over UDP), lobbies that run one title pack, and the
// rollback session of a match (session.odin). Every packet goes through the lobby server, never P2P.
package net

Connection :: struct {}

connect :: proc(host: string) -> (c: ^Connection, ok: bool) {
	return nil, false
}

// (hole lobby-join :tags net :needs (pack-base net-enet server-lobby content-cache registry-verify titlepack-hash content-view loadout-blob identity-key)) joining a lobby does not sign the server's challenge, fetch its title pack from the network (its base is a stock pack the player built), apply the params the server passes down, or check the lobby hash.
join_lobby :: proc(c: ^Connection, lobby: string) -> (ok: bool) {
	return false
}

// A player's loadout: pack format, opaque to the engine. Sent at join, passed to sim init, kept in replays.
LOADOUT_MAX :: 4096

// (hole loadout-blob :tags (net sim) :needs net-enet) loadout blobs are not exchanged at join or capped.
send_loadout :: proc(c: ^Connection, blob: []byte) -> (ok: bool) {
	return false
}
