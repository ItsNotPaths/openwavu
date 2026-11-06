// Title pack: one tar (docs/packs.md). At the root: pack.toml (the first entry), the wasm modules and the db or
// db patch; everything else in folders the modules name. Params narrow in layers: core defaults, pack,
// network, lobby. Each layer sets values and exposes a subset.
package titlepack

import "core:c"
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

// A match mode: the sim module and the presentation module that draws it.
Mode :: struct {
	name, sim, presenter: string,
}

Title_Pack :: struct {
	path:              string,  // the tar
	id, name, version: string,
	main:              string,  // the entry module; "" for a pack without code (a db mod)
	modes:             []Mode,    // sorted by name
	// (hole pack-base :tags titlepack) bases are not checked: each must be a stock pack id (tekken5dr, later tekken6br), and a pack whose base is not installed should be refused at install, not fail inside the sim.
	bases:             []string,  // pack ids, bottom first; a stock pack has none
}

// pack.toml text -> the pack. id and version are required; name falls back to the id. Each [modes.x] needs both a sim
// and a presenter.
read_titlepack :: proc(manifest: string, allocator := context.allocator) -> (tp: Title_Pack, ok: bool) {
	if len(manifest) > int(max(c.int)) do return
	result := toml_parse(raw_data(manifest), c.int(len(manifest)))
	defer toml_free(result)
	if !result.ok do return
	top := result.top
	id := toml_text(toml_get(top, "id")) or_return
	version := toml_text(toml_get(top, "version")) or_return
	name := toml_text(toml_get(top, "name")) or_else id
	main := toml_text(toml_get(top, "main")) or_else ""
	modes := read_modes(top) or_return
	bases := make([dynamic]string, allocator)
	if list := toml_get(top, "bases"); list.type == .Array {
		for element in list.array.elements[:list.array.size] {
			if base, is_text := toml_text(element); is_text do append(&bases, strings.clone(base, allocator))
		}
	}
	tp = {
		id      = strings.clone(id, allocator),
		name    = strings.clone(name, allocator),
		version = strings.clone(version, allocator),
		main    = strings.clone(main, allocator),
		modes   = make([]Mode, len(modes), allocator),
		bases   = bases[:],
	}
	for mode, i in modes do tp.modes[i] = {strings.clone(mode.name, allocator), strings.clone(mode.sim, allocator), strings.clone(mode.presenter, allocator)}
	return tp, true
}

// The [modes.x] tables, sorted by name; views into top's result, in the temp allocator.
@(private = "file")
read_modes :: proc(top: Toml_Datum) -> (modes: []Mode, ok: bool) {
	section := toml_get(top, "modes")
	if section.type == .Unknown do return nil, true
	if section.type != .Table do return
	modes = make([]Mode, section.table.size, context.temp_allocator)
	for &mode, index in modes {
		entry := section.table.values[index]
		if entry.type != .Table do return
		mode.name = string(section.table.keys[index][:section.table.key_lengths[index]])
		mode.sim = toml_text(toml_get(entry, "sim")) or_return
		mode.presenter = toml_text(toml_get(entry, "presenter")) or_return
	}
	slice.sort_by(modes, proc(a, b: Mode) -> bool {return a.name < b.name})
	return modes, true
}

destroy_titlepack :: proc(tp: Title_Pack, allocator := context.allocator) {
	delete(tp.path, allocator)
	delete(tp.id, allocator)
	delete(tp.name, allocator)
	delete(tp.version, allocator)
	delete(tp.main, allocator)
	for mode in tp.modes {
		delete(mode.name, allocator)
		delete(mode.sim, allocator)
		delete(mode.presenter, allocator)
	}
	delete(tp.modes, allocator)
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

// (hole param-layers :tags titlepack :needs param-section) params are not narrowed pack -> network -> lobby; a layer could change what the one above locked.
resolve_params :: proc(declared: []Param, layers: []map[string]Param_Set) -> (final: map[string]f64, ok: bool) {
	return nil, false
}

// (hole titlepack-hash :tags titlepack :needs param-layers) the lobby hash (manifest hash + final params) is not computed.
lobby_hash :: proc(manifest_hash: [32]u8, final: map[string]f64) -> (hash: [32]u8) {
	return {}
}
