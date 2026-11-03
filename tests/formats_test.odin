// Checks against the tk5decomp Python reference. Needs ../tk5decomp/game and extract/; skips without them.
// (hole synthetic-fixtures :tags importer :sev polish) without game files every reader test skips; no small hand-made inputs (LZ edges, motbin end markers).
package tests

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import formats "../src/formats/tk5"

TK5 :: "../tk5decomp"

read_table :: proc() -> (table: []formats.Entry, ok: bool) {
	eboot, err := os.read_entire_file(TK5 + "/game/USRDIR/EBOOT.elf", context.temp_allocator)
	if err != nil do return nil, false
	build, _ := formats.find_build("NPUB30009")
	return formats.read_file_table(eboot, build)
}

// A C tool over the synced sim (tests/ref), linked with the sim's math.
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
	append(&sources, "-Ivendor/sqlite", tool, "modules/tk5/load.c", sim + "stage_file.c", sim + "anim.c", sim + "fighter_data.c",
		sim + "motbin.c", sim + "skel.c", "vendor/sqlite/libsqlite3.a", "-lpthread")
	append(&sources, ..extra)
	return build_sim_tool(out, ..sources[:])
}

// The tool's output for one file; nil when it fails.
run_sim_tool :: proc(tool, file: string) -> []byte {
	state, stdout, _, err := os.process_exec({command = {tool, file}}, context.temp_allocator)
	return err == nil && state.exit_code == 0 ? stdout : nil
}

// The archive entry, as t55.py extracts it.
reference_entry :: proc(index: int) -> (data: []byte, ok: bool) {
	matches, _ := filepath.glob(fmt.tprintf(TK5 + "/extract/%04d.*", index), context.temp_allocator)
	if len(matches) == 0 do return nil, false
	d, err := os.read_entire_file(matches[0], context.temp_allocator)
	return d, err == nil
}

@(test)
archive_matches_reference :: proc(t: ^testing.T) {
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	testing.expect_value(t, len(table), 2297)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)
	checked := 0
	for e, i in table {
		if formats.entry_missing(e) do continue
		want, has := reference_entry(i)
		if !has do continue
		stored := make([]byte, e.stored_size, context.temp_allocator)
		os.read_at(f, stored, formats.entry_offset(e))
		data, unpacked := formats.unpack_entry(e, stored, context.temp_allocator)
		testing.expectf(t, unpacked && bytes.equal(data, want), "entry %d differs", i)
		checked += 1
		free_all(context.temp_allocator)
	}
	testing.expect(t, checked > 2000, "too few entries checked")
}
