// The registry: the packs a network's files host lists. Not signed: each download is checked against the SHA-256 the
// listing gives.
package download

import "core:crypto/hash"
import "core:encoding/hex"

// (hole dmca-agent :tags (content net) :sev blocker) before the registry takes uploads: no DMCA designated agent filed with the US Copyright Office and no takedown address, so openwavu.org has no safe harbor (17 U.S.C. 512); no submission agreement shown at upload (docs/packs.md).
verify :: proc(data: []byte, sha256: string) -> (ok: bool) {
	digest := hash.hash_bytes(.SHA256, data, context.temp_allocator)
	return string(hex.encode(digest, context.temp_allocator)) == sha256
}
