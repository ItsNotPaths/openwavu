package imports

import "base:runtime"
import "core:slice"
import "core:strings"
import "../online/wire"
import "../titlepack"
import "../wasm"

// The entry module's online asks (openwavu.h ow_online .. ow_ready), queued for the host's next frame.
Lobby_Intent :: union {
	Go_Online,
	Create_Lobby,
	Join_Lobby,
	Leave_Lobby,
	Ready,
}

Go_Online :: struct {
	on: bool,
}

Create_Lobby :: struct {
	mode:  string,
	picks: string,  // checked against the pack's params already
}

Join_Lobby :: struct {
	id: u32,
}

Leave_Lobby :: struct {}

Ready :: struct {
	loadout: []byte,
}

lobby_intent_destroy :: proc(intent: Lobby_Intent, allocator: runtime.Allocator) {
	#partial switch asked in intent {
	case Create_Lobby:
		delete(asked.mode, allocator)
		delete(asked.picks, allocator)
	case Ready:
		delete(asked.loadout, allocator)
	}
}

@(private)
define_lobby :: proc(l: wasm.Linker, entry: ^Entry) -> (err: string) {
	if err = wasm.define_func(l, "online", {wasm.I32}, {}, online_import, entry); err != "" do return
	if err = wasm.define_func(l, "lobby_create", {wasm.I32, wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, lobby_create, entry); err != "" do return
	if err = wasm.define_func(l, "lobby_join", {wasm.I32}, {}, lobby_join, entry); err != "" do return
	if err = wasm.define_func(l, "lobby_leave", {}, {}, lobby_leave, entry); err != "" do return
	return wasm.define_func(l, "ready", {wasm.I32, wasm.I32}, {wasm.I32}, ready, entry)
}

@(private = "file")
online_import :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	entry := (^Entry)(env)
	append(&entry.intents, Go_Online{args[0].of.i32 != 0})
	return nil
}

// lobby_create(mode, len, params, len) -> 0, or -1 when offline, already in a lobby, an unknown mode, or picks the pack
// does not allow.
@(private = "file")
lobby_create :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	entry := (^Entry)(env)
	memory := wasm.caller_memory(caller)
	mode, mode_ok := wasm.span(memory, u32(args[0].of.i32), u32(args[1].of.i32))
	picks, picks_ok := wasm.span(memory, u32(args[2].of.i32), u32(args[3].of.i32))
	if !mode_ok || !picks_ok do return wasm.trap("ow_lobby_create: an argument is outside the module's memory")
	results[0] = wasm.i32_val(-1)
	if entry.view.connection != .Online || entry.view.joined do return nil
	if _, known := find_mode(entry.modes, string(mode)); !known do return nil
	parsed, read := titlepack.parse_params(string(picks), context.temp_allocator)
	if !read do return nil
	if _, refused := titlepack.resolve_params(entry.params, parsed, context.temp_allocator); refused != "" do return nil
	append(&entry.intents, Create_Lobby{strings.clone(string(mode), entry.allocator), strings.clone(string(picks), entry.allocator)})
	results[0] = wasm.i32_val(0)
	return nil
}

@(private = "file")
lobby_join :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	entry := (^Entry)(env)
	append(&entry.intents, Join_Lobby{u32(args[0].of.i32)})
	return nil
}

@(private = "file")
lobby_leave :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	entry := (^Entry)(env)
	append(&entry.intents, Leave_Lobby{})
	return nil
}

// ready(loadout, len) -> 0, or -1 when the loadout is over wire.LOADOUT_MAX.
@(private = "file")
ready :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	entry := (^Entry)(env)
	loadout, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32))
	if !ok do return wasm.trap("ow_ready: the loadout is outside the module's memory")
	results[0] = wasm.i32_val(-1)
	if len(loadout) > wire.LOADOUT_MAX do return nil
	append(&entry.intents, Ready{slice.clone(loadout, entry.allocator)})
	results[0] = wasm.i32_val(0)
	return nil
}

// Text into a view field, cut to fit and NUL terminated.
view_text :: proc(field: []u8, text: string) {
	slice.zero(field)
	copy(field[:len(field) - 1], text)
}
