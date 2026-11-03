// The host imports pack modules call (sdk/include/openwavu.h), as sets defined on a module's linker. Pointers and lengths
// are offsets into the calling module's memory; one outside it gets the error result, never a host access.
package imports

import "base:runtime"
import "../content"
import "../wasm"

// content_size(path, path_len) -> size or -1, and content_read(path, path_len, offset, buf, cap) -> bytes copied or -1:
// a module reads the pack's files.
define_content :: proc(l: wasm.Linker, p: ^content.Pack) -> (err: string) {
	if err = wasm.define_func(l, "content_size", {wasm.I32, wasm.I32}, {wasm.I32}, content_size, p); err != "" do return
	return wasm.define_func(l, "content_read", {wasm.I32, wasm.I32, wasm.I32, wasm.I32, wasm.I32}, {wasm.I32}, content_read, p)
}

@(private = "file")
content_size :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	results[0] = wasm.i32_val(-1)
	memory := wasm.caller_memory(caller)
	path, path_ok := wasm.span(memory, u32(args[0].of.i32), u32(args[1].of.i32))
	if !path_ok do return nil
	size, ok := content.pack_size((^content.Pack)(env)^, string(path))
	if ok && size <= int(max(i32)) do results[0] = wasm.i32_val(i32(size))
	return nil
}

@(private = "file")
content_read :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	results[0] = wasm.i32_val(-1)
	memory := wasm.caller_memory(caller)
	path, path_ok := wasm.span(memory, u32(args[0].of.i32), u32(args[1].of.i32))
	buf, buf_ok := wasm.span(memory, u32(args[3].of.i32), u32(args[4].of.i32))
	if !path_ok || !buf_ok do return nil
	n, ok := content.pack_read((^content.Pack)(env)^, string(path), int(u32(args[2].of.i32)), buf)
	if ok do results[0] = wasm.i32_val(i32(n))
	return nil
}
