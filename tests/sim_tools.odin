// Native C tools over modules/tk5 that tests build and run (sources in tests/ref).
package tests

import "core:os"

// A C tool over the TK5 sim (tests/ref), linked with the sim's math.
build_sim_tool :: proc(out: string, sources: ..string) -> bool {
	sim :: "modules/tk5/sim/"
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "cc", "-std=c23", "-fwrapv", "-ffp-contract=off", "-Imodules/tk5", "-Isdk/include", "-o", out, sim + "math.c", sim + "quat.c", sim + "vec.c")
	append(&command, ..sources)
	append(&command, "-lm")
	state, _, _, err := os.process_exec({command = command[:]}, context.temp_allocator)
	return err == nil && state.exit_code == 0
}

// A tool that links the db loader (modules/tk5/load.c), what it calls, and `extra` sources.
build_loader_tool :: proc(out, tool: string, extra: ..string) -> bool {
	sim :: "modules/tk5/sim/"
	sources := make([dynamic]string, context.temp_allocator)
	append(&sources, "-Ivendor/sqlite", "-Ivendor/jsmn", tool, "modules/tk5/load.c", sim + "stage_file.c", sim + "anim.c", sim + "fighter_data.c",
		sim + "motbin.c", sim + "skel.c", "vendor/sqlite/libsqlite3.a", "-lpthread")
	append(&sources, ..extra)
	return build_sim_tool(out, ..sources[:])
}

// The tool's output for one file; nil when it fails.
run_sim_tool :: proc(tool, file: string) -> []byte {
	state, stdout, _, err := os.process_exec({command = {tool, file}}, context.temp_allocator)
	return err == nil && state.exit_code == 0 ? stdout : nil
}
