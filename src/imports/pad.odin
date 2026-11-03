package imports

import "../wasm"

// pad(player) -> what local player 0 or 1 holds this frame, an OW_PAD_* word; 0 for any other player. pads must
// outlive the linker's instances; the host fills it each frame.
define_pad :: proc(l: wasm.Linker, pads: ^[2]u32) -> (err: string) {
	return wasm.define_func(l, "pad", {wasm.I32}, {wasm.I32}, pad, pads)
}

@(private = "file")
pad :: proc "c" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {
	pads := (^[2]u32)(env)
	player := u32(args[0].of.i32)
	results[0] = wasm.i32_val(player < len(pads) ? i32(pads[player]) : 0)
	return nil
}
