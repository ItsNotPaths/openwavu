// A content pack at run time: the game database plus its files, with the lobby's overlays applied.
package content

import "../db"

Pack :: struct {
	root: string,  // content/<game>
	db:   ^db.Sqlite,  // in memory, overlays applied
}

// (hole pack-open :tags (content mech) :sev blocker) packs do not load; nothing reads tk5.db at run time.
open_pack :: proc(root: string) -> (p: Pack, ok: bool) {
	return {}, false
}

close_pack :: proc(p: ^Pack) {}

// A title pack's files: the base import (if the pack names one), then the pack's own files; same path wins.
View :: struct {
	base, pack: Pack,
}

// (hole content-view :tags (content titlepack) :needs (pack-open overlay-apply titlepack-format)) no file view of base import + pack files + overlays behind content_read; a pack can not ship its own database.
open_view :: proc(base: Maybe(string), pack_root: string, overlays: []string) -> (v: View, ok: bool) {
	return {}, false
}
