// Title pack: one tar (docs/packs.md). At the root: pack.toml (the first entry), the wasm modules and the db or
// db patch; everything else in folders the modules name. pack.toml declares the params; the lobby host may change the
// exposed ones, inside their ranges.
package titlepack

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

Param_Kind :: enum {
	Number,
	Text,
}

// A [params.x] table of pack.toml. Values are text, like the sim reads them.
Param :: struct {
	name:     string,
	kind:     Param_Kind,
	default:  string,
	expose:   bool,      // the lobby host may change it
	min, max: f64,       // numbers only
	values:   []string,  // the only values allowed; empty allows any
}

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

// The [params.x] tables, sorted by name; views into top's result, in the temp allocator. kind and default are required;
// a number's default must sit inside min and max.
@(private = "file")
read_params :: proc(top: Toml_Datum) -> (params: []Param, ok: bool) {
	section := toml_get(top, "params")
	if section.type == .Unknown do return nil, true
	if section.type != .Table do return
	params = make([]Param, section.table.size, context.temp_allocator)
	for &param, index in params {
		entry := section.table.values[index]
		if entry.type != .Table do return
		param.name = string(section.table.keys[index][:section.table.key_lengths[index]])
		switch toml_text(toml_get(entry, "kind")) or_return {
		case "number": param.kind = .Number
		case "text":   param.kind = .Text
		case:          return
		}
		param.default = toml_value_text(toml_get(entry, "default")) or_return
		expose := toml_get(entry, "expose")
		param.expose = expose.type == .Boolean && expose.boolean
		param.min = toml_number(toml_get(entry, "min")) or_else math.inf_f64(-1)
		param.max = toml_number(toml_get(entry, "max")) or_else math.inf_f64(1)
		if list := toml_get(entry, "values"); list.type == .Array {
			values := make([dynamic]string, context.temp_allocator)
			for element in list.array.elements[:list.array.size] do append(&values, toml_value_text(element) or_return)
			param.values = values[:]
		}
		if !param_allows(param, param.default) do return
	}
	slice.sort_by(params, proc(a, b: Param) -> bool {return a.name < b.name})
	return params, true
}

// A string or number datum as text.
@(private = "file")
toml_value_text :: proc(datum: Toml_Datum) -> (text: string, ok: bool) {
	#partial switch datum.type {
	case .String: return toml_text(datum)
	case .Int64:  return fmt.tprint(datum.int64), true
	case .Fp64:   return fmt.tprint(datum.fp64), true
	}
	return
}

@(private = "file")
toml_number :: proc(datum: Toml_Datum) -> (number: f64, ok: bool) {
	#partial switch datum.type {
	case .Int64: return f64(datum.int64), true
	case .Fp64:  return datum.fp64, true
	}
	return
}

// Whether value is one the param may take: a number inside its range, and one of its values when it lists any.
param_allows :: proc(param: Param, value: string) -> bool {
	if param.kind == .Number {
		number := strconv.parse_f64(value) or_return
		if number < param.min || number > param.max do return false
	}
	return len(param.values) == 0 || slice.contains(param.values, value)
}

param_clone :: proc(param: Param, allocator := context.allocator) -> (copied: Param) {
	copied = param
	copied.name = strings.clone(param.name, allocator)
	copied.default = strings.clone(param.default, allocator)
	copied.values = make([]string, len(param.values), allocator)
	for value, i in param.values do copied.values[i] = strings.clone(value, allocator)
	return
}

param_destroy :: proc(param: Param, allocator := context.allocator) {
	delete(param.name, allocator)
	delete(param.default, allocator)
	for value in param.values do delete(value, allocator)
	delete(param.values, allocator)
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

find_param :: proc(params: []Param, name: string) -> (param: Param, found: bool) {
	for p in params do if p.name == name do return p, true
	return
}

// The lobby host's picks over the pack's defaults: every declared param, as text. A pick of a param the pack does not
// declare or expose, or a value it does not allow, refuses the whole set.
resolve_params :: proc(declared: []Param, picks: map[string]string, allocator := context.allocator) -> (final: map[string]string, err: string) {
	for name, value in picks {
		param, found := find_param(declared, name)
		if !found do return nil, fmt.tprintf("the pack has no param %s", name)
		if !param.expose do return nil, fmt.tprintf("the param %s is locked", name)
		if !param_allows(param, value) do return nil, fmt.tprintf("%s=%s is not allowed", name, value)
	}
	final = make(map[string]string, allocator)
	for param in declared do final[strings.clone(param.name, allocator)] = strings.clone(picks[param.name] or_else param.default, allocator)
	return
}

// (hole titlepack-hash :tags titlepack) the lobby hash (manifest hash + final params) is not computed.
lobby_hash :: proc(manifest_hash: [32]u8, final: map[string]string) -> (hash: [32]u8) {
	return {}
}
