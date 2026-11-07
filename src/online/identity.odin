package online

// The player id: an Ed25519 key made once per install (docs/network.md).
Identity :: struct {
	public_key: [32]u8,
	seed:       [32]u8,
}

// (hole identity-key :tags net :sev blocker) no identity.key: not made from the OS random source on first run, not loaded, no challenge signing; an unreadable file must be an error, never replaced.
load_identity :: proc(path: string) -> (identity: Identity, ok: bool) {
	return {}, false
}
