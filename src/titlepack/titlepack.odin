// Title pack: a self-contained game. pack.toml names the sim and app modules, files by hash, and params.
// Params narrow in layers: core defaults, pack, server, lobby. Each layer sets values and exposes a subset.
package titlepack

// A param as a module declares it (OW_PARAM writes the openwavu.params custom section).
Param :: struct {
	name:     string,
	default:  f64,
	min, max: f64,
}

// One layer's say on a param: its value, whether the next layer may change it, and a narrower range.
Param_Set :: struct {
	value:    f64,
	expose:   bool,
	min, max: f64,
}

Title_Pack :: struct {
	id, version: string,
	// (hole pack-base :tags titlepack :needs titlepack-format) the base import (game id, import schema version) is not checked; a pack for an import the player lacks fails inside the sim, not at join.
	base:        string,  // e.g. "tk5/1"
	sim, app:    [32]u8,  // module hashes; stock modules are hashes too
	files:       map[string][32]u8,  // pack path -> hash
	mirrors:     []string,
	params:      map[string]Param_Set,
	overlays:    [][32]u8,
}

// (hole titlepack-format :tags titlepack :sev blocker) pack.toml is not read: id, version, optional base, module hashes, files, mirrors, params, overlays.
read_titlepack :: proc(manifest: []byte, allocator := context.allocator) -> (tp: Title_Pack, ok: bool) {
	return {}, false
}

// (hole param-section :tags (titlepack sdk)) no OW_PARAM macro in the SDK, and the host does not read the openwavu.params section.
read_params :: proc(module: []byte, allocator := context.allocator) -> (params: []Param, ok: bool) {
	return nil, false
}

// (hole param-layers :tags titlepack :needs (titlepack-format param-section)) params are not narrowed pack -> server -> lobby; a layer could change what the one above locked.
resolve_params :: proc(declared: []Param, layers: []map[string]Param_Set) -> (final: map[string]f64, ok: bool) {
	return nil, false
}

// (hole titlepack-hash :tags titlepack :needs (titlepack-format param-layers)) the lobby hash (manifest hash + final params) is not computed.
lobby_hash :: proc(manifest_hash: [32]u8, final: map[string]f64) -> (hash: [32]u8) {
	return {}
}
