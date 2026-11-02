// WASM modules for the host: one engine, a store per match, modules compiled once and cached by hash.
// NaN canonicalization keeps floats identical on every machine; fuel stops a module that hangs.
package wasm

import "core:slice"
import "core:strings"

Engine :: struct {
	handle: ^C_Engine,
}

Store :: struct {
	handle: ^C_Store,
	ctx:    ^C_Context,
}

Module :: struct {
	handle: ^C_Module,
}

Linker :: struct {
	handle: ^C_Linker,
}

Instance :: struct {
	handle: C_Instance,
}

Memory :: struct {
	handle: C_Memory,
}

Global :: struct {
	handle: C_Global,
}

PAGE :: 65536

engine_create :: proc() -> Engine {
	config := wasm_config_new()
	wasmtime_config_cranelift_nan_canonicalization_set(config, true)
	wasmtime_config_consume_fuel_set(config, true)
	return {wasm_engine_new_with_config(config)}
}

engine_destroy :: proc(e: Engine) {
	wasm_engine_delete(e.handle)
}

// memory_cap: the most bytes any one module memory may grow to; memory.grow past it returns -1.
store_create :: proc(e: Engine, memory_cap: i64) -> Store {
	s := wasmtime_store_new(e.handle, nil, nil)
	wasmtime_store_limiter(s, memory_cap, -1, -1, -1, -1)  // -1: no limit
	return {s, wasmtime_store_context(s)}
}

store_destroy :: proc(s: Store) {
	wasmtime_store_delete(s.handle)
}

// Instructions the store may run before calls trap.
set_fuel :: proc(s: Store, fuel: u64) -> (err: string) {
	return take_error(wasmtime_context_set_fuel(s.ctx, fuel))
}

compile :: proc(e: Engine, code: []byte) -> (m: Module, err: string) {
	err = take_error(wasmtime_module_new(e.handle, raw_data(code), len(code), &m.handle))
	return
}

// Machine code for this engine and CPU; load it back with deserialize. Cache it by the module hash.
serialize :: proc(m: Module, allocator := context.allocator) -> (code: []byte, err: string) {
	v: Byte_Vec
	if err = take_error(wasmtime_module_serialize(m.handle, &v)); err != "" do return
	defer wasm_byte_vec_delete(&v)
	return slice.clone(v.data[:v.size], allocator), ""  // wasmtime owns v
}

deserialize :: proc(e: Engine, code: []byte) -> (m: Module, err: string) {
	err = take_error(wasmtime_module_deserialize(e.handle, raw_data(code), len(code), &m.handle))
	return
}

module_destroy :: proc(m: Module) {
	wasmtime_module_delete(m.handle)
}

wat_to_wasm :: proc(wat: string, allocator := context.allocator) -> (code: []byte, err: string) {
	v: Byte_Vec
	if err = take_error(wasmtime_wat2wasm(raw_data(wat), len(wat), &v)); err != "" do return
	defer wasm_byte_vec_delete(&v)
	return slice.clone(v.data[:v.size], allocator), ""
}

linker_create :: proc(e: Engine) -> Linker {
	return {wasmtime_linker_new(e.handle)}
}

linker_destroy :: proc(l: Linker) {
	wasmtime_linker_delete(l.handle)
}

// A host function under module "openwavu". params and results are I32, I64, F32 or F64.
define_func :: proc(l: Linker, name: string, params, results: []u8, cb: Callback, data: rawptr = nil) -> (err: string) {
	ps, rs: Valtype_Vec
	wasm_valtype_vec_new(&ps, len(params), valtypes(params))
	wasm_valtype_vec_new(&rs, len(results), valtypes(results))
	type := wasm_functype_new(&ps, &rs)
	defer wasm_functype_delete(type)
	return take_error(wasmtime_linker_define_func(l.handle, raw_data(HOST), len(HOST), raw_data(name), len(name), type, cb, data, nil))
}

// Instantiates, then runs the module's _initialize (a WASI reactor's libc setup) when it has one.
instantiate :: proc(l: Linker, s: Store, m: Module) -> (inst: Instance, err: string) {
	trap: ^C_Trap
	if err = take_error(wasmtime_linker_instantiate(l.handle, s.ctx, m.handle, &inst.handle, &trap)); err != "" do return
	if err = take_trap(trap); err != "" do return
	if has_func(s, inst, "_initialize") do err = call(s, inst, "_initialize")
	return
}

has_func :: proc(s: Store, inst: Instance, name: string) -> bool {
	_, ok := export_of(s, inst, name, EXTERN_FUNC)
	return ok
}

