// wasmtime C API (v49), only the calls the host uses. Layouts from vendor/wasmtime/include.
package wasm

import "core:c"

// (hole windows-build :tags tools) no Windows build: no wasmtime import here, download-deps.sh and build.sh are bash-only and fetch no Windows libs (wasmtime, clay, sqlite, SDL3, SDL3_ttf).
when ODIN_OS == .Linux {
	foreign import lib {"../../vendor/wasmtime/lib/libwasmtime.a", "system:pthread", "system:dl", "system:m"}
} else when ODIN_OS == .Darwin {
	foreign import lib {"../../vendor/wasmtime/lib/libwasmtime.a", "system:System.framework"}
}

C_Engine :: struct {}
C_Config :: struct {}
C_Store :: struct {}
C_Context :: struct {}
C_Module :: struct {}
C_Linker :: struct {}
C_Error :: struct {}
C_Trap :: struct {}
C_Caller :: struct {}
C_Functype :: struct {}
C_Valtype :: struct {}
C_Memorytype :: struct {}

Byte_Vec :: struct {
	size: c.size_t,
	data: [^]u8,
}

Valtype_Vec :: struct {
	size: c.size_t,
	data: [^]^C_Valtype,
}

C_Instance :: struct {
	store_id: u64,
	private:  c.size_t,
}

C_Func :: struct {
	store_id: u64,
	private:  rawptr,
}

C_Memory :: struct {
	inner:    struct {
		store_id: u64,
		private1: u32,
	},  // padded to 16 bytes, as in C
	private2: u32,
}

C_Global :: struct {
	store_id: u64,
	private1: u32,
	private2: u32,
	private3: u32,
}

EXTERN_FUNC :: 0
EXTERN_GLOBAL :: 1
EXTERN_MEMORY :: 3

C_Extern :: struct {
	kind: u8,
	of:   struct #raw_union {
		func:   C_Func,
		global: C_Global,
		memory: C_Memory,
		size:   [24]u8,
	},
}

I32 :: 0
I64 :: 1
F32 :: 2
F64 :: 3

Val :: struct {
	kind: u8,
	of:   struct #raw_union {
		i32:  i32,
		i64:  i64,
		f32:  f32,
		f64:  f64,
		size: [24]u8,
	},
}

Callback :: #type proc "c" (env: rawptr, caller: ^C_Caller, args: [^]Val, nargs: c.size_t, results: [^]Val, nresults: c.size_t) -> ^C_Trap

@(default_calling_convention = "c")
foreign lib {
	wasm_config_new :: proc() -> ^C_Config ---
	wasm_engine_new_with_config :: proc(config: ^C_Config) -> ^C_Engine ---
	wasm_engine_delete :: proc(e: ^C_Engine) ---
	wasm_byte_vec_delete :: proc(v: ^Byte_Vec) ---
	wasm_valtype_new :: proc(kind: u8) -> ^C_Valtype ---
	wasm_valtype_vec_new :: proc(out: ^Valtype_Vec, size: c.size_t, data: [^]^C_Valtype) ---
	wasm_functype_new :: proc(params, results: ^Valtype_Vec) -> ^C_Functype ---
	wasm_functype_delete :: proc(t: ^C_Functype) ---
	wasm_memorytype_delete :: proc(t: ^C_Memorytype) ---
	wasm_trap_message :: proc(trap: ^C_Trap, out: ^Byte_Vec) ---
	wasm_trap_delete :: proc(trap: ^C_Trap) ---
	wasmtime_trap_new :: proc(message: [^]u8, len: c.size_t) -> ^C_Trap ---

	wasmtime_config_consume_fuel_set :: proc(config: ^C_Config, on: bool) ---
	wasmtime_config_cranelift_nan_canonicalization_set :: proc(config: ^C_Config, on: bool) ---
	wasmtime_config_wasm_multi_memory_set :: proc(config: ^C_Config, on: bool) ---

	wasmtime_store_new :: proc(engine: ^C_Engine, data: rawptr, finalizer: rawptr) -> ^C_Store ---
	wasmtime_store_context :: proc(store: ^C_Store) -> ^C_Context ---
	wasmtime_store_delete :: proc(store: ^C_Store) ---
	wasmtime_context_set_fuel :: proc(ctx: ^C_Context, fuel: u64) -> ^C_Error ---

	wasmtime_wat2wasm :: proc(wat: [^]u8, wat_len: c.size_t, out: ^Byte_Vec) -> ^C_Error ---
	wasmtime_module_new :: proc(engine: ^C_Engine, code: [^]u8, len: c.size_t, out: ^^C_Module) -> ^C_Error ---
	wasmtime_module_delete :: proc(m: ^C_Module) ---
	wasmtime_module_serialize :: proc(m: ^C_Module, out: ^Byte_Vec) -> ^C_Error ---
	wasmtime_module_deserialize :: proc(engine: ^C_Engine, bytes: [^]u8, len: c.size_t, out: ^^C_Module) -> ^C_Error ---

	wasmtime_linker_new :: proc(engine: ^C_Engine) -> ^C_Linker ---
	wasmtime_linker_delete :: proc(linker: ^C_Linker) ---
	wasmtime_linker_define :: proc(linker: ^C_Linker, ctx: ^C_Context, module: [^]u8, module_len: c.size_t, name: [^]u8, name_len: c.size_t, item: ^C_Extern) -> ^C_Error ---
	wasmtime_linker_define_func :: proc(linker: ^C_Linker, module: [^]u8, module_len: c.size_t, name: [^]u8, name_len: c.size_t, type: ^C_Functype, cb: Callback, data: rawptr, finalizer: rawptr) -> ^C_Error ---
	wasmtime_linker_instantiate :: proc(linker: ^C_Linker, ctx: ^C_Context, module: ^C_Module, out: ^C_Instance, trap: ^^C_Trap) -> ^C_Error ---

	wasmtime_instance_export_get :: proc(ctx: ^C_Context, instance: ^C_Instance, name: [^]u8, name_len: c.size_t, out: ^C_Extern) -> bool ---
	wasmtime_func_call :: proc(ctx: ^C_Context, func: ^C_Func, args: [^]Val, nargs: c.size_t, results: [^]Val, nresults: c.size_t, trap: ^^C_Trap) -> ^C_Error ---
	wasmtime_memorytype_new :: proc(min: u64, max_present: bool, max: u64, is_64: bool, shared: bool, page_size_log2: u8, out: ^^C_Memorytype) -> ^C_Error ---
	wasmtime_memory_new :: proc(ctx: ^C_Context, type: ^C_Memorytype, out: ^C_Memory) -> ^C_Error ---
	wasmtime_memory_data :: proc(ctx: ^C_Context, memory: ^C_Memory) -> [^]u8 ---
	wasmtime_memory_data_size :: proc(ctx: ^C_Context, memory: ^C_Memory) -> c.size_t ---
	wasmtime_global_get :: proc(ctx: ^C_Context, global: ^C_Global, out: ^Val) ---
	wasmtime_global_set :: proc(ctx: ^C_Context, global: ^C_Global, val: ^Val) -> ^C_Error ---

	wasmtime_error_message :: proc(err: ^C_Error, out: ^Byte_Vec) ---
	wasmtime_error_delete :: proc(err: ^C_Error) ---
}

#assert(size_of(C_Instance) == 16)
#assert(size_of(C_Func) == 16)
#assert(size_of(C_Global) == 24)
#assert(size_of(C_Memory) == 24)
#assert(size_of(C_Extern) == 32)
#assert(size_of(Val) == 32)
