package content

// (hole content-cache :tags (content net) :needs https-client :sev blocker) no download-and-verify of pack files by SHA-256 from the network's files host; no local cache.
fetch :: proc(hash: [32]u8, sources: []string) -> (data: []byte, ok: bool) {
	return nil, false
}
