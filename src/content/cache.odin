package content

// (hole content-cache :tags (content net) :sev blocker) no download-and-verify of packs, overlays and mod files by SHA-256; no local cache.
fetch :: proc(hash: [32]u8, server: string) -> (data: []byte, ok: bool) {
	return nil, false
}
