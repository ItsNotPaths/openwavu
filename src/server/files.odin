package server

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import "../titlepack"

// The files role (docs/network.md): `ls` is the store. A tar dropped in the packs folder is incorporated: renamed to
// <id>@<version>.tar, its front cut to <id>@<version>.front.tar, its thumb.png copied to <id>@<version>.thumb.png,
// and all of them hashed into <id>@<version>.sha256, written last. Each request reads the folder again, so `--prep` in another process needs no restart.
PACKS_DIR :: "/var/lib/openwavu/packs"
FILES_ENDPOINT :: "127.0.0.1:9280"  // Apache proxies openwavu.paths.place here
REQUEST_MAX :: 8192

// (hole network-files :tags server) the files role has no /release /regions /submit /note, no review CLI, and serves plain HTTP only (TLS is Apache's).

// Every tar in dir that is not incorporated yet.
incorporate_all :: proc(dir: string) {
	names, err := folder_names(dir)
	if err != "" {
		fmt.eprintfln("files: %s", err)
		return
	}
	for name in names {
		if !strings.has_suffix(name, ".tar") || strings.has_suffix(name, ".front.tar") do continue
		if os.exists(in_folder(dir, sidecar_name(strings.trim_suffix(name, ".tar")))) do continue
		if err = incorporate(dir, name); err != "" do fmt.eprintfln("files: %s: %s", name, err)
		else do fmt.eprintfln("files: %s incorporated", name)
	}
}

@(private = "file")
incorporate :: proc(dir, name: string) -> (err: string) {
	path := in_folder(dir, name)
	manifest, read := titlepack.read_manifest(path, context.temp_allocator)
	if !read do return "no pack.toml first in the tar"
	tp, parsed := titlepack.read_titlepack(manifest, context.temp_allocator)
	if !parsed do return "pack.toml does not read"
	if !plain_name(tp.id) || !plain_name(tp.version) do return "the id or version has characters a file name can not"
	stem := fmt.tprintf("%s@%s", tp.id, tp.version)
	tar_name := strings.concatenate({stem, ".tar"}, context.temp_allocator)
	tar_path := in_folder(dir, tar_name)
	if name != tar_name {
		if os.exists(tar_path) do return fmt.tprintf("%s is already here", tar_name)
		if os.rename(path, tar_path) != nil do return "can not rename it"
	}
	front_name := strings.concatenate({stem, ".front.tar"}, context.temp_allocator)
	if err = cut_front(tar_path, in_folder(dir, front_name)); err != "" do return
	cut := make([dynamic]string, context.temp_allocator)
	append(&cut, tar_name, front_name)
	thumb_name := strings.concatenate({stem, ".thumb.png"}, context.temp_allocator)
	if has_thumb, thumb_err := copy_thumb(tar_path, in_folder(dir, thumb_name)); thumb_err != "" do return thumb_err
	else if has_thumb do append(&cut, thumb_name)
	sums: strings.Builder
	strings.builder_init(&sums, context.temp_allocator)
	for file in cut {
		sum, hashed := sha256_hex(in_folder(dir, file))
		if !hashed do return fmt.tprintf("can not hash %s", file)
		fmt.sbprintf(&sums, "%s  %s\n", sum, file)
	}
	sidecar := in_folder(dir, sidecar_name(stem))
	part := strings.concatenate({sidecar, ".part"}, context.temp_allocator)
	if os.write_entire_file(part, sums.buf[:]) != nil || os.rename(part, sidecar) != nil do return "can not write the hashes"
	return
}

// pack.toml, the front, its font and the files its elements use: what the launcher shows before a download.
@(private = "file")
cut_front :: proc(tar_path, out_path: string) -> (err: string) {
	files, opened := titlepack.open_files(tar_path)
	if !opened do return "the tar does not read"
	defer titlepack.close_files(&files)
	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, titlepack.MANIFEST)
	if text, has_front := titlepack.read_file(files, titlepack.FRONT); has_front {
		append(&paths, titlepack.FRONT)
		front, front_err := titlepack.read_front(string(text), context.temp_allocator)
		if front_err != "" do return fmt.tprintf("the front does not read: %s", front_err)
		append(&paths, front.font)
		for element in front.elements do append(&paths, element.file)
	}
	used := make([dynamic]string, context.temp_allocator)
	for path in paths do if path != "" && path in files.files && !slice.contains(used[:], path) do append(&used, path)
	return titlepack.write_tar_of(files, used[:], out_path)
}

