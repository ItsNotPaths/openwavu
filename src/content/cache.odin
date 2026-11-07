package content

import "core:os"
import "core:strings"

// A file from the network into path, written only when its SHA-256 (hex) matches: a mangled download never lands.
download_checked :: proc(url, sha256, path: string) -> (err: string) {
	data: []byte
	if data, err = http_get(url); err != "" do return
	defer delete(data)
	if !verify_download(data, sha256) do return "the download is damaged: its hash does not match"
	part := strings.concatenate({path, ".part"}, context.temp_allocator)
	if os.write_entire_file(part, data) != nil || os.rename(part, path) != nil do return strings.concatenate({"can not write ", path}, context.temp_allocator)
	return
}
