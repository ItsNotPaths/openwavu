// T55DATA1.BIN archive: file table in the EBOOT, per-entry XOR, zlib. tk5decomp data.md §1-2.
package tk5_formats

import "vendor:zlib"

SECTOR :: 0x800
ENTRY_SIZE :: 0x1c

Entry :: struct {
	sector:      u32,  // offset in T55DATA1 = sector * SECTOR
	stored_size: u32,  // 0 or 0xffffffff: no file
	size:        u32,  // != stored_size: the entry is zlib
	word_sum:    u32,  // sum of LE words; a mismatch means the entry is XOR encrypted
	key:         u32,  // XOR key: k = k*5 + 3 per LE word, reset every SECTOR bytes
}

entry_offset :: proc(e: Entry) -> i64 {return i64(e.sector) * SECTOR}
entry_missing :: proc(e: Entry) -> bool {return e.stored_size == 0 || e.stored_size == 0xffffffff}

read_file_table :: proc(eboot: []byte, build: Build, allocator := context.allocator) -> (table: []Entry, ok: bool) {
	if build.table_offset + build.table_count * ENTRY_SIZE > len(eboot) do return nil, false
	table = make([]Entry, build.table_count, allocator)
	for &e, i in table {
		r := eboot[build.table_offset + i * ENTRY_SIZE:]
		e = {be_u32(r, 0x00), be_u32(r, 0x04), be_u32(r, 0x08), be_u32(r, 0x0c), be_u32(r, 0x14)}
	}
	return table, true
}

// Raw entry bytes -> decrypted, inflated bytes. A second LZ layer (lz.odin) may remain.
// Decrypts `stored` in place.
unpack_entry :: proc(e: Entry, stored: []byte, allocator := context.allocator) -> (data: []byte, ok: bool) {
	if len(stored) != int(e.stored_size) do return nil, false
	if word_sum(stored) != e.word_sum do decrypt(stored, e.key)
	if e.size == e.stored_size do return stored, true
	data = make([]byte, e.size, allocator)
	size := zlib.uLongf(e.size)
	if zlib.uncompress(raw_data(data), &size, raw_data(stored), zlib.uLong(len(stored))) != zlib.OK || size != zlib.uLongf(e.size) {
		delete(data, allocator)
		return nil, false
	}
	return data, true
}

@(private)
word_sum :: proc(b: []byte) -> (sum: u32) {
	for i := 0; i + 4 <= len(b); i += 4 do sum += le_u32(b, i)
	return sum
}

@(private)
decrypt :: proc(b: []byte, key: u32) {
	for block := 0; block < len(b); block += SECTOR {
		k := key
		end := min(block + SECTOR, len(b))
		for i := block; i < end; i += 4 {
			for j in 0 ..< min(4, end - i) do b[i + j] ~= u8(k >> uint(8 * j))  // a short tail uses the low key bytes
			k = k * 5 + 3
		}
	}
}
