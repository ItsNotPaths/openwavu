// Title pack: one ruleset bundle. A lobby runs one pack; players download it once, cached by hash.
// Modules for the sim, mode and presentation seams; the default TK5 modules ship with the release.
package titlepack

Setting :: struct {
	name, type, default_value: string,  // a value the server host may change
}

Title_Pack :: struct {
	id, version:  string,
	base_sources: map[string]string,  // source key -> value the base pack must have
	modules:      map[string][32]u8,  // seam -> module hash
	rules:        map[string]string,  // rules.toml
	settings:     []Setting,
	overlays:     [][32]u8,
}

// (hole titlepack-format :tags titlepack :sev blocker) no title pack format: manifest.toml, rules.toml, seam -> module hashes, settings, overlays.
read_titlepack :: proc(zip: []byte, allocator := context.allocator) -> (tp: Title_Pack, ok: bool) {
	return {}, false
}

// (hole titlepack-hash :tags titlepack :needs titlepack-format) the lobby hash (pack hash + host settings) is not computed.
pack_hash :: proc(tp: Title_Pack, settings: map[string]string) -> (hash: [32]u8) {
	return {}
}
