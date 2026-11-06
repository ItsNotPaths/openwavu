// The registry: a network's reviewers approve each pack version, and its files host signs the manifest hash with the
// network key. The client ships openwavu.gg's key, pins another network's key on first contact, and auto-loads only
// signed manifests.
package content

OPENWAVU_NETWORK_KEY :: [32]u8{}

// (hole dmca-agent :tags (content net) :sev blocker) before the registry takes uploads: no DMCA designated agent filed with the US Copyright Office and no takedown address, so openwavu.gg has no safe harbor (17 U.S.C. 512); no submission agreement shown at upload (docs/packs.md).
// (hole registry-verify :tags (content net) :sev blocker) manifest signatures are not checked against the network key, and no other network's key is pinned; any pack would load.
verify_manifest :: proc(manifest_hash: [32]u8, signature: [64]u8) -> (ok: bool) {
	return false
}
