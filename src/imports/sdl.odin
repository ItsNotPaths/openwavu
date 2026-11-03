// SDL3 for presentation modules: the functions in sdl_allow.txt as imports with their SDL names, under "env" where
// wasm-ld puts a module's undefined functions. A pack sees its SDL objects as small handles in its own table, and
// the glue traps on a pointer outside the module's memory or a handle that is not the pack's (docs/app.md).
package imports

// (hole sdl-gpu-imports :tags (wasm render sdk)) no SDL_GPU functions: their create infos hold pointers, so each needs a deep copy.
// (hole sdl-audio-imports :tags (wasm sdk audio)) no SDL audio stream functions, so packs can not play sound.

import "base:runtime"
import "core:bytes"
import "core:fmt"
import sdl "vendor:sdl3"
import "vendor:sdl3/ttf"
import "../wasm"

Sdl_Kind :: enum u8 {
	Free,
	Renderer,
	Texture,
	IO_Stream,
	Font,
	Text_Engine,
	Text,
}

// owners: the handles it was made with; destroying one of them destroys this first.
Sdl_Object :: struct {
	kind:    Sdl_Kind,
	pointer: rawptr,
	owners:  [2]u32,
}

// One pack's SDL objects. A handle is its index + 1; handle 1 is the host's renderer.
Sdl_Set :: struct {
	objects: [dynamic]Sdl_Object,
	free:    [dynamic]u32,
}

SDL_RENDERER :: 1

sdl_set_create :: proc(renderer: ^sdl.Renderer) -> (set: Sdl_Set) {
	append(&set.objects, Sdl_Object{kind = .Renderer, pointer = renderer})
	return
}

// Destroys every object the pack left.
sdl_set_destroy :: proc(set: ^Sdl_Set) {
	for _, i in set.objects do sdl_destroy(set, u32(i + 1))
	delete(set.objects)
	delete(set.free)
}

// The allowlisted SDL functions, and ow_renderer() -> the renderer's handle, on a module's linker.
define_sdl :: proc(l: wasm.Linker, set: ^Sdl_Set) -> (err: string) {
	hand := [?]Sdl_Define {
		{"SDL_UpdateTexture", {wasm.I32, wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, update_texture},
		{"SDL_IOFromConstMem", {wasm.I32, wasm.I32}, {wasm.I32}, io_from_const_mem},
		{"TTF_OpenFontIO", {wasm.I32, wasm.I32, wasm.F32}, {wasm.I32}, open_font_io},
	}
	for d in hand do if err = wasm.define_func(l, d.name, d.params, d.results, d.callback, set, "env"); err != "" do return
	for d in sdl_glue() do if err = wasm.define_func(l, d.name, d.params, d.results, d.callback, set, "env"); err != "" do return
	return wasm.define_func(l, "renderer", {}, {wasm.I32}, renderer, set)
}

@(private)
Sdl_Define :: struct {
	name:            string,
	params, results: []u8,
	callback:        wasm.Callback,
}

// One import call: the first bad argument becomes error, and the glue traps with it before SDL sees anything.
@(private)
Sdl_Call :: struct {
	set:    ^Sdl_Set,
	memory: []byte,
	name:   string,
	error:  string,
}

@(private)
sdl_call :: proc(env: rawptr, caller: ^wasm.C_Caller, name: string) -> Sdl_Call {
	return {(^Sdl_Set)(env), wasm.caller_memory(caller), name, ""}
}

// The object behind a handle of this kind; handle 0 is NULL.
@(private)
sdl_handle :: proc(call: ^Sdl_Call, arg: int, v: wasm.Val, kind: Sdl_Kind) -> rawptr {
	handle := u32(v.of.i32)
	if handle == 0 do return nil
	if handle <= u32(len(call.set.objects)) && call.set.objects[handle - 1].kind == kind do return call.set.objects[handle - 1].pointer
	fail(call, arg, fmt.tprintf("is not a %v handle", kind))
	return nil
}

// size bytes of module memory at the pointer; NULL stays NULL.
@(private)
sdl_bytes :: proc(call: ^Sdl_Call, arg: int, v: wasm.Val, size: u64) -> rawptr {
	offset := u64(u32(v.of.i32))
	if offset == 0 do return nil
	if offset + size > u64(len(call.memory)) {
		fail(call, arg, "is outside the module's memory")
		return nil
	}
	return raw_data(call.memory[offset:])
}

// A text of length bytes, or up to its NUL when length is 0; either way inside module memory.
@(private)
sdl_text :: proc(call: ^Sdl_Call, arg: int, v: wasm.Val, length: u64) -> rawptr {
	if length > 0 do return sdl_bytes(call, arg, v, length)
	offset := u32(v.of.i32)
	if offset == 0 || offset >= u32(len(call.memory)) || bytes.index_byte(call.memory[offset:], 0) < 0 {
		if offset != 0 do fail(call, arg, "has no NUL inside the module's memory")
		return nil
	}
	return raw_data(call.memory[offset:])
}

// A handle for an object SDL just made; 0 when SDL failed.
@(private)
sdl_new :: proc(set: ^Sdl_Set, kind: Sdl_Kind, pointer: rawptr, owners: [2]u32) -> u32 {
	if pointer == nil do return 0
	o := Sdl_Object{kind, pointer, owners}
	if handle, reused := pop_safe(&set.free); reused {
		set.objects[handle - 1] = o
		return handle
	}
	append(&set.objects, o)
	return u32(len(set.objects))
}

// Destroys an object and, first, everything made with it. Owners are always older handles, so this ends.
@(private)
sdl_destroy :: proc(set: ^Sdl_Set, handle: u32) {
	if handle == 0 || set.objects[handle - 1].kind == .Free do return
	for o, i in set.objects do if o.kind != .Free && (o.owners[0] == handle || o.owners[1] == handle) {
		sdl_destroy(set, u32(i + 1))
	}
	forget(set, handle, destroy = true)
}

@(private = "file")
forget :: proc(set: ^Sdl_Set, handle: u32, destroy: bool) {
	o := &set.objects[handle - 1]
	if destroy do sdl_destroy_object(o.kind, o.pointer)
	o^ = {}
	if handle != SDL_RENDERER do append(&set.free, handle)
}

@(private = "file")
fail :: proc(call: ^Sdl_Call, arg: int, why: string) {
	if call.error == "" do call.error = fmt.tprintf("%s: argument %d %s", call.name, arg, why)
}

@(private = "file")
renderer :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	results[0] = wasm.i32_val(SDL_RENDERER)
	return nil
}

