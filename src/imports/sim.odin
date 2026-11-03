package imports

import "base:runtime"
import "core:strconv"
import "../wasm"

// ow_event kinds (openwavu.h).
Event_Kind :: enum u32 {
	KO        = 1,  // a = the side that fell
	Round_End = 2,  // a = the winner side, -1 for a draw
	Match_End = 3,  // a = the winner side, -1 for a draw
}

Event :: struct {
	kind: Event_Kind,
	a, b: i32,
}

// What a sim module's imports serve, and what they collect.
Sim_Inputs :: struct {
	params:   map[string]string,  // the final values of the match, as text
	loadouts: [2][]byte,
	seed:     u64,
	events:   [dynamic]Event,  // reported this match, in order
}

// param, param_text, loadout, match_seed and event. `inputs` must outlive the linker's instances.
define_sim :: proc(l: wasm.Linker, inputs: ^Sim_Inputs) -> (err: string) {
	if err = wasm.define_func(l, "param", {wasm.I32, wasm.I32, wasm.F64}, {wasm.F64}, param, inputs); err != "" do return
	if err = wasm.define_func(l, "param_text", {wasm.I32, wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, param_text, inputs); err != "" do return
	if err = wasm.define_func(l, "loadout", {wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, loadout, inputs); err != "" do return
	if err = wasm.define_func(l, "match_seed", {}, {wasm.I64}, match_seed, inputs); err != "" do return
	return wasm.define_func(l, "event", {wasm.I32, wasm.I32, wasm.I32}, {}, event, inputs)
}

// param(name, name_len, fallback) -> the final value as a number, or the fallback for a name with no number.
@(private = "file")
param :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	inputs := (^Sim_Inputs)(env)
	value := args[2].of.f64
	if name, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32)); ok {
		if number, is_number := strconv.parse_f64(inputs.params[string(name)] or_else ""); is_number do value = number
	}
	results[0] = wasm.f64_val(value)
	return nil
}

// param_text(name, name_len, buf, cap) -> the length of the final value, or -1 for a name with no value; copies as much as fits.
@(private = "file")
param_text :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	inputs := (^Sim_Inputs)(env)
	memory := wasm.caller_memory(caller)
	name, name_ok := wasm.span(memory, u32(args[0].of.i32), u32(args[1].of.i32))
	buf, buf_ok := wasm.span(memory, u32(args[2].of.i32), u32(args[3].of.i32))
	if !name_ok || !buf_ok do return wasm.trap("ow_param_text: an argument is outside the module's memory")
	value, has := inputs.params[string(name)]
	copy(buf, value)
	results[0] = wasm.i32_val(has ? i32(len(value)) : -1)
	return nil
}

// loadout(side, buf, cap) -> the loadout's length, or -1; copies as much as fits.
@(private = "file")
loadout :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	inputs := (^Sim_Inputs)(env)
	results[0] = wasm.i32_val(-1)
	side := u32(args[0].of.i32)
	buf, ok := wasm.span(wasm.caller_memory(caller), u32(args[1].of.i32), u32(args[2].of.i32))
	if side >= len(inputs.loadouts) || !ok do return nil
	copy(buf, inputs.loadouts[side])
	results[0] = wasm.i32_val(i32(len(inputs.loadouts[side])))
	return nil
}

@(private = "file")
match_seed :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	results[0] = wasm.i64_val(i64((^Sim_Inputs)(env).seed))
	return nil
}

@(private = "file")
event :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	inputs := (^Sim_Inputs)(env)
	switch kind := Event_Kind(u32(args[0].of.i32)); kind {
	case .KO, .Round_End, .Match_End:
		append(&inputs.events, Event{kind, args[1].of.i32, args[2].of.i32})
	}
	return nil
}
