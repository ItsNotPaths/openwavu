#!/usr/bin/env bash
# Dependencies into vendor/: wasmtime's C API and the SQLite amalgamation. Delete a vendor/ folder to refetch it.
set -euo pipefail
cd "$(dirname "$0")"
WASMTIME=v49.0.2
SQLITE=3530400 # 3.53.4
SQLITE_SHA3=628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e
mkdir -p vendor

if [ ! -d vendor/wasmtime ]; then
	case "$(uname -s)-$(uname -m)" in
		Linux-x86_64) target=x86_64-linux ;;
		Linux-aarch64) target=aarch64-linux ;;
		Darwin-arm64) target=aarch64-macos ;;
		Darwin-x86_64) target=x86_64-macos ;;
		*) echo "download-deps: no wasmtime build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
	esac
	name=wasmtime-$WASMTIME-$target-c-api
	curl -fL --retry 3 "https://github.com/bytecodealliance/wasmtime/releases/download/$WASMTIME/$name.tar.xz" | tar xJ -C vendor
	mv "vendor/$name" vendor/wasmtime
	echo "vendor/wasmtime: $WASMTIME $target"
fi

if [ ! -f vendor/sqlite/sqlite3.c ]; then
	deps_dir=$(mktemp -d)
	trap 'rm -rf "$deps_dir"' EXIT
	curl -fL --retry 3 "https://sqlite.org/2026/sqlite-amalgamation-$SQLITE.zip" -o "$deps_dir/sqlite.zip"
	checksum=$(openssl dgst -sha3-256 -r "$deps_dir/sqlite.zip")
	if [ "${checksum%% *}" != "$SQLITE_SHA3" ]; then
		echo "download-deps: SQLite SHA3-256 mismatch" >&2
		exit 1
	fi
	unzip -q "$deps_dir/sqlite.zip" -d "$deps_dir"
	mkdir -p vendor/sqlite
	cp "$deps_dir/sqlite-amalgamation-$SQLITE/sqlite3.c" "$deps_dir/sqlite-amalgamation-$SQLITE/sqlite3.h" vendor/sqlite/
	echo "vendor/sqlite: $SQLITE"
fi
