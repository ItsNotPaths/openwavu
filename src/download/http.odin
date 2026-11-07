package download

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"
import "core:sync"
import curl "vendor:curl"

// Distros keep the system's CA bundle in one of these; none is built into libcurl.
CA_BUNDLES :: [?]string{"/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem", "/etc/ssl/ca-bundle.pem"}
CONNECT_TIMEOUT_S :: 10

// A running GET's byte counts, and its stop switch; shared with other threads through atomics.
Progress :: struct {
	received, total: i64,  // total 0 until the server says
	cancel:          bool,
}

// Before any thread starts a GET: curl's global init is not thread safe.
@(init)
http_init :: proc "contextless" () {
	curl.global_init(curl.GLOBAL_DEFAULT)
}

// A GET; anything but a 2xx answer is err. body is in allocator.
http_get :: proc(url: string, progress: ^Progress = nil, allocator := context.allocator) -> (body: []byte, err: string) {
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
	if progress != nil {
		report :: proc "c" (data: rawptr, total, received, _, _: curl.off_t) -> c.int {
			progress := (^Progress)(data)
			sync.atomic_store(&progress.total, total)
			sync.atomic_store(&progress.received, received)
			return sync.atomic_load(&progress.cancel) ? 1 : 0
		}
		curl.easy_setopt(handle, .NOPROGRESS, c.long(0))
		curl.easy_setopt(handle, .XFERINFOFUNCTION, report)
		curl.easy_setopt(handle, .XFERINFODATA, progress)
	}
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
