package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "../src/db"
import "../src/wasm"

// A module linked with the SDK's SQLite reads a value from a pack db that the host serves through content_read.
@(test)
module_queries_a_served_db :: proc(t: ^testing.T) {
	module_path, db_path := "build/db_probe.wasm", "build/db_probe.db"
	command := []string{"vendor/zig/zig", "cc", "-target", "wasm32-wasi", "-Os", "-std=c23", "-mexec-model=reactor",
		"-Isdk/include", "-Ivendor/sqlite", "-o", module_path, "tests/ref/db_probe.c", "build/sdk/libow_db.a"}
	state, _, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	if !testing.expectf(t, err == nil && state.exit_code == 0, "db_probe.c did not build: %s", stderr) do return
	code, _ := os.read_entire_file(module_path, context.temp_allocator)
	fmt.printfln("db_probe.wasm: %d bytes", len(code))

	w, create_err := db.create(db_path, "CREATE TABLE t (key TEXT PRIMARY KEY, value INTEGER);")
	testing.expect_value(t, create_err, "")
	db.insert(&w, "t", "answer", i64(42))
	testing.expect_value(t, db.finish(&w), "")
	served, _ := os.read_entire_file(db_path, context.temp_allocator)
	os.remove(db_path)

	r := rig_create(64 << 20)
	defer rig_destroy(r)
	testing.expect_value(t, wasm.define_func(r.linker, "content_size", {wasm.I32, wasm.I32}, {wasm.I32}, served_size, &served), "")
	testing.expect_value(t, wasm.define_func(r.linker, "content_read", {wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, served_read, &served), "")
	m, compile_err := wasm.compile(r.engine, code)
	if !testing.expect_value(t, compile_err, "") do return
	defer wasm.module_destroy(m)
	inst, inst_err := wasm.instantiate(r.linker, r.store, m)
	if !testing.expect_value(t, inst_err, "") do return
	got := []wasm.Val{{}}
	testing.expect_value(t, wasm.call(r.store, inst, "probe", nil, got), "")
	testing.expect_value(t, got[0].of.i32, 42)
}

// The one file x.db; the path is (pointer, length) in the module's memory.
@(private = "file")
served_file :: proc "contextless" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val) -> (file: []byte, memory: []byte, ok: bool) {
	memory = wasm.caller_memory(caller)
	path := wasm.span(memory, u32(args[0].of.i32), u32(args[1].of.i32)) or_return
	return (^[]byte)(env)^, memory, string(path) == "x.db"
}

@(private = "file")
served_size :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	file, _, ok := served_file(env, caller, args)
	results[0] = wasm.i32_val(ok ? i32(len(file)) : -1)
	return nil
}

@(private = "file")
served_read :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	file, memory, ok := served_file(env, caller, args)
	offset := int(u32(args[2].of.i32))
	buf, in_bounds := wasm.span(memory, u32(args[3].of.i32), u32(args[4].of.i32))
	if !ok || !in_bounds || offset > len(file) {
		results[0] = wasm.i32_val(-1)
		return nil
	}
	results[0] = wasm.i32_val(i32(copy(buf, file[offset:])))
	return nil
}
