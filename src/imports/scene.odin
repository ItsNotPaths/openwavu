package imports

import "base:runtime"
import "core:strings"
import "../content"
import "../render"
import "../wasm"

// What the scene imports collect for one pack: the files its scenes name, and the last scene a module sent.
Scene_Inbox :: struct {
	assets: render.Assets,
	scene:  render.Scene,
	sent:   bool,  // a scene came since the host last took one
}

// The imports grow its lists with the allocator they are made with here.
scene_inbox_create :: proc(pack: ^content.Pack) -> Scene_Inbox {
	return {assets = render.assets_create(pack.files), scene = render.scene_create()}
}

// g: the GPU the pack's assets were loaded on; nil when none were.
scene_inbox_destroy :: proc(inbox: ^Scene_Inbox, g: ^render.Gpu) {
	render.assets_destroy(&inbox.assets, g)
	render.scene_destroy(&inbox.scene)
}

// asset(path, len) -> its id, the same for the same path; 0 when the pack has no such file. And
// scene_submit(block, size): the whole scene, read now; a block that does not read stops the module.
define_scene :: proc(l: wasm.Linker, inbox: ^Scene_Inbox) -> (err: string) {
	if err = wasm.define_func(l, "asset", {wasm.I32, wasm.I32}, {wasm.I32}, asset, inbox); err != "" do return
	return wasm.define_func(l, "scene_submit", {wasm.I32, wasm.I32}, {}, scene_submit, inbox)
}

@(private = "file")
asset :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	inbox := (^Scene_Inbox)(env)
	results[0] = wasm.i32_val(0)
	bytes, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32))
	if !ok do return wasm.trap("ow_asset: the path is outside the module's memory")
	results[0] = wasm.i32_val(i32(render.asset_id(&inbox.assets, string(bytes))))
	return nil
}

@(private = "file")
scene_submit :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	inbox := (^Scene_Inbox)(env)
	block, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32))
	if !ok do return wasm.trap("ow_scene_submit: the scene is outside the module's memory")
	if err := render.read_scene(&inbox.scene, block); err != "" {
		inbox.sent = false  // the part read is not a scene
		return wasm.trap(strings.concatenate({"ow_scene_submit: ", err}, context.temp_allocator))
	}
	inbox.sent = true
	return nil
}
