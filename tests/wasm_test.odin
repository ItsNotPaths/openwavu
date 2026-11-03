package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "../src/wasm"

// A module with its own memory, a host import and a global: each step adds 1 to its counter through the host.
COUNTER_WAT :: `(module
	(import "openwavu" "add1" (func $add1 (param i32) (result i32)))
	(memory (export "memory") 1)
	(global (export "steps") (mut i32) (i32.const 0))
	(func (export "step")
		(i32.store (i32.const 0) (call $add1 (i32.load (i32.const 0))))
		(global.set 0 (i32.add (global.get 0) (i32.const 1)))))`

// Grows its memory by n pages; the old page count, or -1.
GROW_WAT :: `(module
	(memory (export "memory") 1)
	(func (export "grow") (param i32) (result i32) (memory.grow (local.get 0))))`

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

rig_create :: proc(memory_cap: i64 = 4 * wasm.PAGE) -> (r: Rig) {
	r.engine = wasm.engine_create()
	r.store = wasm.store_create(r.engine, memory_cap)
	r.linker = wasm.linker_create(r.engine)
	wasm.set_fuel(r.store, 1_000_000)
	return r
}

rig_destroy :: proc(r: Rig) {
	wasm.linker_destroy(r.linker)
	wasm.store_destroy(r.store)
	wasm.engine_destroy(r.engine)
}

// A pack module from C in tests/ref, built as a pack builds one, against the SDK and SDL headers. extra: more sources and libs.
build_module :: proc(t: ^testing.T, source: string, extra: ..string) -> (code: []byte, ok: bool) {
	out := fmt.tprintf("build/%s.wasm", filepath.stem(source))
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "vendor/zig/zig", "cc", "-target", "wasm32-wasi", "-O2", "-std=c23", "-mexec-model=reactor", "-Isdk/include",
		"-Ivendor/sdl3/include", "-Ivendor/sdl3_ttf/include", "-Ivendor/sqlite", "-Wl,--import-symbols", "-o", out, source)
	append(&command, ..extra)
	state, _, stderr, err := os.process_exec({command = command[:]}, context.temp_allocator)
	if !testing.expectf(t, err == nil && state.exit_code == 0, "%s did not build: %s", source, stderr) do return
	read_err: os.Error
	code, read_err = os.read_entire_file(out, context.temp_allocator)
	return code, read_err == nil
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
host_reads_and_writes_module_state :: proc(t: ^testing.T) {
	r := rig_create()
	defer rig_destroy(r)
	testing.expect_value(t, wasm.define_func(r.linker, "add1", {wasm.I32}, {wasm.I32}, add1), "")
	inst, ok := load(t, r, COUNTER_WAT)
	if !ok do return
	memory, has_memory := wasm.export_memory(r.store, inst, "memory")
	steps, has_steps := wasm.export_global(r.store, inst, "steps")
	if !testing.expect(t, has_memory && has_steps) do return

	(^i32)(raw_data(wasm.bytes(r.store, memory)))^ = 41
	testing.expect_value(t, wasm.call(r.store, inst, "step"), "")
	testing.expect_value(t, wasm.call(r.store, inst, "step"), "")
	testing.expect_value(t, (^i32)(raw_data(wasm.bytes(r.store, memory)))^, 43)
	testing.expect_value(t, wasm.global_get(r.store, steps).of.i32, 2)
	testing.expect_value(t, wasm.global_set(r.store, steps, wasm.i32_val(0)), "")
	testing.expect_value(t, wasm.global_get(r.store, steps).of.i32, 0)
}

@(test)
modules_do_not_share_memory :: proc(t: ^testing.T) {
	r := rig_create()
	defer rig_destroy(r)
	testing.expect_value(t, wasm.define_func(r.linker, "add1", {wasm.I32}, {wasm.I32}, add1), "")
	a, ok_a := load(t, r, COUNTER_WAT)
	b, ok_b := load(t, r, COUNTER_WAT)
	if !ok_a || !ok_b do return
	testing.expect_value(t, wasm.call(r.store, a, "step"), "")
	memory_a, _ := wasm.export_memory(r.store, a, "memory")
	memory_b, _ := wasm.export_memory(r.store, b, "memory")
	testing.expect_value(t, (^i32)(raw_data(wasm.bytes(r.store, memory_a)))^, 1)
	testing.expect_value(t, (^i32)(raw_data(wasm.bytes(r.store, memory_b)))^, 0)
}

@(test)
memory_stops_at_the_cap :: proc(t: ^testing.T) {
	r := rig_create()
	defer rig_destroy(r)
	inst, ok := load(t, r, GROW_WAT)
	if !ok do return
	got := []wasm.Val{{}}
	testing.expect_value(t, wasm.call(r.store, inst, "grow", {wasm.i32_val(3)}, got), "")
	testing.expect_value(t, got[0].of.i32, 1)
	testing.expect_value(t, wasm.call(r.store, inst, "grow", {wasm.i32_val(1)}, got), "")
	testing.expect_value(t, got[0].of.i32, -1)
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
