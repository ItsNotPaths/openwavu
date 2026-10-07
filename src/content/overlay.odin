// Overlays: a zip with overlay.db (same schema, changed rows and a `removed` table) plus new files.
package content

// (hole zip-reader :tags content) no in-memory zip reader; overlays can not be opened.
read_zip :: proc(data: []byte, allocator := context.allocator) -> (files: map[string][]byte, ok: bool) {
	return nil, false
}

// (hole overlay-apply :tags content :needs (pack-open zip-reader) :sev blocker) overlays are not applied (ATTACH, INSERT OR REPLACE, removed rows).
apply_overlay :: proc(p: ^Pack, zip: []byte) -> (ok: bool) {
	return false
}

// (hole overlay-write :tags (content editor) :needs pack-open) no way to diff an edited pack into an overlay zip.
write_overlay :: proc(base, edited: ^Pack, path: string) -> (ok: bool) {
	return false
}

