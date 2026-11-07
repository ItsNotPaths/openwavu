package match

import "core:time"
import "../imports"
import "../online"
import "../presentation"
import "../titlepack"
import "../wasm"

// An online match's ticks go through a session with the other player of its lobby. The client is the game's: it
// outlives the match.
Online :: struct {
	client:   ^online.Lobby_Client,
	session:  ^online.Session,
	clock_ns: u64,
}

// The match of the lobby this player is in, from its match fact: the mode, the host's picks over the pack's params,
// both players' loadouts and the seed. Player 1's pad plays this player's side.
start_lobby_match :: proc(engine: wasm.Engine, sim_code, presenter_code: wasm.Module, pack: ^presentation.Pack, tp: titlepack.Title_Pack, client: ^online.Lobby_Client, lobby: ^online.Lobby) -> (m: ^Match, err: string) {
	opening, started := online.match_start(client, lobby)
	if !started do return nil, "the match fact does not read"
	mode, known := imports.find_mode(tp.modes, lobby.mode)
	if !known do return nil, "the lobby's mode is not in this pack"
	picks, read := titlepack.parse_params(lobby.params, context.temp_allocator)
	if !read do return nil, "the lobby's params do not read"
	request := imports.Match_Request{mode = mode, loadouts = opening.loadouts}
	if request.params, err = titlepack.resolve_params(tp.params, picks, context.temp_allocator); err != "" do return
	if m, err = start(engine, sim_code, presenter_code, pack, request, opening.seed); err != "" do return
	m.online = {client, online.session_create(m.world, online.lobby_transport(client), opening.side, opening.token, 0), 0}
	if opening.start_in > 0 do time.sleep(opening.start_in)
	return m, ""
}

online_stop :: proc(match_online: ^Online) {
	if match_online.session == nil do return
	if match_online.session.outcome == .Playing do online.session_linger(match_online.session, match_online.clock_ns)
	online.lobby_done(match_online.client)
	online.session_destroy(match_online.session)
}
