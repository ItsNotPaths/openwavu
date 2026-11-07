package relay

import "core:fmt"
import "core:math/rand"
import "core:sync"
import enet "vendor:ENet"

// The bare relay (ws.md Workstream E): players are paired in the order they connect, and each pair's session packets
// and control messages are forwarded to the other player. Runs no pack code.
Server :: struct {
	host:    ^enet.Host,
	waiting: ^enet.Peer,  // connected, not yet paired
}

// peer.data of both players in a match.
Pair :: struct {
	players: [2]^enet.Peer,
	token:   u32,
}

PEERS_MAX :: 64

open :: proc(port: u16) -> (server: Server, ok: bool) {
	if enet.initialize() != 0 do return
	address := enet.Address{host = enet.HOST_ANY, port = port}
	server.host = enet.host_create(&address, PEERS_MAX, CHANNELS, 0, 0)
	return server, server.host != nil
}

close :: proc(server: ^Server) {
	enet.host_destroy(server.host)
	enet.deinitialize()
}

// Serves until stop is set.
serve :: proc(server: ^Server, stop: ^bool) {
	event: enet.Event
	for !sync.atomic_load(stop) {
		if enet.host_service(server.host, &event, 100) <= 0 do continue
		#partial switch event.type {
		case .CONNECT:    arrive(server, event.peer)
		case .RECEIVE:    forward(event.peer, event.packet, event.channelID)
		case .DISCONNECT: leave(server, event.peer)
		}
	}
}

@(private = "file")
arrive :: proc(server: ^Server, peer: ^enet.Peer) {
	if server.waiting == nil {
		server.waiting = peer
		return
	}
	pair_players(server.waiting, peer)
	server.waiting = nil
}

@(private = "file")
pair_players :: proc(first, second: ^enet.Peer) {
	pair := new(Pair)
	pair^ = {players = {first, second}, token = rand.uint32()}
	seed := rand.uint64()
	for player, side in pair.players {
		player.data = pair
		message := start_encode({side = side, token = pair.token, seed = seed, delay_ms = START_DELAY_MS})
		enet.peer_send(player, CHANNEL_CONTROL, enet.packet_create(&message, len(message), {.RELIABLE}))
	}
	fmt.eprintfln("relay: match %08x paired", pair.token)
}

@(private = "file")
forward :: proc(from: ^enet.Peer, packet: ^enet.Packet, channel: u8) {
	defer enet.packet_destroy(packet)
	pair := (^Pair)(from.data)
	if pair == nil || channel >= CHANNELS do return
	bytes := packet.data[:packet.dataLength]
	flags := enet.PacketFlags{.RELIABLE}
	if channel == CHANNEL_SESSION {
		if token, ok := packet_token(bytes); !ok || token != pair.token do return
		flags = {.UNSEQUENCED}
	}
	to := pair.players[0] == from ? pair.players[1] : pair.players[0]
	enet.peer_send(to, channel, enet.packet_create(raw_data(bytes), len(bytes), flags))
}

// The other player's session ends on its own after the session timeout.
@(private = "file")
leave :: proc(server: ^Server, peer: ^enet.Peer) {
	if server.waiting == peer do server.waiting = nil
	pair := (^Pair)(peer.data)
	if pair == nil do return
	for player in pair.players do player.data = nil
	fmt.eprintfln("relay: match %08x ended", pair.token)
	free(pair)
}
