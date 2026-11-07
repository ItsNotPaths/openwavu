// Params: pack.toml declares them, the lobby host picks the exposed ones; values travel as "name=value name=value".
package titlepack

import "core:fmt"
import "core:math"
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

// The [params.x] tables, sorted by name; views into top's result, in the temp allocator. kind and default are required;
// a number's default must sit inside min and max.
@(private)
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

// Whether value is one the param may take: a finite number inside its range, and one of its values when it lists any.
param_allows :: proc(param: Param, value: string) -> bool {
	if param.kind == .Number {
		number := strconv.parse_f64(value) or_return
		if math.is_nan(number) || math.is_inf(number) || number < param.min || number > param.max do return false
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

// "stage=dragons_nest rounds=5" -> the values as text; ok is false for a pair with no name or no `=`.
parse_params :: proc(text: string, allocator := context.allocator) -> (params: map[string]string, ok: bool) {
	params = make(map[string]string, allocator)
	for pair in strings.fields(text, context.temp_allocator) {
		name, eq, value := strings.partition(pair, "=")
		if name == "" || eq == "" {
			params_destroy(&params, allocator)
			return nil, false
		}
		params[strings.clone(name, allocator)] = strings.clone(value, allocator)
	}
	return params, true
}

// parse_params' inverse.
params_text :: proc(params: map[string]string, allocator := context.allocator) -> string {
	pairs := make([dynamic]string, context.temp_allocator)
	for name, value in params do append(&pairs, strings.concatenate({name, "=", value}, context.temp_allocator))
	return strings.join(pairs[:], " ", allocator)
}

params_clone :: proc(params: map[string]string, allocator := context.allocator) -> map[string]string {
	copied := make(map[string]string, allocator)
	for name, value in params do copied[strings.clone(name, allocator)] = strings.clone(value, allocator)
	return copied
}

params_destroy :: proc(params: ^map[string]string, allocator := context.allocator) {
	for name, value in params {
		delete(name, allocator)
		delete(value, allocator)
	}
	delete(params^)
}
