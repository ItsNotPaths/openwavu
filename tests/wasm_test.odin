package tests

import "core:testing"
import "../src/wasm"

// A seam-shaped module: shared world, a host import, its own memory and a global.
SEAM_WAT :: `(module
	(import "openwavu" "world" (memory 1 1))
	(import "openwavu" "add1" (func $add1 (param i32) (result i32)))
	(memory $own (export "private") 1)
	(global (export "steps") (mut i32) (i32.const 0))
	(func (export "step")
		(i32.store (i32.const 0) (call $add1 (i32.load (i32.const 0))))
		(i32.store $own (i32.const 0) (i32.add (i32.load $own (i32.const 0)) (i32.const 1)))
		(global.set 0 (i32.add (global.get 0) (i32.const 1)))))`

READER_WAT :: `(module
	(import "openwavu" "world" (memory 1 1))
	(func (export "read") (result i32) (i32.load (i32.const 0))))`

// NaN with a payload, plus 1: the hardware keeps the payload unless the engine canonicalizes.
NAN_WAT :: `(module (func (export "nan") (result i32)
	(i32.reinterpret_f32 (f32.add (f32.reinterpret_i32 (i32.const 0x7fa00001)) (f32.const 1)))))`

SPIN_WAT :: `(module (func (export "spin") (loop $l (br $l))))`

add1 :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	results[0].kind = wasm.I32
	results[0].of.i32 = args[0].of.i32 + 1
	return nil
}

Rig :: struct {
	engine: wasm.Engine,
	store:  wasm.Store,
	linker: wasm.Linker,
}

rig_create :: proc() -> (r: Rig) {
	r.engine = wasm.engine_create()
	r.store = wasm.store_create(r.engine)
	r.linker = wasm.linker_create(r.engine)
	wasm.set_fuel(r.store, 1_000_000)
	return r
}

rig_destroy :: proc(r: Rig) {
	wasm.linker_destroy(r.linker)
	wasm.store_destroy(r.store)
	wasm.engine_destroy(r.engine)
}

load :: proc(t: ^testing.T, r: Rig, wat: string) -> (inst: wasm.Instance, ok: bool) {
	code, err := wasm.wat_to_wasm(wat, context.temp_allocator)
	if !testing.expect_value(t, err, "") do return
	m: wasm.Module
	m, err = wasm.compile(r.engine, code)
	if !testing.expect_value(t, err, "") do return
	defer wasm.module_destroy(m)
	inst, err = wasm.instantiate(r.linker, r.store, m)
	return inst, testing.expect_value(t, err, "")
}

@(test)
modules_share_the_world :: proc(t: ^testing.T) {
	r := rig_create()
	defer rig_destroy(r)
	world, err := wasm.define_memory(r.linker, r.store, "world", 1)
	testing.expect_value(t, err, "")
	testing.expect_value(t, wasm.define_func(r.linker, "add1", {wasm.I32}, {wasm.I32}, add1), "")
	seam, ok := load(t, r, SEAM_WAT)
	reader, ok2 := load(t, r, READER_WAT)
	if !ok || !ok2 do return

	(^i32)(raw_data(wasm.bytes(r.store, world)))^ = 41
	testing.expect_value(t, wasm.call(r.store, seam, "step"), "")
	testing.expect_value(t, wasm.call(r.store, seam, "step"), "")
	got := []wasm.Val{{}}
	testing.expect_value(t, wasm.call(r.store, reader, "read", nil, got), "")
	testing.expect_value(t, got[0].of.i32, 43)

	own, has_own := wasm.export_memory(r.store, seam, "private")
	steps, has_steps := wasm.export_global(r.store, seam, "steps")
	testing.expect(t, has_own && has_steps)
	testing.expect_value(t, (^i32)(raw_data(wasm.bytes(r.store, own)))^, 2)
	testing.expect_value(t, wasm.global_get(r.store, steps).of.i32, 2)
	testing.expect_value(t, wasm.global_set(r.store, steps, wasm.i32_val(0)), "")
	testing.expect_value(t, wasm.global_get(r.store, steps).of.i32, 0)
}

@(test)
nans_are_canonical :: proc(t: ^testing.T) {
	r := rig_create()
	defer rig_destroy(r)
	inst, ok := load(t, r, NAN_WAT)
	if !ok do return
	got := []wasm.Val{{}}
	testing.expect_value(t, wasm.call(r.store, inst, "nan", nil, got), "")
	testing.expect_value(t, u32(got[0].of.i32), 0x7fc00000)
}

@(test)
fuel_stops_a_hung_module :: proc(t: ^testing.T) {
	r := rig_create()
	defer rig_destroy(r)
	inst, ok := load(t, r, SPIN_WAT)
	if !ok do return
	testing.expect(t, wasm.call(r.store, inst, "spin") != "", "an endless loop must trap")
}

@(test)
compiled_modules_load_from_cache :: proc(t: ^testing.T) {
	r := rig_create()
	defer rig_destroy(r)
	code, _ := wasm.wat_to_wasm(NAN_WAT, context.temp_allocator)
	m, err := wasm.compile(r.engine, code)
	if !testing.expect_value(t, err, "") do return
	cached, ser_err := wasm.serialize(m, context.temp_allocator)
	wasm.module_destroy(m)
	testing.expect_value(t, ser_err, "")
	back, de_err := wasm.deserialize(r.engine, cached)
	if !testing.expect_value(t, de_err, "") do return
	defer wasm.module_destroy(back)
	inst, inst_err := wasm.instantiate(r.linker, r.store, back)
	testing.expect_value(t, inst_err, "")
	got := []wasm.Val{{}}
	testing.expect_value(t, wasm.call(r.store, inst, "nan", nil, got), "")
	testing.expect_value(t, u32(got[0].of.i32), 0x7fc00000)
}
