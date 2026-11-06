package server

import "core:fmt"
import "core:math/rand"
import "core:sync"
import enet "vendor:ENet"
import "../net/relay"

// The bare relay (ws.md Workstream E): players are paired in the order they connect, and each pair's session packets
// are forwarded to the other player. Runs no pack code.
Relay :: struct {
	host:    ^enet.Host,
	waiting: ^enet.Peer,  // connected, not yet paired
}

// peer.data of both players in a match.
Pair :: struct {
	players: [2]^enet.Peer,
	token:   u32,
}

RELAY_PEERS_MAX :: 64

relay_open :: proc(port: u16) -> (r: Relay, ok: bool) {
	if enet.initialize() != 0 do return
	address := enet.Address{host = enet.HOST_ANY, port = port}
	r.host = enet.host_create(&address, RELAY_PEERS_MAX, relay.CHANNELS, 0, 0)
	return r, r.host != nil
}

relay_close :: proc(r: ^Relay) {
	enet.host_destroy(r.host)
	enet.deinitialize()
}

// Serves until stop is set.
relay_serve :: proc(r: ^Relay, stop: ^bool) {
	event: enet.Event
	for !sync.atomic_load(stop) {
		if enet.host_service(r.host, &event, 100) <= 0 do continue
		#partial switch event.type {
		case .CONNECT:    arrive(r, event.peer)
		case .RECEIVE:    forward(event.peer, event.packet, event.channelID)
		case .DISCONNECT: leave(r, event.peer)
		}
	}
}

@(private = "file")
arrive :: proc(r: ^Relay, peer: ^enet.Peer) {
	if r.waiting == nil {
		r.waiting = peer
		return
	}
	pair_players(r.waiting, peer)
	r.waiting = nil
}

@(private = "file")
pair_players :: proc(first, second: ^enet.Peer) {
	pair := new(Pair)
	pair^ = {players = {first, second}, token = rand.uint32()}
	seed := rand.uint64()
	for player, side in pair.players {
		player.data = pair
		message := relay.start_encode({side = side, token = pair.token, seed = seed, delay_ms = relay.START_DELAY_MS})
		enet.peer_send(player, relay.CHANNEL_CONTROL, enet.packet_create(&message, len(message), {.RELIABLE}))
	}
	fmt.eprintfln("relay: match %08x paired", pair.token)
}

@(private = "file")
forward :: proc(from: ^enet.Peer, packet: ^enet.Packet, channel: u8) {
	defer enet.packet_destroy(packet)
	pair := (^Pair)(from.data)
	if pair == nil || channel != relay.CHANNEL_SESSION do return
	bytes := packet.data[:packet.dataLength]
	if token, ok := relay.packet_token(bytes); !ok || token != pair.token do return
	to := pair.players[0] == from ? pair.players[1] : pair.players[0]
	enet.peer_send(to, relay.CHANNEL_SESSION, enet.packet_create(raw_data(bytes), len(bytes), {.UNSEQUENCED}))
}

// The other player's session ends on its own after the session timeout.
@(private = "file")
leave :: proc(r: ^Relay, peer: ^enet.Peer) {
	if r.waiting == peer do r.waiting = nil
	pair := (^Pair)(peer.data)
	if pair == nil do return
	for player in pair.players do player.data = nil
	fmt.eprintfln("relay: match %08x ended", pair.token)
	free(pair)
}
