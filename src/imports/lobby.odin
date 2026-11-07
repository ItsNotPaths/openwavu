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
	Queue,
	Set_Params,
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

// Into line for a seat, or back to watching.
Queue :: struct {
	on: bool,
}

Set_Params :: struct {
	picks: string,  // checked against the pack's params already
}

Ready :: struct {
	loadout: []byte,
}

lobby_intent_destroy :: proc(intent: Lobby_Intent, allocator: runtime.Allocator) {
	#partial switch asked in intent {
	case Create_Lobby:
		delete(asked.mode, allocator)
		delete(asked.picks, allocator)
	case Set_Params:
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
	if err = wasm.define_func(l, "lobby_queue", {wasm.I32}, {}, lobby_queue, entry); err != "" do return
	if err = wasm.define_func(l, "lobby_params", {wasm.I32, wasm.I32}, {wasm.I32}, lobby_params, entry); err != "" do return
	if err = wasm.define_func(l, "exposed_params", {wasm.I32, wasm.I32}, {wasm.I32}, exposed_params, entry); err != "" do return
	if err = wasm.define_func(l, "exposed_param_value", {wasm.I32, wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, exposed_param_value, entry); err != "" do return
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
	if _, known := find_mode(entry.modes, string(mode)); !known || !picks_allowed(entry, string(picks)) do return nil
	append(&entry.intents, Create_Lobby{strings.clone(string(mode), entry.allocator), strings.clone(string(picks), entry.allocator)})
	results[0] = wasm.i32_val(0)
	return nil
}

// lobby_params(params, len) -> 0, or -1 when not hosting a lobby, its match is running, or picks the pack does not allow.
@(private = "file")
lobby_params :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	entry := (^Entry)(env)
	picks, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32))
	if !ok do return wasm.trap("ow_lobby_params: the params are outside the module's memory")
	results[0] = wasm.i32_val(-1)
	if !entry.view.hosting || entry.view.match == .Running || !picks_allowed(entry, string(picks)) do return nil
	append(&entry.intents, Set_Params{strings.clone(string(picks), entry.allocator)})
	results[0] = wasm.i32_val(0)
	return nil
}

// openwavu.h OwParamInfo: one pack.toml param a lobby host may change.
Param_Info :: struct {
	name:        [32]u8,
	kind:        u32,  // titlepack.Param_Kind
	value_count: u32,
	min, max:    f64,
	default:     [32]u8,
}

@(private = "file")
exposed :: proc(entry: ^Entry) -> []titlepack.Param {
	params := make([dynamic]titlepack.Param, context.temp_allocator)
	for param in entry.params do if param.expose do append(&params, param)
	return params[:]
}

// exposed_params(buf, cap) -> how many params the lobby host may change; copies as many as fit, in pack.toml's order.
@(private = "file")
exposed_params :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	params := exposed((^Entry)(env))
	buf, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32) * size_of(Param_Info))
	if !ok do return wasm.trap("ow_exposed_params: the buffer is outside the module's memory")
	infos := slice.reinterpret([]Param_Info, buf)
	for param, index in params[:min(len(params), len(infos))] {
		infos[index] = {kind = u32(param.kind), value_count = u32(len(param.values)), min = param.min, max = param.max}
		view_text(infos[index].name[:], param.name)
		view_text(infos[index].default[:], param.default)
	}
	results[0] = wasm.i32_val(i32(len(params)))
	return nil
}

// exposed_param_value(param, value, buf, cap) -> the length of that allowed value, or -1; copies as much as fits.
@(private = "file")
exposed_param_value :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	params := exposed((^Entry)(env))
	param, value := int(u32(args[0].of.i32)), int(u32(args[1].of.i32))
	buf, ok := wasm.span(wasm.caller_memory(caller), u32(args[2].of.i32), u32(args[3].of.i32))
	if !ok do return wasm.trap("ow_exposed_param_value: the buffer is outside the module's memory")
	results[0] = wasm.i32_val(-1)
	if param >= len(params) || value >= len(params[param].values) do return nil
	copy(buf, params[param].values[value])
	results[0] = wasm.i32_val(i32(len(params[param].values[value])))
	return nil
}

@(private = "file")
picks_allowed :: proc(entry: ^Entry, picks: string) -> bool {
	parsed, read := titlepack.parse_params(picks, context.temp_allocator)
	if !read do return false
	_, refused := titlepack.resolve_params(entry.params, parsed, context.temp_allocator)
	return refused == ""
}

@(private = "file")
lobby_queue :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	entry := (^Entry)(env)
	append(&entry.intents, Queue{args[0].of.i32 != 0})
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
