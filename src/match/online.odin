package match

import "core:time"
import "../imports"
import "../online"
import "../online/relay"
import "../presentation"
import "../wasm"

PAIR_TIMEOUT_MS :: 30_000

// An online match's ticks go through a session with whoever the relay pairs this player with.
Online :: struct {
	client:    ^online.Relay_Client,
	session:   ^online.Session,
	clock_ns:  u64,
	local_pad: int,  // the controller of the side picked in the menu
}

// Pairs with whoever waits on the relay at host (openwavu-bot), sends it the asked match, and starts the same match on
// both machines. The relay picks the local side; the loadout picked in the menu goes with it.
// (hole server-lobby) stands in for the lobby's match start until then.
start_online :: proc(engine: wasm.Engine, sim_code, presenter_code: wasm.Module, pack: ^presentation.Pack, request: imports.Match_Request, host: string) -> (m: ^Match, err: string) {
	client, connected := online.relay_connect(host, relay.PORT)
	if !connected do return nil, "the relay did not answer"
	defer if err != "" do online.relay_disconnect(client)
	paired, start_in_ns, started := online.relay_wait_start(client, PAIR_TIMEOUT_MS)
	if !started do return nil, "no player to pair with"
	waited := time.tick_now()
	request := request
	picked := 0 in request.bot_sides ? 1 : 0
	if paired.side != picked do request.loadouts = {request.loadouts[1], request.loadouts[0]}
	params := imports.params_text(request.params, context.temp_allocator)
	online.relay_send_control(client, relay.setup_encode({request.mode.sim, params, request.loadouts}, context.temp_allocator))
	request.bot_sides = {}
	if m, err = start(engine, sim_code, presenter_code, pack, request, paired.seed); err != "" do return
	m.online = {client, online.session_create(m.world, online.relay_transport(client), paired.side, paired.token, 0), 0, picked}
	if left := time.Duration(start_in_ns) - time.tick_since(waited); left > 0 do time.sleep(left)
	return m, ""
}

online_stop :: proc(match_online: ^Online) {
	if match_online.session == nil do return
	if match_online.session.outcome == .Playing do online.session_linger(match_online.session, match_online.clock_ns)
	online.session_destroy(match_online.session)
	online.relay_disconnect(match_online.client)
}
