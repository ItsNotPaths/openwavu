// The relay's wire, shared by openwavu-server and the game: ENet channel 0 is reliable control messages, channel 1
// carries session packets unchanged, unsequenced. Little endian.
package relay

import "core:encoding/endian"

PORT :: 9288  // "wavu" on a phone keypad
CHANNEL_CONTROL :: 0
CHANNEL_SESSION :: 1
CHANNELS :: 2
START_DELAY_MS :: 2000

// Sent to both players when the server pairs them. Frame 0 is delay_ms after the server sends it.
Start :: struct {
	side:     int,
	token:    u32,
	seed:     u64,
	delay_ms: u32,
}

START_SIZE :: 1 + 4 + 8 + 4

start_encode :: proc(start: Start) -> (message: [START_SIZE]byte) {
	message[0] = u8(start.side)
	endian.put_u32(message[1:], .Little, start.token)
	endian.put_u64(message[5:], .Little, start.seed)
	endian.put_u32(message[13:], .Little, start.delay_ms)
	return
}

start_decode :: proc(message: []byte) -> (start: Start, ok: bool) {
	if len(message) != START_SIZE || message[0] > 1 do return
	start.side = int(message[0])
	start.token, _ = endian.get_u32(message[1:], .Little)
	start.seed, _ = endian.get_u64(message[5:], .Little)
	start.delay_ms, _ = endian.get_u32(message[13:], .Little)
	return start, true
}

// A session packet's first four bytes are its token.
packet_token :: proc(packet: []byte) -> (token: u32, ok: bool) {
	return endian.get_u32(packet, .Little)
}

// Sent by one player to the other on the control channel, through the relay: what both sims start from. A stand-in
// for the lobby's match start (hole server-lobby).
Setup :: struct {
	sim:      string,  // the mode's sim module, a path in the pack
	params:   string,  // "name=value name=value"
	loadouts: [2][]byte,
}

// Each part as a u16 length and its bytes.
setup_encode :: proc(setup: Setup, allocator := context.allocator) -> (message: []byte) {
	parts := [4][]byte{transmute([]byte)setup.sim, transmute([]byte)setup.params, setup.loadouts[0], setup.loadouts[1]}
	size := 0
	for part in parts do size += 2 + len(part)
	message = make([]byte, size, allocator)
	at := 0
	for part in parts {
		endian.put_u16(message[at:], .Little, u16(len(part)))
		at += 2 + copy(message[at + 2:], part)
	}
	return
}

// The parts point into message.
setup_decode :: proc(message: []byte) -> (setup: Setup, ok: bool) {
	parts: [4][]byte
	at := 0
	for &part in parts {
		size := endian.get_u16(message[at:], .Little) or_return
		if at + 2 + int(size) > len(message) do return
		part = message[at + 2:][:size]
		at += 2 + int(size)
	}
	return {string(parts[0]), string(parts[1]), {parts[2], parts[3]}}, at == len(message)
}
