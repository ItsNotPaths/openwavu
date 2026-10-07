package tests

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:testing"
import "../src/content"

@(test)
zip_reads_stored_deflate_and_descriptors :: proc(t: ^testing.T) {
	for fixture in ([]string{"stored", "deflated", "descriptor"}) {
		data, err := os.read_entire_file(fmt.tprintf("tests/ref/%s.zip", fixture), context.allocator)
		if !testing.expect_value(t, err, nil) do continue
		files, ok := content.read_zip(data)
		delete(data)
		defer content.destroy_zip(files)
		if !testing.expect(t, ok, fixture) do continue
		testing.expect_value(t, len(files), 4)
		testing.expect_value(t, string(files["overlay.db"]), "SQLite fixture\x00")
		anim := files["anims/test.anim"]
		testing.expect_value(t, len(anim), 512)
		for i := 0; i + 4 <= len(anim); i += 4 do testing.expect_value(t, string(anim[i:i + 4]), "OWAN")
		testing.expect_value(t, len(files["empty"]), 0)
		png := files["images/λ.png"]
		testing.expect_value(t, len(png), 256)
		for b, i in png do testing.expect_value(t, b, byte(i))
	}
}

@(test)
zip_refuses_unsafe_or_corrupt_archives :: proc(t: ^testing.T) {
	for fixture in ([]string{"zip64", "traversal", "backslash", "unsupported", "crc", "encrypted"}) {
		data, err := os.read_entire_file(fmt.tprintf("tests/ref/%s.zip", fixture), context.allocator)
		if !testing.expect_value(t, err, nil) do continue
		files, ok := content.read_zip(data)
		delete(data)
		testing.expect(t, !ok && files == nil, fixture)
	}
}

@(test)
zip_checks_directory_and_end_record :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("tests/ref/stored.zip", context.allocator)
	if !testing.expect_value(t, err, nil) do return
	defer delete(data)
	for size in 0 ..< len(data) {
		files, ok := content.read_zip(data[:size])
		testing.expect(t, !ok && files == nil)
	}
	central := bytes.index(data, []byte{'P', 'K', 1, 2})
	data[central] = 0
	files, ok := content.read_zip(data)
	testing.expect(t, !ok && files == nil)
	empty_data, empty_err := os.read_entire_file("tests/ref/empty.zip", context.temp_allocator)
	if !testing.expect_value(t, empty_err, nil) do return
	files, ok = content.read_zip(empty_data)
	testing.expect(t, ok && len(files) == 0)
	content.destroy_zip(files)
}
