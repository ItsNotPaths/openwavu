// The sim host: runs a title pack's sim module, one instance per match. The module owns its memory; a snapshot is that
// memory plus its globals. Bit exact to the game with the stock TK5 sim.
package sim

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "../content"
import "../wasm"

Input :: struct {
	pad: u32,  // OW_PAD_* bits (sdk/include/openwavu.h), the same in every Tekken
}

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

World :: struct {
	store:    wasm.Store,
	linker:   wasm.Linker,
	instance: wasm.Instance,
	memory:   wasm.Memory,
	params:   map[string]f64,
	loadouts: [2][]byte,
	seed:     u64,
	events:   [dynamic]Event,  // reported this match, in order
}

MEMORY_CAP :: 512 << 20
INIT_FUEL :: 200_000_000_000  // loading two fighters from the db
STEP_FUEL :: 2_000_000_000

// A new instance of the sim module, inited for a match. params and loadouts are copied.
create :: proc(engine: wasm.Engine, module: wasm.Module, pack: ^content.Pack, params: map[string]f64, loadouts: [2][]byte, seed: u64) -> (w: ^World, err: string) {
	w = new(World)
	w.store = wasm.store_create(engine, MEMORY_CAP)
	w.linker = wasm.linker_create(engine)
	w.seed = seed
	for name, value in params do w.params[strings.clone(name)] = value
	for loadout, side in loadouts do w.loadouts[side] = slice.clone(loadout)
	defer if err != "" {
		destroy(w)
		w = nil
	}
	if err = content.define_imports(w.linker, pack); err != "" do return
	if err = define_imports(w); err != "" do return
	wasm.set_fuel(w.store, INIT_FUEL)  // _initialize and ow_sim_init both run on it
	if w.instance, err = wasm.instantiate(w.linker, w.store, module); err != "" do return
	has_memory: bool
	if w.memory, has_memory = wasm.export_memory(w.store, w.instance, "memory"); !has_memory do return w, "the sim module exports no memory"
	result := []wasm.Val{{}}
	if err = wasm.call(w.store, w.instance, "ow_sim_init", nil, result); err != "" do return
	if result[0].of.i32 != 0 do return w, "the sim module's init failed"
	return w, ""
}

destroy :: proc(w: ^World) {
	wasm.linker_destroy(w.linker)
	wasm.store_destroy(w.store)
	for name in w.params do delete(name)
	delete(w.params)
	for loadout in w.loadouts do delete(loadout)
	delete(w.events)
	free(w)
}

// One sim tick. A trap (out of fuel, out of bounds) ends the match: err says why.
step :: proc(w: ^World, inputs: [2]Input) -> (err: string) {
	wasm.set_fuel(w.store, STEP_FUEL)
	return wasm.call(w.store, w.instance, "ow_sim_step", {wasm.i32_val(i32(inputs[0].pad)), wasm.i32_val(i32(inputs[1].pad))})
}

// A bot's pad for the next tick, from the module's ow_bot_pad. Never call it during a resimulation.
bot_pad :: proc(w: ^World, side: int) -> (input: Input, err: string) {
	wasm.set_fuel(w.store, STEP_FUEL)
	result := []wasm.Val{{}}
	err = wasm.call(w.store, w.instance, "ow_bot_pad", {wasm.i32_val(i32(side))}, result)
	return {u32(result[0].of.i32)}, err
}

// (hole module-snapshot :tags (sim net) :needs (snapshot-range) :sev blocker) no save/restore of the gameplay module's exported mutable range plus its globals.
save :: proc(w: ^World, buf: []byte) -> (size: int) {
	return 0
}

restore :: proc(w: ^World, buf: []byte) -> (ok: bool) {
	return false
}

// The sim view of the last tick, from ow_sim_view: bytes in the module's memory, valid until its next call.
// (hole sim-view :tags (sim game) :needs app-host) the view is not copied into the match presenter (its ow_view import).
view :: proc(w: ^World) -> (bytes: []byte, err: string) {
	at, size := []wasm.Val{{}}, []wasm.Val{{}}
	if err = wasm.call(w.store, w.instance, "ow_sim_view", nil, at); err != "" do return
	if err = wasm.call(w.store, w.instance, "ow_sim_view_size", nil, size); err != "" do return
	ok: bool
	bytes, ok = wasm.span(wasm.bytes(w.store, w.memory), u32(at[0].of.i32), u32(size[0].of.i32))
	return bytes, "" if ok else "the sim view is outside the module's memory"
}

@(private = "file")
define_imports :: proc(w: ^World) -> (err: string) {
	if err = wasm.define_func(w.linker, "param", {wasm.I32, wasm.I32, wasm.F64}, {wasm.F64}, param, w); err != "" do return
	if err = wasm.define_func(w.linker, "loadout", {wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, loadout, w); err != "" do return
	if err = wasm.define_func(w.linker, "match_seed", {}, {wasm.I64}, match_seed, w); err != "" do return
	if err = wasm.define_func(w.linker, "log", {wasm.I32, wasm.I32}, {}, log, w); err != "" do return
	return wasm.define_func(w.linker, "event", {wasm.I32, wasm.I32, wasm.I32}, {}, event, w)
}

// param(name, name_len, fallback) -> the final value, or the fallback for a name with no value.
@(private = "file")
param :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	w := (^World)(env)
	value := args[2].of.f64
	if name, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32)); ok {
		value = w.params[string(name)] or_else value
	}
	results[0] = wasm.f64_val(value)
	return nil
}

// loadout(side, buf, cap) -> the loadout's length, or -1; copies as much as fits.
@(private = "file")
loadout :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	w := (^World)(env)
	results[0] = wasm.i32_val(-1)
	side := u32(args[0].of.i32)
	buf, ok := wasm.span(wasm.caller_memory(caller), u32(args[1].of.i32), u32(args[2].of.i32))
	if side >= len(w.loadouts) || !ok do return nil
	copy(buf, w.loadouts[side])
	results[0] = wasm.i32_val(i32(len(w.loadouts[side])))
	return nil
}

@(private = "file")
match_seed :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	results[0] = wasm.i64_val(i64((^World)(env).seed))
	return nil
}

@(private = "file")
log :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	if message, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32)); ok {
		fmt.eprintln("openwavu: sim:", string(message))
	}
	return nil
}

@(private = "file")
event :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	w := (^World)(env)
	switch kind := Event_Kind(u32(args[0].of.i32)); kind {
	case .KO, .Round_End, .Match_End:
		append(&w.events, Event{kind, args[1].of.i32, args[2].of.i32})
	}
	return nil
}
