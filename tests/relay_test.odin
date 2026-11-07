package tests

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../src/online"
import "../src/online/relay"
import "../src/sim"

RELAY_TEST_PORT :: 9289
RELAY_HOST :: #config(RELAY_HOST, "")  // a deployed relay to test instead of one on this machine

// Two machines paired by a relay server get one seed and a side each, and their sessions stay in step through it.
@(test)
sessions_agree_through_the_relay :: proc(t: ^testing.T) {
	stock, opened := stock_sim_open(t)
	if !opened do return
	defer stock_sim_close(stock)
	host, port := RELAY_HOST, u16(relay.PORT)
	relay_server: relay.Server
	stop: bool
	serving: ^thread.Thread
	defer if serving != nil {
		sync.atomic_store(&stop, true)
		thread.join(serving)
		thread.destroy(serving)
		relay.close(&relay_server)
	}
	if host == "" {
		host, port = "127.0.0.1", RELAY_TEST_PORT
		listening: bool
		relay_server, listening = relay.open(port)
		if !testing.expect(t, listening, "the relay can not listen") do return
		serving = thread.create_and_start_with_poly_data2(&relay_server, &stop, relay.serve)
	}

	clients: [2]^online.Relay_Client
	defer for client in clients do if client != nil do online.relay_disconnect(client)
	for &client in clients {
		connected: bool
		client, connected = online.relay_connect(host, port)
		if !testing.expect(t, connected, "a client did not connect") do return
	}
	machines := new(Two_Machines)
	defer two_machines_destroy(machines)
	machines.pause = time.Millisecond
	seeds: [2]u64
	for client in clients {
		start, start_in_ns, started := online.relay_wait_start(client, 5000)
		if !testing.expect(t, started, "a client was not paired") do return
		testing.expect(t, start_in_ns <= u64(relay.START_DELAY_MS) * 1_000_000)
		created: bool
		if machines.worlds[start.side], created = stock_world(t, stock, start.seed); !created do return
		machines.sessions[start.side] = online.session_create(machines.worlds[start.side], online.relay_transport(client), start.side, start.token, 0)
		seeds[start.side] = start.seed
	}
	testing.expect_value(t, seeds[0], seeds[1])

	FRAMES :: 600
	if !testing.expect(t, two_machines_play(t, machines, FRAMES), "the sessions did not both finish") do return
	testing.expect(t, sim.state_hash(machines.worlds[0]) == sim.state_hash(machines.worlds[1]), "the two machines' states differ")
	for session in machines.sessions do testing.expect_value(t, session.outcome, online.Outcome.Playing)
}
