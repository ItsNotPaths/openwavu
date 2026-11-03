// The sim host: runs a title pack's sim module, one instance per match. The module owns its memory; a snapshot is that
// memory plus its globals. Bit exact to the game with the stock TK5 sim.
package sim

import "core:slice"
import "core:strings"
import "../content"
import "../imports"
import "../wasm"

Input :: struct {
	pad: u32,  // OW_PAD_* bits (sdk/include/openwavu.h), the same in every Tekken
}

World :: struct {
	store:    wasm.Store,
	linker:   wasm.Linker,
	instance: wasm.Instance,
	memory:   wasm.Memory,
	inputs:   imports.Sim_Inputs,
}

@(private = "file")
LOG_NAME := "sim"
MEMORY_CAP :: 512 << 20
INIT_FUEL :: 200_000_000_000  // loading two fighters from the db
STEP_FUEL :: 2_000_000_000

// A new instance of the sim module, inited for a match. params and loadouts are copied.
create :: proc(engine: wasm.Engine, module: wasm.Module, pack: ^content.Pack, params: map[string]f64, loadouts: [2][]byte, seed: u64) -> (w: ^World, err: string) {
	w = new(World)
	w.store = wasm.store_create(engine, MEMORY_CAP)
	w.linker = wasm.linker_create(engine)
	w.inputs.seed = seed
	for name, value in params do w.inputs.params[strings.clone(name)] = value
	for loadout, side in loadouts do w.inputs.loadouts[side] = slice.clone(loadout)
	defer if err != "" {
		destroy(w)
		w = nil
	}
	if err = imports.define_content(w.linker, pack); err != "" do return
	if err = imports.define_log(w.linker, &LOG_NAME); err != "" do return
	if err = imports.define_sim(w.linker, &w.inputs); err != "" do return
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
	for name in w.inputs.params do delete(name)
	delete(w.inputs.params)
	for loadout in w.inputs.loadouts do delete(loadout)
	delete(w.inputs.events)
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
