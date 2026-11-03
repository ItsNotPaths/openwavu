package imports

import "base:runtime"
import "core:strings"
import "../content"
import "../render"
import "../wasm"

// What the scene imports collect for one pack: the files its scenes name, and the last scene a module sent.
Scene_Inbox :: struct {
	pack:      ^content.Pack,
	assets:    [dynamic]string,  // pack paths; an asset id is index + 1
	asset_ids: map[string]u32,
	scene:     render.Scene,
	sent:      bool,             // a scene came since the host last took one
}

// The imports grow its lists with the allocator they are made with here.
scene_inbox_create :: proc(pack: ^content.Pack) -> Scene_Inbox {
	return {
		pack = pack,
		assets = make([dynamic]string),
		asset_ids = make(map[string]u32),
		scene = render.scene_create(),
	}
}

scene_inbox_destroy :: proc(inbox: ^Scene_Inbox) {
	for path in inbox.assets do delete(path)
	delete(inbox.assets)
	delete(inbox.asset_ids)
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
	path := string(bytes)
	if id, known := inbox.asset_ids[path]; known {
		results[0] = wasm.i32_val(i32(id))
		return nil
	}
	if _, found := content.pack_size(inbox.pack^, path); !found do return nil
	append(&inbox.assets, strings.clone(path, inbox.assets.allocator))
	id := u32(len(inbox.assets))
	inbox.asset_ids[inbox.assets[id - 1]] = id
	results[0] = wasm.i32_val(i32(id))
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
