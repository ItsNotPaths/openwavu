package online

import "core:crypto"
import "core:crypto/ed25519"
import "core:os"

// The player id: an Ed25519 key made once per install (docs/network.md).
Identity :: struct {
	public_key: [ed25519.PUBLIC_KEY_SIZE]u8,
	seed:       [ed25519.PRIVATE_KEY_SIZE]u8,
}

// Loads the key at path, or makes and saves one when no file is there. A file that does not read is an error and
// stays as it is: replacing it would lose the player's id.
load_identity :: proc(path: string) -> (identity: Identity, err: string) {
	if os.exists(path) {
		bytes, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil || len(bytes) != len(identity.seed) do return {}, "identity.key does not read"
		copy(identity.seed[:], bytes)
	} else {
		crypto.rand_bytes(identity.seed[:])
		if os.write_entire_file(path, identity.seed[:], {.Read_User, .Write_User}) != nil do return {}, "identity.key could not be saved"
	}
	private_key: ed25519.Private_Key
	defer ed25519.private_key_clear(&private_key)
	if !ed25519.private_key_set_bytes(&private_key, identity.seed[:]) do return {}, "identity.key does not read"
	ed25519.private_key_public_bytes(&private_key, identity.public_key[:])
	return identity, ""
}

// The signature of message (the server's challenge) by the player's key.
sign :: proc(identity: Identity, message: []byte) -> (signature: [ed25519.SIGNATURE_SIZE]u8) {
	identity := identity
	private_key: ed25519.Private_Key
	defer ed25519.private_key_clear(&private_key)
	_ = ed25519.private_key_set_bytes(&private_key, identity.seed[:])  // load_identity checked the seed
	ed25519.sign(&private_key, message, signature[:])
	return
}

// True when signature is message signed by the key public_key.
signed_by :: proc(public_key: [ed25519.PUBLIC_KEY_SIZE]u8, message: []byte, signature: [ed25519.SIGNATURE_SIZE]u8) -> bool {
	public_key, signature := public_key, signature
	key: ed25519.Public_Key
	return ed25519.public_key_set_bytes(&key, public_key[:]) && ed25519.verify(&key, message, signature[:])
}
