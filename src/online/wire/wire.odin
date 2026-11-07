// The lobbies role's wire (docs/network.md), shared by the lobby server and its clients: ENet channel 0 carries kipp
// lines, one per reliable packet; channel 1 carries session packets, unsequenced, which the server forwards to the
// other player of a running match.
package wire

import "core:crypto/ed25519"
import "core:encoding/endian"

PORT :: 9288  // "wavu" on a phone keypad
CHANNEL_CONTROL :: 0
CHANNEL_SESSION :: 1
CHANNELS :: 2
PROTOCOL :: "1"
START_DELAY_MS :: 2000  // from the match fact to frame 0
LOBBY_PLAYERS_MAX :: 2
LOADOUT_MAX :: 256  // bytes; sent as hex inside one line

// A session packet's first four bytes are its match's token.
packet_token :: proc(packet: []byte) -> (token: u32, ok: bool) {
	return endian.get_u32(packet, .Little)
}

// True when signature is message signed by the key public_key.
signed_by :: proc(public_key: [ed25519.PUBLIC_KEY_SIZE]u8, message: []byte, signature: [ed25519.SIGNATURE_SIZE]u8) -> bool {
	public_key, signature := public_key, signature
	key: ed25519.Public_Key
	return ed25519.public_key_set_bytes(&key, public_key[:]) && ed25519.verify(&key, message, signature[:])
}
