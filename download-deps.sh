#!/usr/bin/env bash
# Dependencies into vendor/: zig (the C compiler for pack modules, pinned so ow build is reproducible), wasmtime's C API, the SQLite amalgamation, Clay (UI layout) with its Odin binding,
# SDL3 and SDL3_ttf built static (FreeType) with their headers for pack modules, and the UI font. Delete a vendor/ folder to refetch it.
set -euo pipefail
cd "$(dirname "$0")"
ZIG=0.16.0
WASMTIME=v49.0.2
SQLITE=3530400 # 3.53.4
SQLITE_SHA3=628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e
CLAY=v0.14
SDL=3.4.18
SDL_SHA256=9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3
SDL_TTF=3.2.2
SDL_TTF_SHA256=63547d58d0185c833213885b635a2c0548201cc8f301e6587c0be1a67e1e045d
FREETYPE=2-13-3
FREETYPE_SHA256=bc5c898e4756d373e0d991bab053036c5eb2aa7c0d5c67e8662ddc6da40c4103
GLSLANG=16.5.0
GLSLANG_SHA256=01af17195fbeb59e39e31e9506de35bb39dfd35807ea0c9a1a99d7d1183ddd45
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

if [ ! -x vendor/zig/zig ]; then
	case "$(uname -s)-$(uname -m)" in
		Linux-x86_64) target=x86_64-linux zig_sha256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
		Linux-aarch64) target=aarch64-linux zig_sha256=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;;
		Darwin-arm64) target=aarch64-macos zig_sha256=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 ;;
		Darwin-x86_64) target=x86_64-macos zig_sha256=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7 ;;
		*) echo "download-deps: no zig build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
	esac
	zig_dir=$(mktemp -d)
	fetch "https://ziglang.org/download/$ZIG/zig-$target-$ZIG.tar.xz" "$zig_dir/zig.tar.xz" "$zig_sha256"
	mkdir -p vendor/zig && tar xJf "$zig_dir/zig.tar.xz" -C vendor/zig --strip-components=1
	rm -rf "$zig_dir"
	echo "vendor/zig: $ZIG $target"
fi

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

# Headers, the static lib and src/dynapi/SDL_dynapi_procs.h, the function list the pack modules' SDL imports come from.
if [ ! -f vendor/sdl3/lib/libSDL3.a ]; then
	sdl_dir=$(mktemp -d)
	fetch "https://github.com/libsdl-org/SDL/releases/download/release-$SDL/SDL3-$SDL.tar.gz" "$sdl_dir/sdl.tar.gz" "$SDL_SHA256"
	mkdir -p "$sdl_dir/src" && tar xzf "$sdl_dir/sdl.tar.gz" -C "$sdl_dir/src" --strip-components=1
	cmake -S "$sdl_dir/src" -B "$sdl_dir/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/vendor/sdl3" \
		-DCMAKE_INSTALL_LIBDIR=lib -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF >/dev/null
	cmake --build "$sdl_dir/build" -j >/dev/null
	cmake --install "$sdl_dir/build" >/dev/null
	mkdir -p vendor/sdl3/dynapi
	cp "$sdl_dir/src/src/dynapi/SDL_dynapi_procs.h" "$sdl_dir/src/LICENSE.txt" vendor/sdl3/dynapi/
	rm -rf "$sdl_dir"
	echo "vendor/sdl3: $SDL"
fi

if [ ! -f vendor/sdl3_ttf/include/SDL3_ttf/SDL_ttf.h ]; then
	ttf_dir=$(mktemp -d)
	fetch "https://github.com/libsdl-org/SDL_ttf/releases/download/release-$SDL_TTF/SDL3_ttf-$SDL_TTF.tar.gz" "$ttf_dir/ttf.tar.gz" "$SDL_TTF_SHA256"
	fetch "https://github.com/freetype/freetype/archive/refs/tags/VER-$FREETYPE.tar.gz" "$ttf_dir/freetype.tar.gz" "$FREETYPE_SHA256"
	mkdir -p "$ttf_dir/src" && tar xzf "$ttf_dir/ttf.tar.gz" -C "$ttf_dir/src" --strip-components=1
	rm -rf "$ttf_dir/src/external/freetype" && mkdir -p "$ttf_dir/src/external/freetype"
	tar xzf "$ttf_dir/freetype.tar.gz" -C "$ttf_dir/src/external/freetype" --strip-components=1
	# English-only UI: no HarfBuzz shaping, no SVG glyphs.
	cmake -S "$ttf_dir/src" -B "$ttf_dir/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_PREFIX_PATH="$PWD/vendor/sdl3" \
		-DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF >/dev/null
	cmake --build "$ttf_dir/build" -j >/dev/null
	mkdir -p vendor/sdl3_ttf/include
	cp "$ttf_dir/build/libSDL3_ttf.a" "$ttf_dir/src/LICENSE.txt" vendor/sdl3_ttf/
	cp -r "$ttf_dir/src/include/SDL3_ttf" vendor/sdl3_ttf/include/
	rm -rf "$ttf_dir"
	echo "vendor/sdl3_ttf: $SDL_TTF, freetype $FREETYPE"
fi

# The shader compiler: GLSL to SPIR-V for the host's 3D shaders. No optimizer, so no SPIRV-Tools.
if [ ! -x vendor/glslang/glslang ]; then
	glslang_dir=$(mktemp -d)
	fetch "https://github.com/KhronosGroup/glslang/archive/refs/tags/$GLSLANG.tar.gz" "$glslang_dir/glslang.tar.gz" "$GLSLANG_SHA256"
	mkdir -p "$glslang_dir/src" && tar xzf "$glslang_dir/glslang.tar.gz" -C "$glslang_dir/src" --strip-components=1
	cmake -S "$glslang_dir/src" -B "$glslang_dir/build" -DCMAKE_BUILD_TYPE=Release -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF \
		-DENABLE_HLSL=OFF -DBUILD_SHARED_LIBS=OFF >/dev/null
	cmake --build "$glslang_dir/build" -j --target glslang-standalone >/dev/null
	mkdir -p vendor/glslang
	cp "$glslang_dir/build/StandAlone/glslang" "$glslang_dir/src/LICENSE.txt" vendor/glslang/
	rm -rf "$glslang_dir"
	echo "vendor/glslang: $GLSLANG"
fi

if [ ! -f vendor/fonts/Michroma-Regular.ttf ]; then
	mkdir -p vendor/fonts
	fetch "https://raw.githubusercontent.com/google/fonts/$FONTS_COMMIT/ofl/michroma/Michroma-Regular.ttf" vendor/fonts/Michroma-Regular.ttf "$MICHROMA_SHA256"
	curl -fL --retry 3 "https://raw.githubusercontent.com/google/fonts/$FONTS_COMMIT/ofl/michroma/OFL.txt" -o vendor/fonts/Michroma-OFL.txt
	echo "vendor/fonts: Michroma"
fi
