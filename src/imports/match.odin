package imports

import "base:runtime"
import "core:slice"
import "../online/wire"
import "../titlepack"
import "../wasm"

// An offline match the entry module asked for.
Match_Request :: struct {
	mode:      titlepack.Mode,
	bot_sides: bit_set[0 ..< 2; u32],  // ow_bot_pad plays these
	loadouts:  [2][]byte,
	params:    map[string]string,  // every declared param's final value, as text
}

// The host view (openwavu.h OwHostView), which the host keeps current.
Host_View :: struct {
	version, size: u32,
	connection:    Connection,
	overlay:       b32,
	match:         Match_Phase,
	winner:        i32,
	lobby_count:   u32,
	lobbies:       [LOBBIES_MAX]View_Lobby,
	joined:        b32,
	lobby:         View_Lobby,
	seats:         [2]View_Seat,
	seat:          u32,
	refused:       [64]u8,
}

LOBBIES_MAX :: 16

// Text fields NUL terminated (view_text).
View_Lobby :: struct {
	id, players: u32,
	host, mode:  [32]u8,
	params:      [128]u8,
}

View_Seat :: struct {
	name:  [32]u8,
	ready: b32,
}

Connection :: enum u32 {
	Offline,
	Connecting,
	Online,
	Failed,
}

Match_Phase :: enum u32 {
	None,
	Running,
	Ended,
}

// What the entry module's imports serve (the host view) and collect (its intents).
Entry :: struct {
	view:      Host_View,
	modes:     []titlepack.Mode,      // the pack.toml modes it may start
	params:    []titlepack.Param,     // the pack.toml params it may pick
	asked:     Maybe(Match_Request),  // until the host starts it at its next frame
	allocator: runtime.Allocator,     // what an ask is copied with
	exit:      bool,                  // the pack asked to go back to the launcher
	intents:   [dynamic]Lobby_Intent, // online asks, in order, until the host applies them
}

HOST_VIEW_VERSION :: 2

entry_create :: proc(tp: titlepack.Title_Pack) -> Entry {
	return {view = {version = HOST_VIEW_VERSION, size = size_of(Host_View)}, modes = tp.modes, params = tp.params, allocator = context.allocator}
}

match_request_destroy :: proc(r: ^Match_Request, allocator: runtime.Allocator) {
	for loadout in r.loadouts do delete(loadout, allocator)
	titlepack.params_destroy(&r.params, allocator)
}

// host_view(buf, cap) -> its length, copying as much as fits. match_local(mode, len, bot_sides, loadout0, len,
// loadout1, len, params, len) -> 0 when the match starts at the next frame, -1 when it is refused: an unknown mode,
// params that do not read or the pack does not allow (titlepack.resolve_params), or a match asked for or running.
define_entry :: proc(l: wasm.Linker, entry: ^Entry) -> (err: string) {
	if err = wasm.define_func(l, "host_view", {wasm.I32, wasm.I32}, {wasm.I32}, host_view, entry); err != "" do return
	if err = wasm.define_func(l, "exit", {}, {}, exit_import, entry); err != "" do return
	if err = define_lobby(l, entry); err != "" do return
	return wasm.define_func(l, "match_local", {wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, match_local, entry)
}

// view(buf, cap) -> the length of the sim view of the last tick; copies as much as fits. view must outlive the linker's
// instances; the host refills it each tick.
define_view :: proc(l: wasm.Linker, view: ^[dynamic]byte) -> (err: string) {
	return wasm.define_func(l, "view", {wasm.I32, wasm.I32}, {wasm.I32}, view_import, view)
}

@(private = "file")
exit_import :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	(^Entry)(env).exit = true
	return nil
}

@(private = "file")
match_local :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	entry := (^Entry)(env)
	context.allocator = entry.allocator
	memory := wasm.caller_memory(caller)
	mode_name, mode_ok := wasm.span(memory, u32(args[0].of.i32), u32(args[1].of.i32))
	loadout0, loadout0_ok := wasm.span(memory, u32(args[3].of.i32), u32(args[4].of.i32))
	loadout1, loadout1_ok := wasm.span(memory, u32(args[5].of.i32), u32(args[6].of.i32))
	params_text, params_ok := wasm.span(memory, u32(args[7].of.i32), u32(args[8].of.i32))
	if !mode_ok || !loadout0_ok || !loadout1_ok || !params_ok do return wasm.trap("ow_match_local: an argument is outside the module's memory")
	results[0] = wasm.i32_val(-1)
	if entry.asked != nil || entry.view.match == .Running || len(loadout0) > wire.LOADOUT_MAX || len(loadout1) > wire.LOADOUT_MAX do return nil
	mode, known := find_mode(entry.modes, string(mode_name))
	if !known do return nil
	picks, read := titlepack.parse_params(string(params_text), context.temp_allocator)
	if !read do return nil
	params, refused := titlepack.resolve_params(entry.params, picks)
	if refused != "" do return nil
	entry.asked = Match_Request{
		mode      = mode,
		bot_sides = transmute(bit_set[0 ..< 2; u32])(u32(args[2].of.i32) & 0b11),
		loadouts  = {slice.clone(loadout0), slice.clone(loadout1)},
		params    = params,
	}
	results[0] = wasm.i32_val(0)
	return nil
}

find_mode :: proc(modes: []titlepack.Mode, name: string) -> (mode: titlepack.Mode, ok: bool) {
	for m in modes do if m.name == name do return m, true
	return
}

@(private = "file")
host_view :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	entry := (^Entry)(env)
	buf, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32))
	if !ok do return wasm.trap("ow_host_view: the buffer is outside the module's memory")
	copy(buf, ([^]byte)(&entry.view)[:size_of(Host_View)])
	results[0] = wasm.i32_val(size_of(Host_View))
	return nil
}

@(private = "file")
view_import :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	view := (^[dynamic]byte)(env)
	buf, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32))
	if !ok do return wasm.trap("ow_view: the buffer is outside the module's memory")
	copy(buf, view[:])
	results[0] = wasm.i32_val(i32(len(view)))
	return nil
}
