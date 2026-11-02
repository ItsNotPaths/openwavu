package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "../src/content"
import "../src/wasm"

// A module linked with the SDK's SQLite reads a value from a pack's db through the host's content imports.
@(test)
module_queries_a_served_db :: proc(t: ^testing.T) {
	module_path :: "build/db_probe.wasm"
	command := []string{"vendor/zig/zig", "cc", "-target", "wasm32-wasi", "-Os", "-std=c23", "-mexec-model=reactor",
		"-Isdk/include", "-Ivendor/sqlite", "-o", module_path, "tests/ref/db_probe.c", "build/sdk/libow_db.a"}
	state, _, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	if !testing.expectf(t, err == nil && state.exit_code == 0, "db_probe.c did not build: %s", stderr) do return
	code, _ := os.read_entire_file(module_path, context.temp_allocator)
	fmt.printfln("db_probe.wasm: %d bytes", len(code))

	tar, written := write_test_pack(t, #procedure)
	if !written do return
	defer os.remove(tar)
	p, opened := content.open_pack(tar)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&p)
	r := rig_create(64 << 20)
	defer rig_destroy(r)
	testing.expect_value(t, content.define_imports(r.linker, &p), "")
	m, compile_err := wasm.compile(r.engine, code)
	if !testing.expect_value(t, compile_err, "") do return
	defer wasm.module_destroy(m)
	inst, inst_err := wasm.instantiate(r.linker, r.store, m)
	if !testing.expect_value(t, inst_err, "") do return
	got := []wasm.Val{{}}
	testing.expect_value(t, wasm.call(r.store, inst, "probe", nil, got), "")
	testing.expect_value(t, got[0].of.i32, 42)
}
