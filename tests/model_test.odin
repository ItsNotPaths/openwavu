package tests

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import formats "../src/formats/tk5"

// Every mesh and texture section parses to the same data as ndp3.py / ntp3.py.
// tests/ref/models.txt comes from tests/ref/models_ref.py.
@(test)
models_match_reference :: proc(t: ^testing.T) {
	ref, ref_err := os.read_entire_file("tests/ref/models.txt", context.allocator)
	if ref_err != nil do return
	defer delete(ref)
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)

	checked := 0
	text := string(ref)
	for line in strings.split_lines_iterator(&text) {
		defer free_all(context.temp_allocator)
		fields := strings.fields(line, context.temp_allocator)
		entry, _ := strconv.parse_int(fields[1])
		e := table[entry]
		stored := make([]byte, e.stored_size, context.temp_allocator)
		os.read_at(f, stored, formats.entry_offset(e))
		data, unpacked := formats.unpack_entry(e, stored, context.temp_allocator)
		testing.expectf(t, unpacked, "entry %d did not unpack", entry)

		section, found := model_section(data, fields[2])
		testing.expectf(t, found, "%s: no section", line)
		got := fields[0] == "ndp3" ? ndp3_summary(section) : ntp3_summary(section)
		want := strings.join(fields[3:], " ", context.temp_allocator)
		testing.expectf(t, got == want, "%s %s %s: got %s, want %s", fields[0], fields[1], fields[2], got, want)
		checked += 1
	}
	testing.expect(t, checked > 800, "too few sections checked")
}

// "2/5": section 5 of section 2; "lz": the whole entry is LZ.
model_section :: proc(data: []byte, path: string) -> ([]byte, bool) {
	if path == "lz" do return formats.unlz(data, context.temp_allocator)
	d := data
	p := path
	for part in strings.split_iterator(&p, "/") {
		i, _ := strconv.parse_int(part)
		secs, ok := formats.sections(d, context.temp_allocator)
		if !ok || i >= len(secs) do return nil, false
		d = secs[i]
	}
	return d, true
}

ndp3_summary :: proc(d: []byte) -> string {
	meshes, ok := formats.read_ndp3(d, context.temp_allocator)
	if !ok do return "parse failed"
	crc, polys, verts, tris: u32
	for m in meshes {
		bind := m.single_bind
		crc = hash.crc32(transmute([]byte)m.name, crc)
		crc = hash.crc32(mem.ptr_to_bytes(&bind), crc)
		for p in m.polys {
			crc = hash.crc32(mem.slice_to_bytes(p.positions), crc)
			crc = hash.crc32(mem.slice_to_bytes(p.normals), crc)
			crc = hash.crc32(mem.slice_to_bytes(p.uvs), crc)
			crc = hash.crc32(mem.slice_to_bytes(p.colors), crc)
			crc = hash.crc32(mem.slice_to_bytes(p.joints), crc)
			crc = hash.crc32(mem.slice_to_bytes(p.weights), crc)
			crc = hash.crc32(mem.slice_to_bytes(p.triangles), crc)
			if len(p.materials) > 0 {  // ndp3.py reads the textures of texprop 1 only
				for &tex in p.materials[0].textures do crc = hash.crc32(mem.ptr_to_bytes(&tex.hash), crc)
			}
			polys, verts, tris = polys + 1, verts + u32(len(p.positions)), tris + u32(len(p.triangles))
		}
	}
	return fmt.tprintf("%d %d %d %d %08x", len(meshes), polys, verts, tris, crc)
}

ntp3_summary :: proc(d: []byte) -> string {
	textures, ok := formats.read_ntp3(d, context.temp_allocator)
	if !ok do return "parse failed"
	crc: u32
	for &tex in textures {
		rgba, decoded := formats.decode_rgba(tex, context.temp_allocator)
		if !decoded do return fmt.tprintf("format %d did not decode", tex.format)
		crc = hash.crc32(mem.ptr_to_bytes(&tex.hash), crc)
		crc = hash.crc32(rgba, crc)
	}
	return fmt.tprintf("%d %08x", len(textures), crc)
}
