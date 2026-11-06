// The sim host: runs a title pack's sim module, one instance per match. The module owns its memory; a snapshot is the
// state range it exports. Bit exact to the game with the stock TK5 sim.
package sim

import "core:hash/xxhash"
import "core:slice"
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
	state_at, state_size: u32,  // from ow_sim_state and ow_sim_state_size, read once after init
}

MEMORY_CAP :: 512 << 20
INIT_FUEL :: 200_000_000_000  // loading two fighters from the db
STEP_FUEL :: 2_000_000_000

// A new instance of the sim module, inited for a match. params and loadouts are copied.
create :: proc(engine: wasm.Engine, module: wasm.Module, pack: ^content.Pack, params: map[string]string, loadouts: [2][]byte, seed: u64) -> (w: ^World, err: string) {
	w = new(World)
	w.inputs.seed = seed
	w.inputs.events = make([dynamic]imports.Event)  // the event import grows it with this allocator
	w.inputs.params = imports.params_clone(params)
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
	at, size := []wasm.Val{{}}, []wasm.Val{{}}
	if err = imports.module_call(w.module, "ow_sim_state", nil, at, STEP_FUEL); err != "" do return
	if err = imports.module_call(w.module, "ow_sim_state_size", nil, size, STEP_FUEL); err != "" do return
	w.state_at, w.state_size = u32(at[0].of.i32), u32(size[0].of.i32)
	if _, inside := wasm.span(wasm.bytes(w.module.store, w.memory), w.state_at, w.state_size); !inside do return "the sim state is outside the module's memory"
	return
}

destroy :: proc(w: ^World) {
	if w.module != nil do imports.module_destroy(w.module)
	imports.params_destroy(&w.inputs.params)
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

// The module's state: its bytes now, valid until memory grows.
@(private = "file")
state :: proc(w: ^World) -> []byte {
	return wasm.bytes(w.module.store, w.memory)[w.state_at:][:w.state_size]
}

snapshot_size :: proc(w: ^World) -> int {
	return int(w.state_size)
}

// Copies the state into snapshot, snapshot_size bytes.
save :: proc(w: ^World, snapshot: []byte) {
	copy(snapshot, state(w))
}

restore :: proc(w: ^World, snapshot: []byte) {
	copy(state(w), snapshot)
}

// The hash both players compare: equal states give equal hashes.
state_hash :: proc(w: ^World) -> u64 {
	return xxhash.XXH3_64(state(w))
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
