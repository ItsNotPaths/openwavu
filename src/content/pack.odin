// A content pack at run time: the game database plus its files, with the lobby's overlays applied.
package content

import "../db"

Pack :: struct {
	root: string,  // content/<game>
	db:   ^db.Sqlite,  // in memory, overlays applied
}

// (hole pack-open :tags content :sev blocker) packs do not load; nothing reads tk5.db at run time.
open_pack :: proc(root: string) -> (p: Pack, ok: bool) {
	return {}, false
}

close_pack :: proc(p: ^Pack) {}