// Calls an exported function. A trap (out of fuel, out of bounds, ...) comes back as err.
call :: proc(s: Store, inst: Instance, name: string, args: []Val = nil, results: []Val = nil) -> (err: string) {
	item, ok := export_of(s, inst, name, EXTERN_FUNC)
	if !ok do return strings.concatenate({"no exported function ", name}, context.temp_allocator)
	trap: ^C_Trap
	if err = take_error(wasmtime_func_call(s.ctx, &item.of.func, raw_data(args), len(args), raw_data(results), len(results), &trap)); err != "" do return
	return take_trap(trap)
}

export_memory :: proc(s: Store, inst: Instance, name: string) -> (m: Memory, ok: bool) {
	item := export_of(s, inst, name, EXTERN_MEMORY) or_return
	return {item.of.memory}, true
}

export_global :: proc(s: Store, inst: Instance, name: string) -> (g: Global, ok: bool) {
	item := export_of(s, inst, name, EXTERN_GLOBAL) or_return
	return {item.of.global}, true
}

// Inside a host function: the calling module's exported "memory"; nil if it has none. Valid until the memory grows.
caller_memory :: proc "contextless" (caller: ^C_Caller) -> []byte {
	item: C_Extern
	name := "memory"
	if !wasmtime_caller_export_get(caller, raw_data(name), len(name), &item) || item.kind != EXTERN_MEMORY do return nil
	ctx := wasmtime_caller_context(caller)
	return wasmtime_memory_data(ctx, &item.of.memory)[:wasmtime_memory_data_size(ctx, &item.of.memory)]
}

// The bytes [offset, offset + size) of memory; ok is false when any of them is outside it.
span :: proc "contextless" (memory: []byte, offset, size: u32) -> (bytes: []byte, ok: bool) {
	if u64(offset) + u64(size) > u64(len(memory)) do return nil, false
	return memory[offset:][:size], true
}

// The memory's bytes. Valid until the memory grows.
bytes :: proc(s: Store, m: Memory) -> []byte {
	m := m
	return wasmtime_memory_data(s.ctx, &m.handle)[:wasmtime_memory_data_size(s.ctx, &m.handle)]
}

global_get :: proc(s: Store, g: Global) -> (v: Val) {
	g := g
	wasmtime_global_get(s.ctx, &g.handle, &v)
	return v
}

global_set :: proc(s: Store, g: Global, v: Val) -> (err: string) {
	g, v := g, v
	return take_error(wasmtime_global_set(s.ctx, &g.handle, &v))
}

i32_val :: proc "contextless" (v: i32) -> (out: Val) {out.kind = I32; out.of.i32 = v; return}
f32_val :: proc "contextless" (v: f32) -> (out: Val) {out.kind = F32; out.of.f32 = v; return}
i64_val :: proc "contextless" (v: i64) -> (out: Val) {out.kind = I64; out.of.i64 = v; return}
f64_val :: proc "contextless" (v: f64) -> (out: Val) {out.kind = F64; out.of.f64 = v; return}

// Host functions return this to stop the module with a message.
trap :: proc "contextless" (message: string) -> ^C_Trap {
	return wasmtime_trap_new(raw_data(message), len(message))
}

@(private = "file")
HOST := "openwavu"

@(private = "file")
export_of :: proc(s: Store, inst: Instance, name: string, kind: u8) -> (item: C_Extern, ok: bool) {
	inst := inst
	ok = wasmtime_instance_export_get(s.ctx, &inst.handle, raw_data(name), len(name), &item) && item.kind == kind
	return
}

@(private = "file")
valtypes :: proc(kinds: []u8) -> [^]^C_Valtype {
	out := make([]^C_Valtype, len(kinds), context.temp_allocator)
	for k, i in kinds do out[i] = wasm_valtype_new(k)
	return raw_data(out)
}

@(private = "file")
take_error :: proc(e: ^C_Error) -> string {
	if e == nil do return ""
	defer wasmtime_error_delete(e)
	v: Byte_Vec
	wasmtime_error_message(e, &v)
	defer wasm_byte_vec_delete(&v)
	return strings.clone(string(v.data[:v.size]), context.temp_allocator)
}

@(private = "file")
take_trap :: proc(t: ^C_Trap) -> string {
	if t == nil do return ""
	defer wasm_trap_delete(t)
	v: Byte_Vec
	wasm_trap_message(t, &v)
	defer wasm_byte_vec_delete(&v)
	return strings.trim_right_null(strings.clone(string(v.data[:v.size]), context.temp_allocator))
}
