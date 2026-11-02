// A db patch: `<db>.patch` in a pack, same schema as <db>. Its rows replace rows with the same key, and its lists
// replace whole lists (docs/formats.md).
package content

// (hole patch-apply :tags content :needs pack-open :sev blocker) db patches are not applied: a row replaces its row by key in place (an upsert keeps its spot in the sheet), a list in the patch replaces that whole list, and a new text key outside the pack's own `<id>/` namespace is not refused.
apply_patch :: proc(p: ^Pack, patch: []byte) -> (ok: bool) {
	return false
}

// (hole patch-write :tags (content editor) :needs pack-open) no way to diff an edited database into a db patch.
write_patch :: proc(base, edited: ^Pack, path: string) -> (ok: bool) {
	return false
}
