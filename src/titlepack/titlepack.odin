// Title pack: one tar (docs/packs.md). At the root: pack.toml (the first entry), the wasm modules and the db or
// db patch; everything else in folders the modules name. Params narrow in layers: core defaults, pack, server,
// lobby. Each layer sets values and exposes a subset.
package titlepack

import "core:path/filepath"
import "core:slice"
import "core:strings"

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
	path:              string,  // the tar
	id, name, version: string,
	// (hole pack-base :tags titlepack) bases are not checked; a pack whose base the player lacks, or has at another version, fails inside the sim, not at join.
	bases:             []string,  // pack ids, bottom first; a stock pack has none
}

// pack.toml text -> the pack. id and version are required; name falls back to the id.
read_titlepack :: proc(manifest: string, allocator := context.allocator) -> (tp: Title_Pack, ok: bool) {
	table, err := read_toml(manifest, context.temp_allocator)
	if err != "" do return
	id := table.values["id"].(string) or_return
	version := table.values["version"].(string) or_return
	name := table.values["name"].(string) or_else id
	bases := make([dynamic]string, allocator)
	if list, has := table.values["bases"].([dynamic]Toml_Value); has {
		for base in list {
			if s, is_string := base.(string); is_string do append(&bases, strings.clone(s, allocator))
		}
	}
	tp = {
		id      = strings.clone(id, allocator),
		name    = strings.clone(name, allocator),
		version = strings.clone(version, allocator),
		bases   = bases[:],
	}
	return tp, true
}

destroy_titlepack :: proc(tp: Title_Pack, allocator := context.allocator) {
	delete(tp.path, allocator)
	delete(tp.id, allocator)
	delete(tp.name, allocator)
	delete(tp.version, allocator)
	for base in tp.bases do delete(base, allocator)
	delete(tp.bases, allocator)
}

// (hole data-dir :tags titlepack :sev polish) packs live in the working directory, not a per-user data folder.
PACKS_DIR :: "packs"

// Every packs/*.tar whose pack.toml reads, sorted by name. Others are skipped.
installed :: proc(allocator := context.allocator) -> []Title_Pack {
	paths, _ := filepath.glob(PACKS_DIR + "/*.tar", context.temp_allocator)
	packs := make([dynamic]Title_Pack, allocator)
	for path in paths {
		manifest := read_manifest(path, context.temp_allocator) or_continue
		tp := read_titlepack(manifest, allocator) or_continue
		tp.path = strings.clone(path, allocator)
		append(&packs, tp)
	}
	slice.sort_by(packs[:], proc(a, b: Title_Pack) -> bool {return a.name < b.name})
	return packs[:]
}

destroy_installed :: proc(packs: []Title_Pack, allocator := context.allocator) {
	for tp in packs do destroy_titlepack(tp, allocator)
	delete(packs, allocator)
}

// (hole param-section :tags (titlepack sdk)) no OW_PARAM macro in the SDK, and the host does not read the openwavu.params section.
read_params :: proc(module: []byte, allocator := context.allocator) -> (params: []Param, ok: bool) {
	return nil, false
}

// (hole param-layers :tags titlepack :needs param-section) params are not narrowed pack -> server -> lobby; a layer could change what the one above locked.
resolve_params :: proc(declared: []Param, layers: []map[string]Param_Set) -> (final: map[string]f64, ok: bool) {
	return nil, false
}

// (hole titlepack-hash :tags titlepack :needs param-layers) the lobby hash (manifest hash + final params) is not computed.
lobby_hash :: proc(manifest_hash: [32]u8, final: map[string]f64) -> (hash: [32]u8) {
	return {}
}
