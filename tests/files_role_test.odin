package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "../src/content"
import "../src/server"
import "../src/titlepack"

FILES_DIR :: "build/files_role_test"

// A tar dropped under any name is incorporated, and its store line reads back on the client with hashes that check
// the files the server sends; the front holds pack.toml.
@(test)
dropped_pack_lists_and_checks :: proc(t: ^testing.T) {
	os.remove_all(FILES_DIR)
	defer os.remove_all(FILES_DIR)
	os.make_directory_all(FILES_DIR + "/pack")
	os.make_directory_all(FILES_DIR + "/store")
	_ = os.write_entire_file(FILES_DIR + "/pack/" + titlepack.MANIFEST, transmute([]byte)string("id = \"drop\"\nversion = \"1.2\"\n"))
	_ = os.write_entire_file(FILES_DIR + "/pack/" + titlepack.THUMB, transmute([]byte)string("not really a png"))
	if !testing.expect_value(t, titlepack.write_tar(FILES_DIR + "/pack", FILES_DIR + "/store/upload.tar"), "") do return

	server.incorporate_all(FILES_DIR + "/store")
	served := server.listing(FILES_DIR + "/store")
	if !testing.expect_value(t, len(served), 1) do return
	listed := titlepack.read_listing(titlepack.listing_line(served[0]), context.temp_allocator)
	if !testing.expect_value(t, len(listed), 1) do return
	pack := listed[0]
	testing.expect_value(t, pack.id, "drop")
	testing.expect_value(t, pack.version, "1.2")

	for file in ([][2]string{{"drop@1.2.tar", pack.sha256}, {"drop@1.2.front.tar", pack.front_sha256}, {"drop@1.2.thumb.png", pack.thumb_sha256}}) {
		data, err := os.read_entire_file(fmt.tprintf("%s/store/%s", FILES_DIR, file[0]), context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s is missing", file[0]) do continue
		testing.expectf(t, content.verify_download(data, file[1]), "%s does not match its listed hash", file[0])
	}
	manifest, read := titlepack.read_manifest(FILES_DIR + "/store/drop@1.2.front.tar", context.temp_allocator)
	testing.expect(t, read && manifest != "", "the front has no pack.toml")
}
