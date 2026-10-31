// Overlays: a zip with overlay.db (same schema, changed rows and a `removed` table) plus new files.
package content

import "core:bytes"
import "core:compress/zlib"
import "core:hash"
import "core:strings"

read_zip :: proc(data: []byte, allocator := context.allocator) -> (files: map[string][]byte, ok: bool) {
	context.allocator = allocator
	defer if !ok {
		destroy_zip(files)
		files = nil
	}
	end: ^Zip_End
	for off := len(data) - size_of(Zip_End); off >= max(0, len(data) - size_of(Zip_End) - 65535); off -= 1 {
		candidate, valid := zip_record(data, off, Zip_End)
		if valid && candidate.signature == 0x06054b50 && off + size_of(Zip_End) + int(candidate.comment_size) == len(data) {
			end = candidate
			break
		}
	}
	if end == nil || end.disk != 0 || end.directory_disk != 0 || end.disk_entries != end.entries do return files, false
	if end.entries == 0xffff || end.directory_size == 0xffffffff || end.directory_offset == 0xffffffff do return files, false
	end_offset := len(data) - size_of(Zip_End) - int(end.comment_size)
	if locator, valid := zip_record(data, end_offset - 20, u32le); valid && locator^ == 0x07064b50 do return files, false
	off := int(end.directory_offset)
	limit := off + int(end.directory_size)
	if limit != end_offset do return files, false
	files = make(map[string][]byte)
	for _ in 0 ..< int(end.entries) {
		entry, valid := zip_record(data[:limit], off, Zip_Central)
		if !valid || entry.signature != 0x02014b50 || entry.disk != 0 do return files, false
		if u16(entry.flags) & ~u16(0x080e) != 0 || (entry.method != 0 && entry.method != 8) do return files, false
		if entry.size == 0xffffffff || entry.stored_size == 0xffffffff || entry.local_offset == 0xffffffff do return files, false
		start := off + size_of(Zip_Central)
		next := start + int(entry.name_size) + int(entry.extra_size) + int(entry.comment_size)
		if next > limit do return files, false
		name := string(data[start:start + int(entry.name_size)])
		if !zip_path(name) || !zip_extra(data[start + int(entry.name_size):next - int(entry.comment_size)]) do return files, false
		if _, exists := files[name]; exists do return files, false
		local, local_valid := zip_record(data[:int(end.directory_offset)], int(entry.local_offset), Zip_Local)
		if !local_valid || local.signature != 0x04034b50 || local.method != entry.method || local.flags != entry.flags do return files, false
		if local.size == 0xffffffff || local.stored_size == 0xffffffff do return files, false
		if local.flags & 8 == 0 && (local.size != entry.size || local.stored_size != entry.stored_size || local.crc != entry.crc) do return files, false
		start = int(entry.local_offset) + size_of(Zip_Local)
		payload := start + int(local.name_size) + int(local.extra_size)
		last := payload + int(entry.stored_size)
		if last > int(end.directory_offset) || string(data[start:start + int(local.name_size)]) != name do return files, false
		if !zip_extra(data[start + int(local.name_size):payload]) do return files, false
		stored := data[payload:last]
		buf: bytes.Buffer
		defer bytes.buffer_destroy(&buf)
		if entry.method == 8 {
			if int(entry.size) > int(entry.stored_size) * 1032 do return files, false // past deflate's maximum ratio
			bytes.buffer_init_allocator(&buf, 0, int(entry.size))
			if zlib.inflate(stored, &buf, raw = true, expected_output_size = int(entry.size)) != nil do return files, false
			stored = bytes.buffer_to_bytes(&buf)
		}
		if len(stored) != int(entry.size) || hash.crc32(stored) != u32(entry.crc) do return files, false
		if !strings.has_suffix(name, "/") {
			contents := make([]byte, len(stored))
			copy(contents, stored)
			files[strings.clone(name)] = contents
		}
		off = next
	}
	return files, off == limit
}

// The returned files own their names and contents.
destroy_zip :: proc(files: map[string][]byte, allocator := context.allocator) {
	context.allocator = allocator
	for name, contents in files {
		delete(name)
		delete(contents)
	}
	delete(files)
}

@(private = "file")
Zip_End :: struct #packed {
	signature: u32le,
	disk, directory_disk, disk_entries, entries: u16le,
	directory_size, directory_offset: u32le,
	comment_size: u16le,
}

@(private = "file")
Zip_Central :: struct #packed {
	signature: u32le,
	creator_version, version, flags, method, time, date: u16le,
	crc, stored_size, size: u32le,
	name_size, extra_size, comment_size, disk, internal_attributes: u16le,
	external_attributes, local_offset: u32le,
}

@(private = "file")
Zip_Local :: struct #packed {
	signature: u32le,
	version, flags, method, time, date: u16le,
	crc, stored_size, size: u32le,
	name_size, extra_size: u16le,
}

@(private = "file")
zip_record :: proc(data: []byte, off: int, $T: typeid) -> (^T, bool) {
	if off < 0 || off > len(data) || size_of(T) > len(data) - off do return nil, false
	return cast(^T)raw_data(data[off:]), true
}

@(private = "file")
zip_extra :: proc(data: []byte) -> bool {
	Header :: struct #packed {id, size: u16le}
	for off := 0; off < len(data); {
		header, valid := zip_record(data, off, Header)
		if !valid || header.id == 1 do return false
		off += size_of(Header) + int(header.size)
		if off > len(data) do return false
	}
	return true
}

@(private = "file")
zip_path :: proc(name: string) -> bool {
	if len(name) == 0 || name[0] == '/' || name[0] == '\\' || strings.contains_rune(name, 0) || strings.contains_rune(name, ':') do return false
	start := 0
	for b, i in name {
		if b == '/' || b == '\\' {
			if name[start:i] == ".." do return false
			start = i + 1
		}
	}
	return name[start:] != ".."
}

// (hole overlay-apply :tags content :needs (pack-open) :sev blocker) overlays are not applied (ATTACH, INSERT OR REPLACE, removed rows), and an overlay does not name the database it edits.
apply_overlay :: proc(p: ^Pack, zip: []byte) -> (ok: bool) {
	return false
}

// (hole overlay-merge :tags content :needs overlay-apply) two overlays that grow a list both move it to the end of its table and take the same new indices; no merge rule.
// (hole overlay-write :tags (content editor) :needs pack-open) no way to diff an edited pack into an overlay zip.
write_overlay :: proc(base, edited: ^Pack, path: string) -> (ok: bool) {
	return false
}

