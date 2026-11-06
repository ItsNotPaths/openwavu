package net

import "core:strings"
import enet "vendor:ENet"
import "relay"

// How a session's packets travel: ENet through the lobby server, or a pipe in tests. Each send is one datagram, which
// may be lost, late or out of order.
Transport :: struct {
	data:    rawptr,
	send:    proc(data: rawptr, packet: []byte),
	receive: proc(data: rawptr, buffer: []byte) -> (size: int),  // 0: nothing waiting
}

// A connection to a relay server: wait for its Start, then hand relay_transport to a session.
Relay_Client :: struct {
	host:   ^enet.Host,
	server: ^enet.Peer,
}

CONNECT_TIMEOUT_MS :: 5000

relay_connect :: proc(host_name: string, port: u16) -> (client: ^Relay_Client, ok: bool) {
	if enet.initialize() != 0 do return
	client = new(Relay_Client)
	defer if !ok do relay_disconnect(client)
	if client.host = enet.host_create(nil, 1, relay.CHANNELS, 0, 0); client.host == nil do return
	address := enet.Address{port = port}
	if enet.address_set_host(&address, strings.clone_to_cstring(host_name, context.temp_allocator)) != 0 do return
	if client.server = enet.host_connect(client.host, &address, relay.CHANNELS, 0); client.server == nil do return
	event: enet.Event
	ok = enet.host_service(client.host, &event, CONNECT_TIMEOUT_MS) > 0 && event.type == .CONNECT
	enet.host_flush(client.host)  // the server counts the connect when this ack arrives
	return
}

relay_disconnect :: proc(client: ^Relay_Client) {
	if client.server != nil {
		enet.peer_disconnect(client.server, 0)
		enet.host_flush(client.host)
	}
	if client.host != nil do enet.host_destroy(client.host)
	enet.deinitialize()
	free(client)
}

// Waits for the server to pair this player. start_in_ns: from now until frame 0, the server's delay less half the
// round trip it took to arrive.
relay_wait_start :: proc(client: ^Relay_Client, timeout_ms: u32) -> (start: relay.Start, start_in_ns: u64, ok: bool) {
	event: enet.Event
	for enet.host_service(client.host, &event, timeout_ms) > 0 {
		if event.type == .DISCONNECT do return
		if event.type != .RECEIVE do continue
		if event.channelID == relay.CHANNEL_CONTROL do start, ok = relay.start_decode(event.packet.data[:event.packet.dataLength])
		enet.packet_destroy(event.packet)
		if ok {
			half_trip_ms := min(client.server.roundTripTime / 2, start.delay_ms)
			return start, u64(start.delay_ms - half_trip_ms) * 1_000_000, true
		}
	}
	return
}

relay_transport :: proc(client: ^Relay_Client) -> Transport {
	send :: proc(data: rawptr, packet: []byte) {
		client := (^Relay_Client)(data)
		enet.peer_send(client.server, relay.CHANNEL_SESSION, enet.packet_create(raw_data(packet), len(packet), {.UNSEQUENCED}))
		enet.host_flush(client.host)
	}
	receive :: proc(data: rawptr, buffer: []byte) -> (size: int) {
		client := (^Relay_Client)(data)
		event: enet.Event
		for enet.host_service(client.host, &event, 0) > 0 {
			if event.type != .RECEIVE do continue
			if event.channelID == relay.CHANNEL_SESSION do size = copy(buffer, event.packet.data[:event.packet.dataLength])
			enet.packet_destroy(event.packet)
			if size > 0 do return
		}
		return 0
	}
	return {client, send, receive}
}
