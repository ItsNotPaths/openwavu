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