// SDL reads rows of width * bytes per pixel, pitch apart, so the pixels span (height - 1) * pitch + that.
@(private = "file")
update_texture :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	call := sdl_call(env, caller, "SDL_UpdateTexture")
	texture := (^sdl.Texture)(sdl_handle(&call, 1, args[0], .Texture))
	rect := (^sdl.Rect)(sdl_bytes(&call, 2, args[1], size_of(sdl.Rect)))
	pitch := args[3].of.i32
	if call.error != "" do return wasm.trap(call.error)
	results[0] = wasm.i32_val(0)
	if texture == nil do return nil
	w, h := rect != nil ? rect.w : texture.w, rect != nil ? rect.h : texture.h
	row := i64(w) * (sdl.ISPIXELFORMAT_FOURCC(texture.format) ? 0 : i64(u32(texture.format) & 0xFF))  // SDL_BYTESPERPIXEL
	if row <= 0 || h <= 0 || i64(pitch) < row do return nil  // SDL refuses these too
	pixels := sdl_bytes(&call, 3, args[2], u64(i64(h - 1) * i64(pitch) + row))
	if call.error != "" do return wasm.trap(call.error)
	results[0] = wasm.i32_val(i32(sdl.UpdateTexture(texture, rect, pixels, pitch)))
	return nil
}

// SDL keeps reading the stream after the call, so it reads a host copy, not module memory.
@(private = "file")
io_from_const_mem :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	call := sdl_call(env, caller, "SDL_IOFromConstMem")
	size := u32(args[1].of.i32)
	data := sdl_bytes(&call, 1, args[0], u64(size))
	if call.error != "" do return wasm.trap(call.error)
	results[0] = wasm.i32_val(0)
	if data == nil do return nil
	stream := sdl.IOFromDynamicMem()
	if stream == nil do return nil
	if sdl.WriteIO(stream, data, uint(size)) != uint(size) || sdl.SeekIO(stream, 0, .SEEK_SET) != 0 {
		_ = sdl.CloseIO(stream)
		return nil
	}
	results[0] = wasm.i32_val(i32(sdl_new(call.set, .IO_Stream, stream, {})))
	return nil
}

// With closeio the font takes the stream: it leaves the table without being closed. Without, the stream owns the font.
@(private = "file")
open_font_io :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	call := sdl_call(env, caller, "TTF_OpenFontIO")
	stream := (^sdl.IOStream)(sdl_handle(&call, 1, args[0], .IO_Stream))
	if call.error != "" do return wasm.trap(call.error)
	handle, closeio := u32(args[0].of.i32), args[1].of.i32 != 0
	owners := [2]u32{}
	if closeio {
		for o in call.set.objects do if o.kind != .Free && o.owners[0] == handle {
			return wasm.trap("TTF_OpenFontIO: closeio on a stream another font still reads")
		}
		if stream != nil do forget(call.set, handle, destroy = false)
	} else {
		owners[0] = handle
	}
	results[0] = wasm.i32_val(i32(sdl_new(call.set, .Font, ttf.OpenFontIO(stream, closeio, args[2].of.f32), owners)))
	return nil
}
