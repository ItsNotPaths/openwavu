package tests

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../src/online"
import "../src/online/lobbies"
import "../src/sim"

LOBBY_TEST_PORT :: 9289

// One player hosts a lobby and another joins it: they take the two seats, and a third gets in line and watches. Once
// both seats are ready they get one match (same seed and token, a side each), their sessions stay in step through the
// server, and the watcher, stepping only on both sides' pads, reaches the same state. After both say DONE the lobby is
// open for a rematch: no match, nobody ready. Only the host changes the params, and that unreadies both seats. A seated
// player who goes back to watching gives the seat to the first in line.
@(test)
lobby_match_and_rematch :: proc(t: ^testing.T) {
	stock, opened := stock_sim_open(t)
	if !opened do return
	defer stock_sim_close(stock)
	server, listening := lobbies.open(LOBBY_TEST_PORT)
	if !testing.expect(t, listening, "the lobby server can not listen") do return
	stop: bool
	serving := thread.create_and_start_with_poly_data2(&server, &stop, lobbies.serve)
	defer {
		sync.atomic_store(&stop, true)
		thread.join(serving)
		thread.destroy(serving)
		lobbies.close(&server)
	}
	clients: [3]^online.Lobby_Client
	defer for client in clients do if client != nil do online.lobby_disconnect(client)
	for &client in clients {
		err: string
		client, err = online.lobby_connect("127.0.0.1", online.new_identity(), "player", LOBBY_TEST_PORT)
		if !testing.expect_value(t, err, "") do return
	}
	host, joiner, late := clients[0], clients[1], clients[2]

	online.lobby_create(host, "tekken5dr@1", "versus", "stage=dragons_nest", "00")
	if !testing.expect(t, pump_until(clients[:], lobby_shown), "the lobby did not show") do return
	id := joiner.lobbies[0].id
	online.lobby_join(joiner, id)
	if !testing.expect(t, pump_until(clients[:], lobby_filled), "the joiner did not show") do return
	online.lobby_join(late, id)
	if !testing.expect(t, pump_until(clients[:], late_in_line), "the late player is not in line") do return

	for client in clients[:2] do online.lobby_ready(client, loadout_bytes(client == host ? "paul" : "kazuya"))
	if !testing.expect(t, pump_until(clients[:], match_started), "the match did not start") do return

	machines := new(Two_Machines)
	defer two_machines_destroy(machines)
	machines.pause = time.Millisecond
	openings: [2]online.Match_Start
	for client in clients[:2] {
		opening, started := online.match_start(client, online.lobby_joined(client))
		if !testing.expect(t, started) do return
		openings[opening.side] = opening
		created: bool
		if machines.worlds[opening.side], created = stock_world(t, stock, opening.seed); !created do return
		machines.sessions[opening.side] = online.session_create(machines.worlds[opening.side], online.lobby_transport(client), opening.side, opening.token, 0)
	}
	testing.expect_value(t, openings[0].seed, openings[1].seed)
	testing.expect_value(t, openings[0].token, openings[1].token)
	testing.expect_value(t, string(cstring(raw_data(openings[0].loadouts[0]))), "paul")
	watched, watching := online.match_start(late, online.lobby_joined(late))
	if !testing.expect(t, watching) || !testing.expect_value(t, watched.side, -1) do return
	watcher_world, watcher_created := stock_world(t, stock, watched.seed)
	if !watcher_created do return
	defer sim.destroy(watcher_world)
	FRAMES :: 600
	watcher := Watcher{watch = online.watch_create(watcher_world, late, watched.token, 0), frames = FRAMES}
	defer online.watch_destroy(watcher.watch)
	watching_thread := thread.create_and_start_with_poly_data(&watcher, watch_until)  // alongside the players, as in a game

	played := two_machines_play(t, machines, FRAMES)
	thread.join(watching_thread)
	thread.destroy(watching_thread)
	if !testing.expect(t, played, "the sessions did not both finish") do return
	testing.expect(t, sim.state_hash(machines.worlds[0]) == sim.state_hash(machines.worlds[1]), "the two machines' states differ")
	testing.expect_value(t, watcher.err, "")
	testing.expect_value(t, watcher.watch.outcome, online.Outcome.Playing)
	testing.expect(t, sim.state_hash(watcher_world) == sim.state_hash(machines.worlds[0]), "the watcher's state differs")

	for client in clients[:2] do online.lobby_done(client)
	testing.expect(t, pump_until(clients[:], rematch_open), "the lobby did not open for a rematch")

	online.lobby_params(joiner, "stage=acid_rain", "01")
	if !testing.expect(t, pump_until(clients[:], joiner_refused), "a guest changed the params") do return
	online.lobby_ready(host, loadout_bytes("paul"))  // one seat only: both ready would start a match
	if !testing.expect(t, pump_until(clients[:], host_ready), "the host's ready did not show") do return
	online.lobby_params(host, "stage=acid_rain", "01")
	testing.expect(t, pump_until(clients[:], params_changed), "the new params did not unready both seats")

	online.lobby_queue(host, false)
	testing.expect(t, pump_until(clients[:], seat_passed_on), "the seat did not go to the first in line")
}

