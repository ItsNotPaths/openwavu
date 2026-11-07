// SDL3 for presentation modules: the functions in sdl_allow.txt as imports with their SDL names, under "env" where
// wasm-ld puts a module's undefined functions. A pack sees its SDL objects as small handles in its own table, and
// the glue traps on a pointer outside the module's memory or a handle that is not the pack's (docs/app.md).
package imports

// (hole sdl-gpu-imports :tags (wasm render sdk)) no SDL_GPU functions: their create infos hold pointers, so each needs a deep copy.

import "base:runtime"
import "core:bytes"
import hm "core:container/handle_map"
import "core:fmt"
import sdl "vendor:sdl3"
import "vendor:sdl3/ttf"
import "../wasm"

Sdl_Kind :: enum u8 {
	Renderer,
	Texture,
	IO_Stream,
	Font,
	Text_Engine,
	Text,
	Audio_Stream,
}

// What a pack names an audio stream (OW_SOUND_*); the player sets a volume for each.
Sound_Kind :: enum u32 {
	Effects,
	Music,
}

// Gains per kind, 1 = as the pack plays it.
Volumes :: [Sound_Kind]f32

// A pack sees a handle as one u32; 0 is NULL. A destroyed object's handle never names a later object in its slot.
Sdl_Handle :: hm.Handle32

// owners: the handles it was made with; destroying one of them destroys this first.
Sdl_Object :: struct {
	handle:  Sdl_Handle,
	kind:    Sdl_Kind,
	pointer: rawptr,
	owners:  [2]u32,
	sound:   Sound_Kind,  // an audio stream's
	gain:    f32,         // an audio stream's own, before the player's volume
}

// One pack's SDL objects.
Sdl_Set :: struct {
	objects:  hm.Dynamic_Handle_Map(Sdl_Object, Sdl_Handle),
	renderer: u32,  // the host's renderer
	volumes:  Volumes,
}

// The imports grow its lists with the allocator it is made with here.
sdl_set_create :: proc(renderer: ^sdl.Renderer, volumes := Volumes{.Effects = 1, .Music = 1}) -> (set: Sdl_Set) {
	hm.dynamic_init(&set.objects, context.allocator)
	set.volumes = volumes
	set.renderer = sdl_new(&set, .Renderer, renderer, {})
	return
}

// Destroys every object the pack left.
sdl_set_destroy :: proc(set: ^Sdl_Set) {
	handles := make([dynamic]u32, context.temp_allocator)
	iterator := hm.iterator_make(&set.objects)
	for _, handle in hm.iterate(&iterator) do append(&handles, transmute(u32)handle)
	for handle in handles do sdl_destroy(set, handle)
	hm.dynamic_destroy(&set.objects)
}

// Puts back the renderer state the allowlist lets a pack change: draw color, draw blend mode, clip, scale.
sdl_reset :: proc(set: ^Sdl_Set) {
	object, valid := hm.get(&set.objects, transmute(Sdl_Handle)set.renderer)
	if !valid do return
	renderer := (^sdl.Renderer)(object.pointer)
	_ = sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	_ = sdl.SetRenderDrawBlendMode(renderer, sdl.BLENDMODE_BLEND)
	_ = sdl.SetRenderClipRect(renderer, nil)
	_ = sdl.SetRenderScale(renderer, 1, 1)
}

