package imports

import "core:fmt"
import "core:strings"
import "../content"
import "../wasm"

// A pack module the host runs, in its own store, with the imports every module gets (content, log). The host defines
// its role's imports on linker (sim, SDL), then calls module_start.
Module :: struct {
	name:     string,  // its file, for logs
	store:    wasm.Store,
	linker:   wasm.Linker,
	instance: wasm.Instance,
}

// pack must outlive the module. memory_cap: the most bytes its memory may grow to.
module_create :: proc(engine: wasm.Engine, pack: ^content.Pack, name: string, memory_cap: i64) -> (m: ^Module, err: string) {
	m = new(Module)
	m.name = strings.clone(name)
	m.store = wasm.store_create(engine, memory_cap)
	m.linker = wasm.linker_create(engine)
	if err = define_content(m.linker, pack); err == "" do err = define_log(m.linker, &m.name)
	if err != "" {
		module_destroy(m)
		return nil, err
	}
	return m, ""
}

module_destroy :: proc(m: ^Module) {
	wasm.linker_destroy(m.linker)
	wasm.store_destroy(m.store)
	delete(m.name)
	free(m)
}

// Instantiates the code (running its _initialize), then calls the export init, which returns 0 when the module is
// ready. fuel covers both.
module_start :: proc(m: ^Module, code: wasm.Module, init: string, fuel: u64) -> (err: string) {
	wasm.set_fuel(m.store, fuel)
	if m.instance, err = wasm.instantiate(m.linker, m.store, code); err != "" do return
	result := []wasm.Val{{}}
	if err = wasm.call(m.store, m.instance, init, nil, result); err != "" do return
	if result[0].of.i32 != 0 do return fmt.tprintf("%s: %s returned %d", m.name, init, result[0].of.i32)
	return
}

// Calls an export with fuel for this call alone. A trap (out of fuel, out of bounds) comes back as err.
module_call :: proc(m: ^Module, name: string, args: []wasm.Val = nil, results: []wasm.Val = nil, fuel: u64) -> (err: string) {
	wasm.set_fuel(m.store, fuel)
	return wasm.call(m.store, m.instance, name, args, results)
}
