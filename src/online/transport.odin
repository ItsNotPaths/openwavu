package online

// How a session's packets travel: ENet through the lobby server, or a pipe in tests. Each send is one datagram, which
// may be lost, late or out of order.
Transport :: struct {
	data:    rawptr,
	send:    proc(data: rawptr, packet: []byte),
	receive: proc(data: rawptr, buffer: []byte) -> (size: int),  // 0: nothing waiting
}