@(private = "file")
copy_thumb :: proc(tar_path, out_path: string) -> (has: bool, err: string) {
	files, opened := titlepack.open_files(tar_path)
	if !opened do return false, "the tar does not read"
	defer titlepack.close_files(&files)
	thumb, found := titlepack.read_file(files, titlepack.THUMB)
	if !found do return false, ""
	if os.write_entire_file(out_path, thumb) != nil do return false, "can not write the thumb"
	return true, ""
}

// Incorporated packs, newest version first within each id.
listing :: proc(dir: string) -> (packs: []titlepack.Listed) {
	names, err := folder_names(dir)
	if err != "" do return
	found := make([dynamic]titlepack.Listed, context.temp_allocator)
	for name in names {
		if !strings.has_suffix(name, ".sha256") do continue
		stem := strings.trim_suffix(name, ".sha256")
		id, at, version := strings.partition(stem, "@")
		if at == "" do continue
		pack := titlepack.Listed{id = id, version = version}
		pack.sha256, pack.size = listed_file(dir, name, strings.concatenate({stem, ".tar"}, context.temp_allocator))
		pack.front_sha256, pack.front_size = listed_file(dir, name, strings.concatenate({stem, ".front.tar"}, context.temp_allocator))
		pack.thumb_sha256, pack.thumb_size = listed_file(dir, name, strings.concatenate({stem, ".thumb.png"}, context.temp_allocator))
		if pack.sha256 != "" && pack.front_sha256 != "" do append(&found, pack)
	}
	slice.sort_by(found[:], proc(a, b: titlepack.Listed) -> bool {
		if a.id != b.id do return a.id < b.id
		return version_less(b.version, a.version)
	})
	return found[:]
}

// A file's hash from the sidecar, and its size on disk.
@(private = "file")
listed_file :: proc(dir, sidecar, file: string) -> (sha256: string, size: i64) {
	text, err := os.read_entire_file(in_folder(dir, sidecar), context.temp_allocator)
	if err != nil do return
	lines := string(text)
	for line in strings.split_lines_iterator(&lines) {
		sum, _, name := strings.partition(line, "  ")
		if name != file do continue
		info, stat_err := os.stat(in_folder(dir, file), context.temp_allocator)
		if stat_err != nil do return
		return sum, info.size
	}
	return
}

// "1.10" after "1.9": dot-separated numbers compared as numbers, anything else as text.
version_less :: proc(a, b: string) -> bool {
	a_parts, b_parts := strings.split(a, ".", context.temp_allocator), strings.split(b, ".", context.temp_allocator)
	for index in 0 ..< min(len(a_parts), len(b_parts)) {
		a_number, a_is := strconv.parse_int(a_parts[index])
		b_number, b_is := strconv.parse_int(b_parts[index])
		if a_is && b_is && a_number != b_number do return a_number < b_number
		if !(a_is && b_is) && a_parts[index] != b_parts[index] do return a_parts[index] < b_parts[index]
	}
	return len(a_parts) < len(b_parts)
}

// --- HTTP: GET /store, /versions/<id>, /files/<name>. One thread per connection, Connection: close.

serve_files :: proc(dir: string) -> (ok: bool) {
	endpoint, _ := net.parse_endpoint(FILES_ENDPOINT)
	listener, err := net.listen_tcp(endpoint)
	if err != nil {
		fmt.eprintfln("files: can not listen on %s: %v", FILES_ENDPOINT, err)
		return
	}
	fmt.eprintfln("files: http on %s, packs in %s", FILES_ENDPOINT, dir)
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		thread.create_and_start_with_poly_data2(client, dir, answer, self_cleanup = true)
	}
}

