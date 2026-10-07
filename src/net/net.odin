// Online play: sessions between peers or through a server, and lobbies that carry overlays.
package net

import "../sim"

Session :: struct {}

// P2P rollback between the players, through a server relay when they can not connect directly.
session_create :: proc(host: string) -> (s: ^Session, ok: bool) {
	return nil, false
}

// (hole net-session :tags net :needs module-snapshot :sev blocker) no rollback session (vendor:ggpo is a candidate): input exchange, prediction, resimulation, state checksums.
session_step :: proc(s: ^Session, w: ^sim.World, local: sim.Input) {}

// (hole lobby-join :tags net :needs (net-session server-lobby content-cache titlepack-hash overlay-apply)) joining a lobby does not fetch its title pack, apply its overlays and rules, or check the lobby hash.
join_lobby :: proc(s: ^Session, lobby: string) -> (ok: bool) {
	return false
}
