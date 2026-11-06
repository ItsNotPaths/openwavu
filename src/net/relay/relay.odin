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
