package server

import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:thread"
import "core:time"
import "../release"
import "../titlepack"

// The files role over HTTP: GET /store, /versions/<id>, /files/<name>, /release. One thread per connection, Connection: close.
FILES_ENDPOINT :: "127.0.0.1:9280"  // the box's TLS proxy (Caddy) forwards here
REQUEST_MAX :: 8192
REQUEST_TIMEOUT :: 30 * time.Second  // a silent client frees its thread after this

// (hole network-files :tags server) the files role has no /regions /submit /note, no review CLI, and serves plain HTTP only (TLS is Apache's).

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
	net.set_option(client, .Receive_Timeout, REQUEST_TIMEOUT)
	net.set_option(client, .Send_Timeout, REQUEST_TIMEOUT)
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
	case target == "/release":
		respond(client, "200 OK", "text/plain", fmt.tprintf("%s\n", release.current()))
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
		stem := titlepack.pack_name(pack.id, pack.version)
		for suffix in ([]string{".tar", ".front.tar"}) do listed ||= name == strings.concatenate({stem, suffix}, context.temp_allocator)
		listed ||= pack.thumb_sha256 != "" && name == strings.concatenate({stem, ".thumb.png"}, context.temp_allocator)
	}
	if !listed {
		respond(client, "404 Not Found", "text/plain", "not found\n")
		return
	}
	data, err := virtual.map_file_from_path(titlepack.join_path(dir, name), {.Read})
	if err != nil {
		respond(client, "404 Not Found", "text/plain", "not found\n")
		return
	}
	defer virtual.unmap_file(data)
	content_type := strings.has_suffix(name, ".png") ? "image/png" : "application/x-tar"
	head := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: public, max-age=31536000, immutable\r\nConnection: close\r\n\r\n", content_type, len(data))
	if _, send_err := net.send_tcp(client, transmute([]byte)head); send_err == nil do net.send_tcp(client, data)
}

@(private = "file")
respond :: proc(client: net.TCP_Socket, status, content_type, body: string) {
	head := fmt.tprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", status, content_type, len(body))
	net.send_tcp(client, transmute([]byte)strings.concatenate({head, body}, context.temp_allocator))
}
