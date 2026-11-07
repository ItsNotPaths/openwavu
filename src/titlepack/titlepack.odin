// Title pack: one tar (docs/packs.md). At the root: pack.toml (the first entry), the wasm modules and the db or
// db patch; everything else in folders the modules name. pack.toml declares the params; the lobby host may change the
// exposed ones, inside their ranges.
package titlepack

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// A match mode: the sim module and the presentation module that draws it.
Mode :: struct {
	name, sim, presenter: string,
}

Title_Pack :: struct {
	path:              string,  // the tar
	id, name, version: string,
	locked:            bool,  // an orphaned tile: its tar is <id>@<version>.tar and never updates
	main:              string,  // the entry module; "" for a pack without code (a db mod)
	modes:             []Mode,    // sorted by name
	bases:             []string,  // pack ids, bottom first; a stock pack has none
	params:            []Param,   // sorted by name
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
	params := read_params(top) or_return
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
		params  = make([]Param, len(params), allocator),
	}
	for mode, i in modes do tp.modes[i] = {strings.clone(mode.name, allocator), strings.clone(mode.sim, allocator), strings.clone(mode.presenter, allocator)}
	for param, i in params do tp.params[i] = param_clone(param, allocator)
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
	for param in tp.params do param_destroy(param, allocator)
	delete(tp.params, allocator)
}

// The user's data folder: packs/ and saves/. The game sets it at startup.
data_dir := "."

packs_dir :: proc() -> string {
	return join_path(data_dir, "packs")
}

// Where a base lives: a stock pack's folder in packs/.
base_path :: proc(id: string) -> string {
	return join_path(packs_dir(), id)
}

// The first base of tp that is not installed as a stock folder; "" when all are.
missing_base :: proc(tp: Title_Pack) -> string {
	for base in tp.bases do if !os.is_dir(base_path(base)) do return base
	return ""
}

// A pack that names no entry module or modes runs its bases': the top base that names them. It also takes every base
// param it does not declare itself, like a file of the same path.
inherit_from_bases :: proc(tp: ^Title_Pack, allocator := context.allocator) {
	#reverse for base in tp.bases {
		manifest := read_manifest(base_path(base), context.temp_allocator) or_continue
		base_tp := read_titlepack(manifest, allocator) or_continue
		if tp.main == "" do tp.main, base_tp.main = base_tp.main, ""
		if len(tp.modes) == 0 {
			delete(tp.modes, allocator)
			tp.modes, base_tp.modes = base_tp.modes, nil
		}
		params := slice.to_dynamic(tp.params, allocator)
		for param in base_tp.params do if _, found := find_param(params[:], param.name); !found do append(&params, param_clone(param, allocator))
		delete(tp.params, allocator)
		tp.params = params[:]
		slice.sort_by(tp.params, proc(a, b: Param) -> bool {return a.name < b.name})
		destroy_titlepack(base_tp, allocator)
	}
}

// Every packs/*.tar and stock packs/<id>/ folder whose pack.toml reads, sorted by name. Others are skipped, and so is
// a folder with bases: only stock packs, built on this machine, are folders.
installed :: proc(allocator := context.allocator) -> []Title_Pack {
	paths, _ := filepath.glob(join_path(packs_dir(), "*"), context.temp_allocator)
	packs := make([dynamic]Title_Pack, allocator)
	for path in paths {
		folder := os.is_dir(path)
		if !folder && !strings.has_suffix(path, ".tar") do continue
		manifest := read_manifest(path, context.temp_allocator) or_continue
		tp := read_titlepack(manifest, allocator) or_continue
		if folder && len(tp.bases) > 0 {
			destroy_titlepack(tp, allocator)
			continue
		}
		tp.path = strings.clone(path, allocator)
		tp.locked = !folder && filepath.stem(path) == tile_name(tp.id, tp.version, true)
		inherit_from_bases(&tp, allocator)
		append(&packs, tp)
	}
	slice.sort_by(packs[:], proc(a, b: Title_Pack) -> bool {return a.name < b.name || (a.name == b.name && a.path < b.path)})
	return packs[:]
}

destroy_installed :: proc(packs: []Title_Pack, allocator := context.allocator) {
	for tp in packs do destroy_titlepack(tp, allocator)
	delete(packs, allocator)
}
