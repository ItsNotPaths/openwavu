package server

// (hole network-files :tags server :needs titlepack-hash :sev blocker) no files role: no HTTPS (mbedTLS, certbot certs, SIGHUP reload, or plain HTTP behind a proxy), no /key /store /versions /files /release /regions /submit /note, no store.db, no review CLI (approve signs and cuts the front tar).
serve_files :: proc(port: int) {}
