#!/usr/bin/env bash
# Dependencies into vendor/: wasmtime's C API, the SQLite amalgamation, Clay (UI layout) with its Odin binding,
# SDL3_ttf built static with FreeType, and the UI font. Delete a vendor/ folder to refetch it.
set -euo pipefail
cd "$(dirname "$0")"
WASMTIME=v49.0.2
SQLITE=3530400 # 3.53.4
SQLITE_SHA3=628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e
CLAY=v0.14
SDL_TTF=3.2.2
SDL_TTF_SHA256=63547d58d0185c833213885b635a2c0548201cc8f301e6587c0be1a67e1e045d
FREETYPE=2-13-3
FREETYPE_SHA256=bc5c898e4756d373e0d991bab053036c5eb2aa7c0d5c67e8662ddc6da40c4103
FONTS_COMMIT=8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5 # google/fonts
MICHROMA_SHA256=b62301163788bc5b7f8fcac0b74b184e34e1827e577b499ecb724da065098f87
mkdir -p vendor

# fetch <url> <file> <sha256>
fetch() {
	curl -fL --retry 3 "$1" -o "$2"
	checksum=$(openssl dgst -sha256 -r "$2")
	if [ "${checksum%% *}" != "$3" ]; then
		echo "download-deps: SHA-256 mismatch for $1" >&2
		exit 1
	fi
}

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

if [ ! -f vendor/clay/clay.h ]; then
	clay_dir=$(mktemp -d)
	curl -fL --retry 3 "https://github.com/nicbarker/clay/archive/refs/tags/$CLAY.tar.gz" | tar xz -C "$clay_dir" --strip-components=1
	mkdir -p vendor/clay
	cp "$clay_dir/clay.h" "$clay_dir/bindings/odin/clay-odin/clay.odin" vendor/clay/
	rm -rf "$clay_dir"
	echo "vendor/clay: $CLAY"
fi

if [ ! -f vendor/sdl3_ttf/libSDL3_ttf.a ]; then
	ttf_dir=$(mktemp -d)
	fetch "https://github.com/libsdl-org/SDL_ttf/releases/download/release-$SDL_TTF/SDL3_ttf-$SDL_TTF.tar.gz" "$ttf_dir/ttf.tar.gz" "$SDL_TTF_SHA256"
	fetch "https://github.com/freetype/freetype/archive/refs/tags/VER-$FREETYPE.tar.gz" "$ttf_dir/freetype.tar.gz" "$FREETYPE_SHA256"
	mkdir -p "$ttf_dir/src" && tar xzf "$ttf_dir/ttf.tar.gz" -C "$ttf_dir/src" --strip-components=1
	rm -rf "$ttf_dir/src/external/freetype" && mkdir -p "$ttf_dir/src/external/freetype"
	tar xzf "$ttf_dir/freetype.tar.gz" -C "$ttf_dir/src/external/freetype" --strip-components=1
	# English-only UI: no HarfBuzz shaping, no SVG glyphs.
	cmake -S "$ttf_dir/src" -B "$ttf_dir/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
		-DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF >/dev/null
	cmake --build "$ttf_dir/build" -j >/dev/null
	mkdir -p vendor/sdl3_ttf
	cp "$ttf_dir/build/libSDL3_ttf.a" vendor/sdl3_ttf/
	rm -rf "$ttf_dir"
	echo "vendor/sdl3_ttf: $SDL_TTF, freetype $FREETYPE"
fi

if [ ! -f vendor/fonts/Michroma-Regular.ttf ]; then
	mkdir -p vendor/fonts
	fetch "https://raw.githubusercontent.com/google/fonts/$FONTS_COMMIT/ofl/michroma/Michroma-Regular.ttf" vendor/fonts/Michroma-Regular.ttf "$MICHROMA_SHA256"
	curl -fL --retry 3 "https://raw.githubusercontent.com/google/fonts/$FONTS_COMMIT/ofl/michroma/OFL.txt" -o vendor/fonts/Michroma-OFL.txt
	echo "vendor/fonts: Michroma"
fi