// The allowlisted SDL functions, and ow_renderer() -> the renderer's handle, on a module's linker.
define_sdl :: proc(l: wasm.Linker, set: ^Sdl_Set) -> (err: string) {
	hand := [?]Sdl_Define {
		{"SDL_UpdateTexture", {wasm.I32, wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, update_texture},
		{"SDL_IOFromConstMem", {wasm.I32, wasm.I32}, {wasm.I32}, io_from_const_mem},
		{"TTF_OpenFontIO", {wasm.I32, wasm.I32, wasm.F32}, {wasm.I32}, open_font_io},
		{"SDL_OpenAudioDeviceStream", {wasm.I32, wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, open_audio_device_stream},
		{"SDL_SetAudioStreamGain", {wasm.I32, wasm.F32}, {wasm.I32}, set_audio_stream_gain},
	}
	for list in ([][]Sdl_Define{hand[:], sdl_glue()}) {
		for d in list do if err = wasm.define_func(l, d.name, d.params, d.results, d.callback, set, "env"); err != "" do return
	}
	if err = wasm.define_func(l, "sound_kind", {wasm.I32, wasm.I32}, {}, sound_kind, set); err != "" do return
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
	handle := transmute(Sdl_Handle)u32(v.of.i32)
	if handle == {} do return nil
	if object, valid := hm.get(&call.set.objects, handle); valid && object.kind == kind do return object.pointer
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
	handle := hm.add(&set.objects, Sdl_Object{kind = kind, pointer = pointer, owners = owners})
	return transmute(u32)handle
}

// Destroys an object and, first, everything made with it. Owners are always older handles, so this ends.
@(private)
sdl_destroy :: proc(set: ^Sdl_Set, handle: u32) {
	found, valid := hm.get(&set.objects, transmute(Sdl_Handle)handle)
	if !valid do return
	object := found^
	iterator := hm.iterator_make(&set.objects)
	for other, other_handle in hm.iterate(&iterator) do if made_with(other^, handle) do sdl_destroy(set, transmute(u32)other_handle)
	sdl_destroy_object(object.kind, object.pointer)
	release(set, handle)
}

@(private = "file")
made_with :: proc(object: Sdl_Object, handle: u32) -> bool {
	return object.owners[0] == handle || object.owners[1] == handle
}

// Frees the handle's slot; the object itself is destroyed already, or now belongs to another object.
@(private = "file")
release :: proc(set: ^Sdl_Set, handle: u32) {
	_, _ = hm.remove(&set.objects, transmute(Sdl_Handle)handle)
}

@(private = "file")
fail :: proc(call: ^Sdl_Call, arg: int, why: string) {
	if call.error == "" do call.error = fmt.tprintf("%s: argument %d %s", call.name, arg, why)
}

@(private = "file")
renderer :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	results[0] = wasm.i32_val(i32((^Sdl_Set)(env).renderer))
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
		iterator := hm.iterator_make(&call.set.objects)
		for other, _ in hm.iterate(&iterator) do if made_with(other^, handle) do return wasm.trap("TTF_OpenFontIO: closeio on a stream another font still reads")
		if stream != nil do release(call.set, handle)
	} else {
		owners[0] = handle
	}
	results[0] = wasm.i32_val(i32(sdl_new(call.set, .Font, ttf.OpenFontIO(stream, closeio, args[2].of.f32), owners)))
	return nil
}

// Only the default playback device, and no callback: the pack feeds the stream itself. Each stream gets its own
// logical device; destroying the stream closes it.
@(private = "file")
open_audio_device_stream :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	call := sdl_call(env, caller, "SDL_OpenAudioDeviceStream")
	if sdl.AudioDeviceID(u32(args[0].of.i32)) != sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK do fail(&call, 1, "is not SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK")
	spec := (^sdl.AudioSpec)(sdl_bytes(&call, 2, args[1], size_of(sdl.AudioSpec)))
	if args[2].of.i32 != 0 do fail(&call, 3, "is a callback")
	if call.error != "" do return wasm.trap(call.error)
	stream := sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, spec, nil, nil)
	handle := sdl_new(call.set, .Audio_Stream, stream, {})
	if object, valid := hm.get(&call.set.objects, transmute(Sdl_Handle)handle); valid {
		object.gain = 1
		apply_gain(call.set, object^)
	}
	results[0] = wasm.i32_val(i32(handle))
	return nil
}

// The pack's gain is kept, and SDL gets it times the player's volume.
@(private = "file")
set_audio_stream_gain :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	call := sdl_call(env, caller, "SDL_SetAudioStreamGain")
	stream := audio_stream(&call, 1, args[0])
	if call.error != "" do return wasm.trap(call.error)
	gain := args[1].of.f32
	set := stream != nil && gain >= 0
	if set {
		stream.gain = gain
		apply_gain(call.set, stream^)
	}
	results[0] = wasm.i32_val(i32(set))
	return nil
}

// ow_sound_kind(stream, kind): which of the player's volumes the stream plays at.
@(private = "file")
sound_kind :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	call := sdl_call(env, caller, "ow_sound_kind")
	stream := audio_stream(&call, 1, args[0])
	kind := u32(args[1].of.i32)
	if kind > u32(max(Sound_Kind)) do fail(&call, 2, "is not an OW_SOUND_* kind")
	if call.error != "" do return wasm.trap(call.error)
	if stream != nil {
		stream.sound = Sound_Kind(kind)
		apply_gain(call.set, stream^)
	}
	return nil
}

// The audio stream object behind a handle; nil for 0.
@(private = "file")
audio_stream :: proc(call: ^Sdl_Call, arg: int, v: wasm.Val) -> ^Sdl_Object {
	if sdl_handle(call, arg, v, .Audio_Stream) == nil do return nil
	object, _ := hm.get(&call.set.objects, transmute(Sdl_Handle)u32(v.of.i32))
	return object
}

@(private = "file")
apply_gain :: proc(set: ^Sdl_Set, stream: Sdl_Object) {
	_ = sdl.SetAudioStreamGain((^sdl.AudioStream)(stream.pointer), stream.gain * set.volumes[stream.sound])
}
