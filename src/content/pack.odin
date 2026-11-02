// A pack file at run time: its tar and its game database.
package content

import "../db"

Pack :: struct {
	path: string,  // packs/<id>.tar
	db:   ^db.Sqlite,  // in memory, so patches from the packs above can apply
}

// (hole pack-open :tags (content mech) :sev blocker) packs do not load; nothing reads tk5.db at run time.
open_pack :: proc(path: string) -> (p: Pack, ok: bool) {
	return {}, false
}

close_pack :: proc(p: ^Pack) {}

// What a pack sees: its bases in pack.toml order, then the pack itself; the same path in a later layer wins.
// A stock pack has no bases and is a view of one layer.
View :: struct {
	layers: []Pack,
}

// (hole content-view :tags (content titlepack) :needs (pack-open patch-apply titlepack-format)) no file view of a pack over its bases behind content_read, with each layer's db patches applied to the database below.
open_view :: proc(tars: []string) -> (v: View, ok: bool) {
	return {}, false
}
