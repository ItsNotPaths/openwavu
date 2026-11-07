// The registry: the packs a network's files host lists. Not signed: each download is checked against the SHA-256 the
// listing gives.
package content

// (hole dmca-agent :tags (content net) :sev blocker) before the registry takes uploads: no DMCA designated agent filed with the US Copyright Office and no takedown address, so openwavu.gg has no safe harbor (17 U.S.C. 512); no submission agreement shown at upload (docs/packs.md).
// (hole registry-verify :tags (content net) :sev blocker) a download is not checked against the SHA-256 from /store; a mangled tar would install.
verify_download :: proc(data: []byte, sha256: [32]u8) -> (ok: bool) {
	return false
}
