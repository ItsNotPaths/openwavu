package online

import "core:strings"
import "../titlepack"
import "wire"

// A lobby's picks -> their lobby hash for one pack, "" when the pack refuses them. Cached: a stock base's hash is a
// file read, a tar pack's a full hash of the tar.
Lobby_Hashes :: map[string]string

// This pack's, room for one more member, and the same lobby hash here. A member that joins during a match watches the next.
lobby_joinable :: proc(hashes: ^Lobby_Hashes, tp: titlepack.Title_Pack, lobby: ^Lobby) -> bool {
	if lobby.pack != titlepack.pack_name(tp.id, tp.version) || len(lobby.players) >= wire.LOBBY_MEMBERS_MAX do return false
	hash := picks_hash(hashes, tp, lobby.params)
	return hash != "" && hash == lobby.hash
}

picks_hash :: proc(hashes: ^Lobby_Hashes, tp: titlepack.Title_Pack, picks: string) -> string {
	if known, has := hashes[picks]; has do return known
	hash := ""
	if parsed, read := titlepack.parse_params(picks, context.temp_allocator); read {
		if text, _, err := titlepack.lobby_hash_text(tp, parsed, context.temp_allocator); err == "" do hash = text
	}
	hashes[strings.clone(picks)] = strings.clone(hash)
	return hashes[picks]
}

lobby_hashes_destroy :: proc(hashes: ^Lobby_Hashes) {
	for picks, hash in hashes {
		delete(picks)
		delete(hash)
	}
	delete(hashes^)
}
