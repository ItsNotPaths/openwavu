// The registry: trusted reviewers approve each pack version, and the registry signs its manifest hash.
// The client ships the registry's public key and auto-loads only signed manifests.
package content

REGISTRY_KEY :: [32]u8{}

// (hole dmca-agent :tags (content net) :sev blocker) before the registry takes uploads: no DMCA designated agent filed with the US Copyright Office and no takedown address, so the master server has no safe harbor (17 U.S.C. 512); no submission agreement shown at upload (docs/packs.md).
// (hole registry-verify :tags (content net) :sev blocker) manifest signatures are not checked; any pack would load.
verify_manifest :: proc(manifest_hash: [32]u8, signature: [64]u8) -> (ok: bool) {
	return false
}
