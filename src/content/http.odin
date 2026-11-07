package content

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"
import curl "vendor:curl"

// Distros keep the system's CA bundle in one of these; none is built into libcurl.
CA_BUNDLES :: [?]string{"/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem", "/etc/ssl/ca-bundle.pem"}
CONNECT_TIMEOUT_S :: 10

// A GET; anything but a 2xx answer is err. body is in allocator.
http_get :: proc(url: string, allocator := context.allocator) -> (body: []byte, err: string) {
	handle := curl.easy_init()
	if handle == nil do return nil, "curl did not start"
	defer curl.easy_cleanup(handle)
	write :: proc "c" (buffer: [^]byte, size, count: c.size_t, data: rawptr) -> c.size_t {
		context = runtime.default_context()
		append((^[dynamic]byte)(data), ..buffer[:size * count])
		return size * count
	}
	received := make([dynamic]byte, allocator)
	curl.easy_setopt(handle, .URL, strings.clone_to_cstring(url, context.temp_allocator))
	curl.easy_setopt(handle, .WRITEFUNCTION, write)
	curl.easy_setopt(handle, .WRITEDATA, &received)
	curl.easy_setopt(handle, .FAILONERROR, c.long(1))
	curl.easy_setopt(handle, .ACCEPT_ENCODING, cstring(""))
	curl.easy_setopt(handle, .CONNECTTIMEOUT, c.long(CONNECT_TIMEOUT_S))
	for bundle in CA_BUNDLES do if os.exists(bundle) {
		curl.easy_setopt(handle, .CAINFO, strings.clone_to_cstring(bundle, context.temp_allocator))
		break
	}
	if result := curl.easy_perform(handle); result != .E_OK {
		delete(received)
		return nil, strings.clone(string(curl.easy_strerror(result)), context.temp_allocator)
	}
	return received[:], ""
}