Watcher :: struct {
	watch:  ^online.Watch,
	frames: int,
	err:    string,
}

// Ticks the watch on the real clock until it has stepped frames, or ends.
watch_until :: proc(watcher: ^Watcher) {
	for watched_from := time.tick_now(); watcher.watch.frame < watcher.frames && watcher.watch.outcome == .Playing; {
		time.sleep(time.Millisecond)
		if watcher.err = online.watch_tick(watcher.watch, u64(time.tick_since(watched_from))); watcher.err != "" do return
	}
}

// Pumps every client until done holds, or 5 s pass.
pump_until :: proc(clients: []^online.Lobby_Client, done: proc(clients: []^online.Lobby_Client) -> bool) -> bool {
	for waited := time.tick_now(); time.tick_since(waited) < 5 * time.Second; {
		for client in clients do online.lobby_pump(client, 10)
		if done(clients) do return true
	}
	return false
}

// The conditions of lobby_match_and_rematch: clients are the host, the joiner and the late player.
lobby_shown :: proc(clients: []^online.Lobby_Client) -> bool {return len(clients[1].lobbies) == 1}
lobby_filled :: proc(clients: []^online.Lobby_Client) -> bool {return len(clients[2].lobbies) == 1 && len(clients[2].lobbies[0].players) == 2}
joiner_refused :: proc(clients: []^online.Lobby_Client) -> bool {return clients[1].refused != ""}

late_in_line :: proc(clients: []^online.Lobby_Client) -> bool {
	lobby := online.lobby_joined(clients[2])
	if lobby == nil do return false
	late := online.lobby_player(lobby, clients[2].key)
	return late.side == -1 && late.queued > 0 && online.lobby_player(lobby, clients[1].key).side == 1
}

host_ready :: proc(clients: []^online.Lobby_Client) -> bool {
	return online.lobby_player(online.lobby_joined(clients[1]), clients[0].key).ready
}

params_changed :: proc(clients: []^online.Lobby_Client) -> bool {
	lobby := online.lobby_joined(clients[1])
	if lobby.params != "stage=acid_rain" || lobby.hash != "01" do return false
	for player in lobby.players do if player.ready do return false
	return true
}

seat_passed_on :: proc(clients: []^online.Lobby_Client) -> bool {
	lobby := online.lobby_joined(clients[1])
	host, late := online.lobby_player(lobby, clients[0].key), online.lobby_player(lobby, clients[2].key)
	return host.side == -1 && host.queued == 0 && late.side == 0
}

match_started :: proc(clients: []^online.Lobby_Client) -> bool {
	for client in clients[:2] do if online.lobby_joined(client).match == nil do return false
	return true
}

rematch_open :: proc(clients: []^online.Lobby_Client) -> bool {
	lobby := online.lobby_joined(clients[0])
	if lobby.match != nil do return false
	for player in lobby.players do if player.ready do return false
	return true
}
