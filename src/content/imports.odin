package content

import "base:runtime"
import "../wasm"

// content_size(path, path_len) -> size or -1, and content_read(path, path_len, offset, buf, cap) -> bytes copied or -1:
// a module reads the pack's files. Paths and buffers are (offset, length) in the calling module's memory.
define_imports :: proc(l: wasm.Linker, p: ^Pack) -> (err: string) {
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
	size, ok := pack_size((^Pack)(env)^, string(path))
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
	n, ok := pack_read((^Pack)(env)^, string(path), int(u32(args[2].of.i32)), buf)
	if ok do results[0] = wasm.i32_val(i32(n))
	return nil
}
