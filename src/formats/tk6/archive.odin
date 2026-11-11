// TEKKEN.psarc (zlib blocks) and the DATA2xx archives: DINF_200.BIN ranges, IDX (block, size) pairs.
// tk6decomp tools/psarc.py, tools/datascan.py.
package tk6_formats

import "base:runtime"
import "core:os"
import "core:strings"
import "vendor:zlib"
import tk5 "../tk5"

PSARC_HEADER_SIZE :: 32
PSARC_ENTRY_SIZE :: 30
INDEX_BLOCK :: 0x80
DINF_FIRST_RECORD :: 0x20
DINF_RECORD_SIZE :: 0x50

Psarc :: struct {
	file:          ^os.File,
	block_size:    int,
	entries:       []Psarc_Entry,  // entry 0 is the name list
	names:         []string,       // names[number] belongs to entries[number + 1]
	block_offsets: []i64,          // where each block starts in the psarc
	block_sizes:   []int,          // stored size; 0 = a full raw block
	name_list:     []byte,
}

Psarc_Entry :: struct {
	first_block: int,
	length:      i64,
	offset:      i64,
}

// A BIN sits inside the psarc or loose in USRDIR.
Archive_Data :: union {
	Psarc_Entry,
	^os.File,
}

Archive :: struct {
	name:       string,  // the BIN name, "DATA213.BIN"
	first, end: int,     // global file index range
	files:      []Index_Entry,
	data:       Archive_Data,
}

// size 0 or 0xffffffff: no file.
Index_Entry :: struct {
	block, size: u32,
}

Game_Files :: struct {
	psarc:     Psarc,
	archives:  []Archive,
	allocator: runtime.Allocator,
}

open_game_files :: proc(usrdir: string, allocator := context.allocator) -> (game: Game_Files, ok: bool) {
	context.allocator = allocator
	game.allocator = allocator
	defer if !ok do close_game_files(&game)
	open_psarc(&game.psarc, join_path(usrdir, "TEKKEN.psarc")) or_return
	dinf := read_member(game.psarc, usrdir, "DINF_200.BIN") or_return
	defer delete(dinf)

	game.archives = make([]Archive, max(0, (len(dinf) - DINF_FIRST_RECORD) / DINF_RECORD_SIZE))
	for &archive, number in game.archives {
		record := dinf[DINF_FIRST_RECORD + number * DINF_RECORD_SIZE:]
		archive.name = strings.clone(tk5.cstring_at(record, 0x08))
		archive.first, archive.end = int(tk5.be_u32(record, 0)), int(tk5.be_u32(record, 4))
		index := read_member(game.psarc, usrdir, tk5.cstring_at(record, 0x18)) or_return
		defer delete(index)
		archive.files = make([]Index_Entry, len(index) / 8)
		for &file, file_number in archive.files do file = {tk5.be_u32(index, file_number * 8), tk5.be_u32(index, file_number * 8 + 4)}
		if entry, inside := psarc_find(game.psarc, archive.name); inside {
			archive.data = entry
		} else {
			file, error := os.open(join_path(usrdir, archive.name))
			if error != nil do return
			archive.data = file
		}
	}
	return game, true
}

close_game_files :: proc(game: ^Game_Files) {
	context.allocator = game.allocator
	for archive in game.archives {
		if file, loose := archive.data.(^os.File); loose do os.close(file)
		delete(archive.name)
		delete(archive.files)
	}
	delete(game.archives)
	psarc := &game.psarc
	if psarc.file != nil do os.close(psarc.file)
	delete(psarc.entries)
	delete(psarc.names)
	delete(psarc.block_offsets)
	delete(psarc.block_sizes)
	delete(psarc.name_list)
}

// The first `limit` bytes of file `index` (global index); not ok for an empty slot.
read_file :: proc(game: Game_Files, index: int, limit := max(int), allocator := context.allocator) -> (data: []byte, ok: bool) {
	archive, entry := find_file(game, index) or_return
	size := min(int(entry.size), limit)
	offset := i64(entry.block) * INDEX_BLOCK
	data = make([]byte, size, allocator)
	switch source in archive.data {
	case Psarc_Entry:
		ok = offset + i64(size) <= source.length && psarc_read(game.psarc, source, offset, data)
	case ^os.File:
		read, error := os.read_at(source, data, offset)
		ok = error == nil && read == size
	}
	if !ok do delete(data, allocator)
	return
}

file_size :: proc(game: Game_Files, index: int) -> int {
	_, entry, found := find_file(game, index)
	return found ? int(entry.size) : 0
}

archive_named :: proc(game: Game_Files, name: string) -> (archive: Archive, ok: bool) {
	for candidate in game.archives do if candidate.name == name do return candidate, true
	return
}

@(private = "file")
find_file :: proc(game: Game_Files, index: int) -> (archive: Archive, entry: Index_Entry, ok: bool) {
	for candidate in game.archives {
		local := index - candidate.first
		if index < candidate.first || index >= candidate.end || local >= len(candidate.files) do continue
		entry = candidate.files[local]
		return candidate, entry, entry.size != 0 && entry.size != 0xffffffff
	}
	return
}

