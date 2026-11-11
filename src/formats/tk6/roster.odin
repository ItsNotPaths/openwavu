// Every move set (COM file). All 263 sit in DATA213 (tk6decomp out/scan/files.tsv over every archive).
package tk6_formats

import "core:strings"
import tk5 "../tk5"

MOTBIN_ARCHIVE :: "DATA213.BIN"

Roster_Entry :: struct {
	index: int,     // global file index
	name:  string,  // header name, "[KAZUYA]"
}

read_roster :: proc(game: Game_Files, allocator := context.allocator) -> (roster: []Roster_Entry, ok: bool) {
	archive := archive_named(game, MOTBIN_ARCHIVE) or_return
	entries := make([dynamic]Roster_Entry, allocator)
	defer if !ok do delete_roster(entries[:], allocator)
	for index in archive.first ..< archive.end {
		head, found := read_file(game, index, HEADER_SIZE, context.temp_allocator)
		if !found || !is_motbin(head) do continue
		data := read_file(game, index, allocator = context.temp_allocator) or_return
		name := motbin_string(data, tk5.be_u32(data, 0x08)) or_return
		append(&entries, Roster_Entry{index, strings.clone(name, allocator)})
	}
	return entries[:], true
}

delete_roster :: proc(roster: []Roster_Entry, allocator := context.allocator) {
	for entry in roster do delete(entry.name, allocator)
	delete(roster, allocator)
}
