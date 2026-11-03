// The presentation host: runs a pack's presentation modules (the entry module, later a match presenter) outside
// rollback, one frame call per display frame. They draw 2D on the host's renderer through the SDL imports, and may
// send a scene.
package presentation

import sdl "vendor:sdl3"
import "../content"
import "../imports"
import "../render"
import "../wasm"

MEMORY_CAP :: 512 << 20
INIT_FUEL :: 200_000_000_000  // fonts, textures and dbs read at start
FRAME_FUEL :: 2_000_000_000

// What a pack's presentation modules share: its files, its SDL objects, the scene they send and the local pads.
// (hole sdl-per-module :tags (game render) :sev polish) a match presenter's SDL objects live until the pack closes, not the match; each match adds its textures again.
Pack :: struct {
	content: ^content.Pack,
	sdl:     imports.Sdl_Set,
	scene:   imports.Scene_Inbox,
	pads:    [2]u32,  // the host sets them each frame
	gpu:     ^render.Gpu,
}

// renderer: the host's, for the pack's 2D. gpu: the one the scene's assets load on; nil draws no scene.
pack_create :: proc(files: ^content.Pack, renderer: ^sdl.Renderer, gpu: ^render.Gpu = nil) -> (p: ^Pack) {
	p = new(Pack)
	p.content = files
	p.gpu = gpu
	p.sdl = imports.sdl_set_create(renderer)
	p.scene = imports.scene_inbox_create(files)
	return
}

pack_destroy :: proc(p: ^Pack) {
	imports.sdl_set_destroy(&p.sdl)
	imports.scene_inbox_destroy(&p.scene, p.gpu)
	free(p)
}

// A module of the pack with the imports every presentation module gets; define its role's on m.linker, then start it.
// The pack must outlive it.
create :: proc(engine: wasm.Engine, name: string, pack: ^Pack) -> (m: ^imports.Module, err: string) {
	if m, err = imports.module_create(engine, pack.content, name, MEMORY_CAP); err != "" do return
	if err = imports.define_sdl(m.linker, &pack.sdl); err == "" do err = imports.define_scene(m.linker, &pack.scene)
	if err == "" do err = imports.define_pad(m.linker, &pack.pads)
	if err != "" {
		imports.module_destroy(m)
		return nil, err
	}
	return m, ""
}

// Instantiates the code and calls its ow_init.
start :: proc(m: ^imports.Module, code: wasm.Module) -> (err: string) {
	return imports.module_start(m, code, "ow_init", INIT_FUEL)
}

// One display frame: ow_frame(dt, command buffer); then the host puts back the draw state the module changed.
// Packs have no GPU command buffer yet (sdl-gpu-imports), so it is 0. A trap means the module is gone.
frame :: proc(m: ^imports.Module, pack: ^Pack, dt: f32) -> (err: string) {
	err = imports.module_call(m, "ow_frame", {wasm.f32_val(dt), wasm.i32_val(0)}, fuel = FRAME_FUEL)
	imports.sdl_reset(&pack.sdl)
	return
}