@(private = "file")
answer :: proc(client: net.TCP_Socket, dir: string) {
	defer net.close(client)
	defer free_all(context.temp_allocator)
	request: [REQUEST_MAX]byte
	size := 0
	for size < len(request) && !strings.contains(string(request[:size]), "\r\n\r\n") {
		got, err := net.recv_tcp(client, request[size:])
		if err != nil || got == 0 do return
		size += got
	}
	method, _, rest := strings.partition(string(request[:size]), " ")
	target, _, _ := strings.partition(rest, " ")
	if method != "GET" {
		respond(client, "405 Method Not Allowed", "text/plain", "GET only\n")
		return
	}
	switch {
	case target == "/store":
		respond(client, "200 OK", "text/plain", pack_lines(listing(dir), "", true))
	case strings.has_prefix(target, "/versions/"):
		respond(client, "200 OK", "text/plain", pack_lines(listing(dir), strings.trim_prefix(target, "/versions/"), false))
	case strings.has_prefix(target, "/files/"):
		send_pack_file(client, dir, strings.trim_prefix(target, "/files/"))
	case:
		respond(client, "404 Not Found", "text/plain", "not found\n")
	}
}

// latest_only: the first, newest, line of each id. id "" is every id.
@(private = "file")
pack_lines :: proc(packs: []titlepack.Listed, id: string, latest_only: bool) -> string {
	lines: strings.Builder
	strings.builder_init(&lines, context.temp_allocator)
	last_id := ""
	for pack in packs {
		if id != "" && pack.id != id do continue
		if latest_only && pack.id == last_id do continue
		last_id = pack.id
		strings.write_string(&lines, titlepack.listing_line(pack))
	}
	return strings.to_string(lines)
}

// Only files the listing names.
@(private = "file")
send_pack_file :: proc(client: net.TCP_Socket, dir, name: string) {
	listed := false
	for pack in listing(dir) {
		stem := fmt.tprintf("%s@%s", pack.id, pack.version)
		for suffix in ([]string{".tar", ".front.tar"}) do listed ||= name == strings.concatenate({stem, suffix}, context.temp_allocator)
		listed ||= pack.thumb_sha256 != "" && name == strings.concatenate({stem, ".thumb.png"}, context.temp_allocator)
	}
	if !listed {
		respond(client, "404 Not Found", "text/plain", "not found\n")
		return
	}
	data, err := virtual.map_file_from_path(in_folder(dir, name), {.Read})
	if err != nil {
		respond(client, "404 Not Found", "text/plain", "not found\n")
		return
	}
	defer virtual.unmap_file(data)
	head := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\nContent-Length: %d\r\nCache-Control: public, max-age=31536000, immutable\r\nConnection: close\r\n\r\n", len(data))
	if _, send_err := net.send_tcp(client, transmute([]byte)head); send_err == nil do net.send_tcp(client, data)
}

@(private = "file")
respond :: proc(client: net.TCP_Socket, status, content_type, body: string) {
	head := fmt.tprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", status, content_type, len(body))
	net.send_tcp(client, transmute([]byte)strings.concatenate({head, body}, context.temp_allocator))
}

@(private = "file")
folder_names :: proc(dir: string) -> (names: []string, err: string) {
	entries, read_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if read_err != nil do return nil, fmt.tprintf("can not read %s", dir)
	found := make([dynamic]string, context.temp_allocator)
	for entry in entries do append(&found, entry.name)
	return found[:], ""
}

@(private = "file")
in_folder :: proc(dir, name: string) -> string {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

@(private = "file")
sidecar_name :: proc(stem: string) -> string {
	return strings.concatenate({stem, ".sha256"}, context.temp_allocator)
}

@(private = "file")
plain_name :: proc(text: string) -> bool {
	if text == "" || text == "." || text == ".." do return false
	for character in text do if !(character == '.' || character == '-' || character == '_' || (character >= '0' && character <= '9') || (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z')) do return false
	return true
}

@(private = "file")
sha256_hex :: proc(path: string) -> (text: string, ok: bool) {
	digest, err := hash.hash_file_by_name(.SHA256, path, allocator = context.temp_allocator)
	if err != nil do return
	return string(hex.encode(digest, context.temp_allocator)), true
}
