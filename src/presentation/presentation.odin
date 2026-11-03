// The presentation host: runs a pack's presentation modules (the entry module, later a match presenter) outside
// rollback, one frame call per display frame. They draw 2D on the host's renderer through the SDL imports.
package presentation

import "../content"
import "../imports"
import "../wasm"

MEMORY_CAP :: 512 << 20
INIT_FUEL :: 200_000_000_000  // fonts, textures and dbs read at start
FRAME_FUEL :: 2_000_000_000

// Starts a module with the SDL imports on sdl, the pack's one SDL table. pack and sdl must outlive it.
start :: proc(engine: wasm.Engine, code: wasm.Module, name: string, pack: ^content.Pack, sdl: ^imports.Sdl_Set) -> (m: ^imports.Module, err: string) {
	if m, err = imports.module_create(engine, pack, name, MEMORY_CAP); err != "" do return
	if err = imports.define_sdl(m.linker, sdl); err == "" do err = imports.module_start(m, code, "ow_init", INIT_FUEL)
	if err != "" {
		imports.module_destroy(m)
		return nil, err
	}
	return m, ""
}

// One display frame: ow_frame(dt, command buffer); then the host puts back the draw state the module changed.
// Packs have no GPU command buffer yet (sdl-gpu-imports), so it is 0. A trap means the module is gone.
frame :: proc(m: ^imports.Module, sdl: ^imports.Sdl_Set, dt: f32) -> (err: string) {
	err = imports.module_call(m, "ow_frame", {wasm.f32_val(dt), wasm.i32_val(0)}, fuel = FRAME_FUEL)
	imports.sdl_reset(sdl)
	return
}
