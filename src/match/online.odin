package match

import "core:encoding/hex"
import "core:fmt"
import "core:time"
import "../imports"
import "../online"
import "../presentation"
import "../titlepack"
import "../wasm"

JOIN_TIMEOUT :: 30 * time.Second

// An online match's ticks go through a session with the other player of its lobby.
Online :: struct {
	client:    ^online.Lobby_Client,
	session:   ^online.Session,
	clock_ns:  u64,
	local_pad: int,  // the controller of the side picked in the menu
}

Online_Player :: struct {
	host:     string,  // the lobby server
	identity: online.Identity,
	name:     string,
}

// Hosts a lobby of the asked match on the lobby server, readies with the loadout picked in the menu, and starts once
// someone joins and readies (openwavu-bot). The lobby picks the local side.
// (hole lobby-intents) stands in for the pack's own lobby menus until then.
start_online :: proc(engine: wasm.Engine, sim_code, presenter_code: wasm.Module, pack: ^presentation.Pack, tp: titlepack.Title_Pack, request: imports.Match_Request, player: Online_Player) -> (m: ^Match, err: string) {
	hash: titlepack.Hash
	if hash, err = titlepack.lobby_hash(tp, request.params); err != "" do return
	client: ^online.Lobby_Client
	if client, err = online.lobby_connect(player.host, player.identity, player.name); err != "" do return
	defer if err != "" do online.lobby_disconnect(client)
	picked := 0 in request.bot_sides ? 1 : 0
	online.lobby_create(client, fmt.tprintf("%s@%s", tp.id, tp.version), request.mode.name, imports.params_text(request.params, context.temp_allocator), string(hex.encode(hash[:], context.temp_allocator)))
	online.lobby_ready(client, request.loadouts[picked])
	opening: online.Match_Start
	waited := time.tick_now()
	for started := false; !started; {
		if !online.lobby_pump(client, 100) do return nil, "the lobby server hung up"
		if time.tick_since(waited) > JOIN_TIMEOUT do return nil, "nobody joined"
		if lobby := online.lobby_joined(client); lobby != nil do opening, started = online.match_start(client, lobby)
	}
	request := request
	request.loadouts = opening.loadouts
	request.bot_sides = {}
	if m, err = start(engine, sim_code, presenter_code, pack, request, opening.seed); err != "" do return
	m.online = {client, online.session_create(m.world, online.lobby_transport(client), opening.side, opening.token, 0), 0, picked}
	if opening.start_in > 0 do time.sleep(opening.start_in)
	return m, ""
}

online_stop :: proc(match_online: ^Online) {
	if match_online.session == nil do return
	if match_online.session.outcome == .Playing do online.session_linger(match_online.session, match_online.clock_ns)
	online.lobby_done(match_online.client)
	online.session_destroy(match_online.session)
	online.lobby_disconnect(match_online.client)
}
