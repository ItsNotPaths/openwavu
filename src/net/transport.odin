package net

// How a session's packets travel: ENet through the lobby server, or a pipe in tests. Each send is one datagram, which
// may be lost, late or out of order.
Transport :: struct {
	data:    rawptr,
	send:    proc(data: rawptr, packet: []byte),
	receive: proc(data: rawptr, buffer: []byte) -> (size: int),  // 0: nothing waiting
}

// (hole net-enet :tags net :needs server-lobby :sev blocker) no ENet transport (Odin's vendor:ENet) on the unreliable channel to the lobby server.
enet_transport :: proc(host: string) -> (transport: Transport, ok: bool) {
	return {}, false
}
