package imports

import "base:runtime"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../titlepack"
import "../wasm"

// An offline match the entry module asked for.
Match_Request :: struct {
	mode:      titlepack.Mode,
	bot_sides: bit_set[0 ..< 2; u32],  // ow_bot_pad plays these
	loadouts:  [2][]byte,
	params:    map[string]f64,
}

// The host view (openwavu.h OwHostView), which the host keeps current.
Host_View :: struct {
	version, size: u32,
	connection:    Connection,
	overlay:       b32,
	match:         Match_Phase,
	winner:        i32,
}

Connection :: enum u32 {
	Offline,
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
	asked:     Maybe(Match_Request),  // until the host starts it at its next frame
	allocator: runtime.Allocator,     // what an ask is copied with
}

HOST_VIEW_VERSION :: 1
LOADOUT_MAX :: 4096

entry_create :: proc(modes: []titlepack.Mode) -> Entry {
	return {view = {version = HOST_VIEW_VERSION, size = size_of(Host_View)}, modes = modes, allocator = context.allocator}
}

match_request_destroy :: proc(r: ^Match_Request, allocator: runtime.Allocator) {
	for loadout in r.loadouts do delete(loadout, allocator)
	for name in r.params do delete(name, allocator)
	delete(r.params)
}

// host_view(buf, cap) -> its length, copying as much as fits. match_local(mode, len, bot_sides, loadout0, len,
// loadout1, len, params, len) -> 0 when the match starts at the next frame, -1 when it is refused: an unknown mode,
// params that do not read, or a match asked for or running.
define_entry :: proc(l: wasm.Linker, entry: ^Entry) -> (err: string) {
	if err = wasm.define_func(l, "host_view", {wasm.I32, wasm.I32}, {wasm.I32}, host_view, entry); err != "" do return
	return wasm.define_func(l, "match_local", {wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, match_local, entry)
}

// view(buf, cap) -> the length of the sim view of the last tick; copies as much as fits. view must outlive the linker's
// instances; the host refills it each tick.
define_view :: proc(l: wasm.Linker, view: ^[dynamic]byte) -> (err: string) {
	return wasm.define_func(l, "view", {wasm.I32, wasm.I32}, {wasm.I32}, view_import, view)
}

// "stage=3 rounds=5" -> the values; ok is false for a pair that does not read.
parse_params :: proc(text: string, allocator := context.allocator) -> (params: map[string]f64, ok: bool) {
	params = make(map[string]f64, allocator)
	for pair in strings.fields(text, context.temp_allocator) {
		name, eq, value := strings.partition(pair, "=")
		number, is_number := strconv.parse_f64(value)
		if name == "" || eq == "" || !is_number {
			for key in params do delete(key, allocator)
			delete(params)
			return nil, false
		}
		params[strings.clone(name, allocator)] = number
	}
	return params, true
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
	if entry.asked != nil || entry.view.match == .Running || len(loadout0) > LOADOUT_MAX || len(loadout1) > LOADOUT_MAX do return nil
	mode, known := find_mode(entry.modes, string(mode_name))
	if !known do return nil
	params, read := parse_params(string(params_text))
	if !read do return nil
	entry.asked = Match_Request{mode, transmute(bit_set[0 ..< 2; u32])(u32(args[2].of.i32) & 0b11), {slice.clone(loadout0), slice.clone(loadout1)}, params}
	results[0] = wasm.i32_val(0)
	return nil
}

@(private = "file")
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
