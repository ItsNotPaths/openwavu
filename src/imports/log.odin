package imports

import "base:runtime"
import "core:fmt"
import "../wasm"

// log(message, len): a line on stderr, after `who` (a string that outlives the linker's instances).
define_log :: proc(l: wasm.Linker, who: ^string) -> (err: string) {
	return wasm.define_func(l, "log", {wasm.I32, wasm.I32}, {}, log, who)
}

@(private = "file")
log :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	context = runtime.default_context()
	if message, ok := wasm.span(wasm.caller_memory(caller), u32(args[0].of.i32), u32(args[1].of.i32)); ok {
		fmt.eprintfln("openwavu: %s: %s", (^string)(env)^, string(message))
	}
	return nil
}
