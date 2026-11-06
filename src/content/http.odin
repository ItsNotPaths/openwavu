package content

// (hole https-client :tags (content net) :sev blocker) no HTTPS client; libcurl with mbedTLS is not vendored in download-deps.sh.
http_get :: proc(url: string) -> (body: []byte, ok: bool) {
	return nil, false
}
