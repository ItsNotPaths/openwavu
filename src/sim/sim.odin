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
	module: ^imports.Module,
	memory: wasm.Memory,
	inputs: imports.Sim_Inputs,
}

MEMORY_CAP :: 512 << 20
INIT_FUEL :: 200_000_000_000  // loading two fighters from the db
STEP_FUEL :: 2_000_000_000

// A new instance of the sim module, inited for a match. params and loadouts are copied.
create :: proc(engine: wasm.Engine, module: wasm.Module, pack: ^content.Pack, params: map[string]f64, loadouts: [2][]byte, seed: u64) -> (w: ^World, err: string) {
	w = new(World)
	w.inputs.seed = seed
	w.inputs.events = make([dynamic]imports.Event)  // the event import grows it with this allocator
	for name, value in params do w.inputs.params[strings.clone(name)] = value
	for loadout, side in loadouts do w.inputs.loadouts[side] = slice.clone(loadout)
	if err = start(w, engine, module, pack); err != "" {
		destroy(w)
		return nil, err
	}
	return w, ""
}

@(private = "file")
start :: proc(w: ^World, engine: wasm.Engine, module: wasm.Module, pack: ^content.Pack) -> (err: string) {
	if w.module, err = imports.module_create(engine, pack, "sim", MEMORY_CAP); err != "" do return
	if err = imports.define_sim(w.module.linker, &w.inputs); err != "" do return
	if err = imports.module_start(w.module, module, "ow_sim_init", INIT_FUEL); err != "" do return
	has_memory: bool
	if w.memory, has_memory = wasm.export_memory(w.module.store, w.module.instance, "memory"); !has_memory do return "the sim module exports no memory"
	return
}

destroy :: proc(w: ^World) {
	if w.module != nil do imports.module_destroy(w.module)
	for name in w.inputs.params do delete(name)
	delete(w.inputs.params)
	for loadout in w.inputs.loadouts do delete(loadout)
	delete(w.inputs.events)
	free(w)
}

// One sim tick. A trap (out of fuel, out of bounds) ends the match: err says why.
step :: proc(w: ^World, inputs: [2]Input) -> (err: string) {
	return imports.module_call(w.module, "ow_sim_step", {wasm.i32_val(i32(inputs[0].pad)), wasm.i32_val(i32(inputs[1].pad))}, fuel = STEP_FUEL)
}

// A bot's pad for the next tick, from the module's ow_bot_pad. Never call it during a resimulation.
bot_pad :: proc(w: ^World, side: int) -> (input: Input, err: string) {
	result := []wasm.Val{{}}
	err = imports.module_call(w.module, "ow_bot_pad", {wasm.i32_val(i32(side))}, result, STEP_FUEL)
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
view :: proc(w: ^World) -> (bytes: []byte, err: string) {
	at, size := []wasm.Val{{}}, []wasm.Val{{}}
	if err = imports.module_call(w.module, "ow_sim_view", nil, at, STEP_FUEL); err != "" do return
	if err = imports.module_call(w.module, "ow_sim_view_size", nil, size, STEP_FUEL); err != "" do return
	ok: bool
	bytes, ok = wasm.span(wasm.bytes(w.module.store, w.memory), u32(at[0].of.i32), u32(size[0].of.i32))
	return bytes, "" if ok else "the sim view is outside the module's memory"
}
