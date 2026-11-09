package tests

import "core:sync"
import "core:testing"
import "core:thread"
import "../src/online"
import "../src/online/lobbies"

LOBBY_LOCK_TEST_PORT :: 9290

// A locked lobby takes only its password. The host's kick puts a member out, who may come back; a ban keeps them out.
@(test)
lobby_password_kick_and_ban :: proc(t: ^testing.T) {
	server, listening := lobbies.open(LOBBY_LOCK_TEST_PORT)
	if !testing.expect(t, listening, "the lobby server can not listen") do return
	stop: bool
	serving := thread.create_and_start_with_poly_data2(&server, &stop, lobbies.serve)
	defer {
		sync.atomic_store(&stop, true)
		thread.join(serving)
		thread.destroy(serving)
		lobbies.close(&server)
	}
	clients: [2]^online.Lobby_Client
	defer for client in clients do if client != nil do online.lobby_disconnect(client)
	for &client in clients {
		err: string
		client, err = online.lobby_connect("127.0.0.1", online.new_identity(), "player", LOBBY_LOCK_TEST_PORT)
		if !testing.expect_value(t, err, "") do return
	}
	host, guest := clients[0], clients[1]

	online.lobby_create(host, "tekken5dr@1", "versus", "stage=dragons_nest", "00")
	if !testing.expect(t, pump_until(clients[:], lobby_shown_to_guest), "the lobby did not show") do return
	id := guest.lobbies[0].id
	online.lobby_lock(host, "1234")
	if !testing.expect(t, pump_until(clients[:], lobby_locked), "the lobby is not locked") do return

	online.lobby_join(guest, id, "")
	if !testing.expect(t, pump_until(clients[:], guest_refused), "joined with no password") do return
	testing.expect_value(t, guest.refused, "wrong password")

	online.lobby_join(guest, id, "1234")
	if !testing.expect(t, pump_until(clients[:], guest_joined), "the password did not let the guest in") do return

	online.lobby_kick(host, guest.key, false)
	if !testing.expect(t, pump_until(clients[:], guest_out), "the kick did not put the guest out") do return
	testing.expect_value(t, guest.refused, "the host kicked you")
	clear_refused(guest)
	online.lobby_join(guest, id, "1234")
	if !testing.expect(t, pump_until(clients[:], guest_joined), "a kicked guest can not come back") do return

	online.lobby_kick(host, guest.key, true)
	if !testing.expect(t, pump_until(clients[:], guest_out), "the ban did not put the guest out") do return
	clear_refused(guest)
	online.lobby_join(guest, id, "1234")
	if !testing.expect(t, pump_until(clients[:], guest_refused), "a banned guest got back in") do return
	testing.expect_value(t, guest.refused, "banned from this lobby")
}

clear_refused :: proc(client: ^online.Lobby_Client) {
	delete(client.refused)
	client.refused = ""
}

// The conditions of lobby_password_kick_and_ban: clients are the host and the guest.
lobby_shown_to_guest :: proc(clients: []^online.Lobby_Client) -> bool {return len(clients[1].lobbies) == 1}
lobby_locked :: proc(clients: []^online.Lobby_Client) -> bool {return clients[1].lobbies[0].locked}
guest_refused :: proc(clients: []^online.Lobby_Client) -> bool {return clients[1].refused != ""}
guest_joined :: proc(clients: []^online.Lobby_Client) -> bool {return online.lobby_joined(clients[1]) != nil}
guest_out :: proc(clients: []^online.Lobby_Client) -> bool {
	return online.lobby_joined(clients[1]) == nil && len(clients[0].lobbies[0].players) == 1
}
