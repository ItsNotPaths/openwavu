package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../src/titlepack"

TAR_DIR :: "build/test_tar"
LONG_PATH :: "anims/a_folder_name_that_is_long_enough/to_push_the_path/over_the_hundred_byte_ustar_name_field/0.anim"

// A packed folder reads back with the same files and bytes, and packing it twice gives the same tar.
@(test)
tar_round_trip :: proc(t: ^testing.T) {
	os.remove_all(TAR_DIR)
	defer os.remove_all(TAR_DIR)
	Tar_File :: struct {path, text: string}
	files := []Tar_File{
		{"pack.toml", "id = \"x\"\n"},
		{"empty.bin", ""},
		{"ui/34.png", "not really a png"},
		{LONG_PATH, "long"},
	}
	for f in files {
		full := fmt.tprintf("%s/in/%s", TAR_DIR, f.path)
		os.make_directory_all(full[:strings.last_index_byte(full, '/')])
		testing.expect_value(t, os.write_entire_file(full, f.text), nil)
	}
	testing.expect_value(t, titlepack.write_tar(TAR_DIR + "/in", TAR_DIR + "/a.tar"), "")
	testing.expect_value(t, titlepack.write_tar(TAR_DIR + "/in", TAR_DIR + "/b.tar"), "")
	a, _ := os.read_entire_file(TAR_DIR + "/a.tar", context.temp_allocator)
	b, _ := os.read_entire_file(TAR_DIR + "/b.tar", context.temp_allocator)
	testing.expect(t, string(a) == string(b), "packing twice gave different tars")

	index, ok := titlepack.read_tar(a)
	if !testing.expect(t, ok, "tar did not read") do return
	defer titlepack.destroy_tar(index)
	testing.expect_value(t, len(index), len(files))
	for f in files {
		entry, has := index[f.path]
		if testing.expect(t, has, f.path) do testing.expect_value(t, string(a[entry.offset:][:entry.size]), f.text)
	}
}

// Paths that leave the pack, a path twice, and entries that are not plain files are refused.
@(test)
tar_refuses_unsafe_entries :: proc(t: ^testing.T) {
	refused := [][]byte{
		tar_of({header("../x")}),
		tar_of({header("a/../../x")}),
		tar_of({header("/etc/passwd")}),
		tar_of({header("link", kind = '2')}),
		tar_of({header("twice.txt"), header("twice.txt")}),
	}
	for data, i in refused {
		files, ok := titlepack.read_tar(data)
		testing.expectf(t, !ok, "case %d was accepted", i)
		if ok do titlepack.destroy_tar(files)
	}
}

// GNU tar writes names over 100 bytes as an `L` entry holding the name.
@(test)
tar_reads_gnu_long_names :: proc(t: ^testing.T) {
	name := LONG_PATH + "\x00"
	body := make([]byte, titlepack.TAR_BLOCK, context.temp_allocator)
	copy(body, name)
	files, ok := titlepack.read_tar(tar_of({header("././@LongLink", len(name), 'L'), body, header(LONG_PATH[:100])}))
	if !testing.expect(t, ok, "tar did not read") do return
	defer titlepack.destroy_tar(files)
	testing.expect(t, LONG_PATH in files, "long name lost")
	testing.expect_value(t, len(files), 1)
}

// One header block; the checksum is redone for the new type.
header :: proc(path: string, size := 0, kind: byte = '0') -> []byte {
	h := make([]byte, titlepack.TAR_BLOCK, context.temp_allocator)
	copy(h, path)
	fmt.bprintf(h[124:136], "%011o\x00", size)
	h[156] = kind
	copy(h[257:265], "ustar\x0000")
	copy(h[148:156], "        ")
	sum := 0
	for v in h do sum += int(v)
	fmt.bprintf(h[148:156], "%06o\x00 ", sum)
	return h
}

// Blocks plus the end marker.
tar_of :: proc(blocks: [][]byte) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	for b in blocks do append(&out, ..b)
	resize(&out, len(out) + 2 * titlepack.TAR_BLOCK)
	return out[:]
}