@(private = "file")
// Fills `psarc` as far as it gets; close_game_files frees it either way.
open_psarc :: proc(psarc: ^Psarc, path: string) -> bool {
	file, error := os.open(path)
	if error != nil do return false
	psarc.file = file
	header: [PSARC_HEADER_SIZE]byte
	if read, _ := os.read_at(psarc.file, header[:], 0); read != len(header) do return false
	if string(header[0:4]) != "PSAR" || string(header[8:12]) != "zlib" do return false
	toc_length := int(tk5.be_u32(header[:], 12))
	entry_size := int(tk5.be_u32(header[:], 16))
	entry_count := int(tk5.be_u32(header[:], 20))
	psarc.block_size = int(tk5.be_u32(header[:], 24))
	if entry_size != PSARC_ENTRY_SIZE || entry_count == 0 || toc_length < PSARC_HEADER_SIZE + entry_count * entry_size do return false

	toc := make([]byte, toc_length - PSARC_HEADER_SIZE)
	defer delete(toc)
	if read, _ := os.read_at(psarc.file, toc, PSARC_HEADER_SIZE); read != len(toc) do return false
	psarc.entries = make([]Psarc_Entry, entry_count)
	for &entry, number in psarc.entries {
		record := toc[number * entry_size:]
		entry = {int(tk5.be_u32(record, 16)), be_u40(record, 20), be_u40(record, 25)}
	}

	size_width := psarc.block_size <= 0x10000 ? 2 : psarc.block_size <= 0x1000000 ? 3 : 4
	table := toc[entry_count * entry_size:]
	psarc.block_sizes = make([]int, len(table) / size_width)
	for &size, number in psarc.block_sizes {
		for byte_value in table[number * size_width:][:size_width] do size = size << 8 | int(byte_value)
	}
	psarc.block_offsets = make([]i64, len(psarc.block_sizes))
	for entry in psarc.entries {
		blocks := int((entry.length + i64(psarc.block_size) - 1) / i64(psarc.block_size))
		if entry.first_block + blocks > len(psarc.block_sizes) do return false
		position := entry.offset
		for block in entry.first_block ..< entry.first_block + blocks {
			psarc.block_offsets[block] = position
			position += i64(stored_size(psarc^, block))
		}
	}

	names_entry := psarc.entries[0]
	psarc.name_list = make([]byte, names_entry.length)
	psarc_read(psarc^, names_entry, 0, psarc.name_list) or_return
	psarc.names = strings.split(string(psarc.name_list), "\n")
	for &name in psarc.names do name = strings.trim_prefix(name, "/")
	return true
}

@(private = "file")
psarc_find :: proc(psarc: Psarc, name: string) -> (entry: Psarc_Entry, ok: bool) {
	for candidate, number in psarc.names {
		if candidate == name && number + 1 < len(psarc.entries) do return psarc.entries[number + 1], true
	}
	return
}

// Inflates the blocks that cover `output`. A block stored at full length without a zlib header is raw.
@(private = "file")
psarc_read :: proc(psarc: Psarc, entry: Psarc_Entry, offset: i64, output: []byte) -> bool {
	block_size := i64(psarc.block_size)
	stored := make([]byte, psarc.block_size)
	defer delete(stored)
	plain := make([]byte, psarc.block_size)
	defer delete(plain)
	position := offset
	for done := 0; done < len(output); {
		local := position / block_size
		block := entry.first_block + int(local)
		plain_length := int(min(block_size, entry.length - local * block_size))
		stored_length := stored_size(psarc, block)
		if read, _ := os.read_at(psarc.file, stored[:stored_length], psarc.block_offsets[block]); read != stored_length do return false
		if stored_length == plain_length && stored[0] != 0x78 {
			copy(plain, stored[:stored_length])
		} else {
			length := zlib.uLongf(plain_length)
			result := zlib.uncompress(raw_data(plain), &length, raw_data(stored), zlib.uLong(stored_length))
			if result != zlib.OK || int(length) != plain_length do return false
		}
		copied := copy(output[done:], plain[position - local * block_size:plain_length])
		done += copied
		position += i64(copied)
	}
	return true
}

@(private = "file")
stored_size :: proc(psarc: Psarc, block: int) -> int {
	size := psarc.block_sizes[block]
	return size == 0 ? psarc.block_size : size
}

// A small file from inside the psarc, else from USRDIR.
@(private = "file")
read_member :: proc(psarc: Psarc, usrdir, name: string) -> (data: []byte, ok: bool) {
	if entry, inside := psarc_find(psarc, name); inside {
		data = make([]byte, entry.length)
		if !psarc_read(psarc, entry, 0, data) {
			delete(data)
			return nil, false
		}
		return data, true
	}
	error: os.Error
	data, error = os.read_entire_file(join_path(usrdir, name), context.allocator)
	return data, error == nil
}

@(private = "file")
be_u40 :: proc(bytes: []byte, offset: int) -> i64 {
	return i64(tk5.be_u32(bytes, offset)) << 8 | i64(bytes[offset + 4])
}

@(private = "file")
join_path :: proc(folder, name: string) -> string {
	return strings.concatenate({folder, "/", name}, context.temp_allocator)
}
