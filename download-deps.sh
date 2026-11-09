#!/usr/bin/env bash
# Dependencies into vendor/: zig (the C compiler for pack modules, pinned so ow build is reproducible), wasmtime's C API, the SQLite amalgamation, Clay (UI layout) with its Odin binding, cgltf, tomlc17, jsmn, dr_flac,
# SDL3 and SDL3_ttf built static (FreeType) with their headers for pack modules, ffmpeg's audio codecs for the importer, ENet, curl with mbedTLS, and the UI font. Delete a vendor/ folder to refetch it.
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
JSMN=v1.1.0
DR_FLAC=806ee9ada8ca9827b22f76827f739c290f37ba48 # 0.13.4
DR_FLAC_SHA256=b8078eeb5d523502eb7964508cd7ec8450bc79d383bec90aa17fd9e2fefd9c24
JSMN_SHA256=1ed6154dedf009212a08a397e9c4ed50a0ce31d5a8301bb294e137ae3188c13b
TOMLC17=R261003
TOMLC17_SHA256=48876f14bd7a123f95f16074dd0d5681f75c397c1bce61f1a52f42201f90eacc
ENET=1.3.18
ZLIB=1.3.1
ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
MBEDTLS=3.6.5
MBEDTLS_SHA256=4a11f1777bb95bf4ad96721cac945a26e04bf19f57d905f241fe77ebeddf46d8
CURL=8.17.0  # what Odin's vendor:curl binds
CURL_SHA256=955f6e729ad6b3566260e8fef68620e76ba3c31acf0a18524416a185acf77992
ENET_SHA256=28603c895f9ed24a846478180ee72c7376b39b4bb1287b73877e5eae7d96b0dd
GLSLANG=16.5.0
GLSLANG_SHA256=01af17195fbeb59e39e31e9506de35bb39dfd35807ea0c9a1a99d7d1183ddd45
FONTS_COMMIT=8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5 # google/fonts
MICHROMA_SHA256=b62301163788bc5b7f8fcac0b74b184e34e1827e577b499ecb724da065098f87
FFMPEG=7.1.1
FFMPEG_SHA256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
mkdir -p vendor
# Windows (MSYS2 bash, MSVC on PATH): Odin ships ENet and curl (schannel) there, so those are not built.
windows=
case "$(uname -s)" in MINGW*|MSYS*) windows=1 ;; esac
# CMake builds: static, PIC, and the static MSVC runtime that Odin links on Windows.
cmake_flags=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded)

# unpack <archive> <dir>: the archive's one top folder becomes dir.
unpack() {
	mkdir -p "$2"
	case "$1" in
		*.zip)
			unzip_dir=$(mktemp -d)
			unzip -q "$1" -d "$unzip_dir"
			mv "$unzip_dir"/*/* "$2"/
			rm -rf "$unzip_dir"
			;;
		*) tar xf "$1" -C "$2" --strip-components=1 ;;
	esac
}

# download <url> <file>: five tries; curl's own --retry skips connection resets.
download() {
	for attempt in 1 2 3 4 5; do
		curl -fL "$1" -o "$2" && return
		echo "download-deps: try $attempt of $1 failed" >&2
		sleep 5
	done
	return 1
}

# fetch <url> <file> <sha256>
fetch() {
	download "$1" "$2"
	checksum=$(openssl dgst -sha256 -r "$2")
	if [ "${checksum%% *}" != "$3" ]; then
		echo "download-deps: SHA-256 mismatch for $1" >&2
		exit 1
	fi
}

if [ ! -x vendor/zig/zig ]; then
	case "$(uname -s)-$(uname -m)" in
		Linux-x86_64) target=x86_64-linux zig_sha256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
		MINGW*-x86_64|MSYS*-x86_64) target=x86_64-windows zig_sha256=68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e ;;
		Linux-aarch64) target=aarch64-linux zig_sha256=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;;
		Darwin-arm64) target=aarch64-macos zig_sha256=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 ;;
		Darwin-x86_64) target=x86_64-macos zig_sha256=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7 ;;
		*) echo "download-deps: no zig build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
	esac
	zig_archive=zig-$target-$ZIG.tar.xz
	[ -n "$windows" ] && zig_archive=zig-$target-$ZIG.zip
	zig_dir=$(mktemp -d)
	fetch "https://ziglang.org/download/$ZIG/$zig_archive" "$zig_dir/$zig_archive" "$zig_sha256"
	unpack "$zig_dir/$zig_archive" vendor/zig
	rm -rf "$zig_dir"
	echo "vendor/zig: $ZIG $target"
fi

if [ ! -f vendor/tomlc17/tomlc17.c ]; then
	toml_dir=$(mktemp -d)
	fetch "https://github.com/cktan/tomlc17/archive/refs/tags/$TOMLC17.tar.gz" "$toml_dir/tomlc17.tar.gz" "$TOMLC17_SHA256"
	tar xzf "$toml_dir/tomlc17.tar.gz" -C "$toml_dir" --strip-components=1
	mkdir -p vendor/tomlc17
	cp "$toml_dir/src/tomlc17.c" "$toml_dir/src/tomlc17.h" "$toml_dir/LICENSE" vendor/tomlc17/
	rm -rf "$toml_dir"
	echo "vendor/tomlc17: $TOMLC17"
fi

# UDP for online play, built static for vendor:ENet's "system:enet".
if [ -z "$windows" ] && [ ! -f vendor/enet/libenet.a ]; then
	enet_dir=$(mktemp -d)
	fetch "https://github.com/lsalzman/enet/archive/refs/tags/v$ENET.tar.gz" "$enet_dir/enet.tar.gz" "$ENET_SHA256"
	tar xzf "$enet_dir/enet.tar.gz" -C "$enet_dir" --strip-components=1
	mkdir -p vendor/enet
	for source in callbacks compress host list packet peer protocol unix; do
		vendor/zig/zig cc -O2 -I"$enet_dir/include" \
			-DHAS_POLL -DHAS_FCNTL -DHAS_SOCKLEN_T -DHAS_MSGHDR_FLAGS -DHAS_GETADDRINFO -DHAS_GETNAMEINFO \
			-DHAS_INET_PTON -DHAS_INET_NTOP -c "$enet_dir/$source.c" -o "$enet_dir/$source.o"
	done
	vendor/zig/zig ar rcs vendor/enet/libenet.a "$enet_dir"/*.o
	cp "$enet_dir/LICENSE" vendor/enet/
	rm -rf "$enet_dir"
	echo "vendor/enet: $ENET"
fi

# The server needs nothing below.
[ "${1:-}" = server ] && exit 0

if [ ! -d vendor/wasmtime ]; then
	case "$(uname -s)-$(uname -m)" in
		Linux-x86_64) target=x86_64-linux ;;
		Linux-aarch64) target=aarch64-linux ;;
		Darwin-arm64) target=aarch64-macos ;;
		Darwin-x86_64) target=x86_64-macos ;;
		MINGW*-x86_64|MSYS*-x86_64) target=x86_64-windows ;;
		*) echo "download-deps: no wasmtime build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
	esac
	wasmtime_archive=wasmtime-$WASMTIME-$target-c-api.tar.xz
	[ -n "$windows" ] && wasmtime_archive=wasmtime-$WASMTIME-$target-c-api.zip
	wasmtime_dir=$(mktemp -d)
	download "https://github.com/bytecodealliance/wasmtime/releases/download/$WASMTIME/$wasmtime_archive" "$wasmtime_dir/$wasmtime_archive"
	unpack "$wasmtime_dir/$wasmtime_archive" vendor/wasmtime
	rm -rf "$wasmtime_dir"
	echo "vendor/wasmtime: $WASMTIME $target"
fi

if [ ! -f vendor/sqlite/sqlite3.c ]; then
	deps_dir=$(mktemp -d)
	trap 'rm -rf "$deps_dir"' EXIT
	download "https://sqlite.org/2026/sqlite-amalgamation-$SQLITE.zip" "$deps_dir/sqlite.zip"
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
	download "https://github.com/nicbarker/clay/archive/refs/tags/$CLAY.tar.gz" "$clay_dir/clay.tar.gz"
	tar xzf "$clay_dir/clay.tar.gz" -C "$clay_dir" --strip-components=1
	mkdir -p vendor/clay
	cp "$clay_dir/clay.h" "$clay_dir/bindings/odin/clay-odin/clay.odin" vendor/clay/
	# Clay keeps 10 clipped elements; every slot's name plate clips.
	sed -i 's/ScrollContainerDataInternalArray_Allocate_Arena(10, arena)/ScrollContainerDataInternalArray_Allocate_Arena(512, arena)/' vendor/clay/clay.h
	grep -q 'Allocate_Arena(512, arena)' vendor/clay/clay.h || { echo "clay.h: clip limit patch did not apply" >&2; exit 1; }
	rm -rf "$clay_dir"
	echo "vendor/clay: $CLAY"
fi

# Headers, the static lib and src/dynapi/SDL_dynapi_procs.h, the function list the pack modules' SDL imports come from.
if [ ! -f vendor/sdl3/dynapi/SDL_dynapi_procs.h ]; then
	sdl_dir=$(mktemp -d)
	fetch "https://github.com/libsdl-org/SDL/releases/download/release-$SDL/SDL3-$SDL.tar.gz" "$sdl_dir/sdl.tar.gz" "$SDL_SHA256"
	mkdir -p "$sdl_dir/src" && tar xzf "$sdl_dir/sdl.tar.gz" -C "$sdl_dir/src" --strip-components=1
	cmake -S "$sdl_dir/src" -B "$sdl_dir/build" "${cmake_flags[@]}" -DCMAKE_INSTALL_PREFIX="$PWD/vendor/sdl3" \
		-DCMAKE_INSTALL_LIBDIR=lib -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF >/dev/null
	cmake --build "$sdl_dir/build" --config Release -j >/dev/null
	cmake --install "$sdl_dir/build" --config Release >/dev/null
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
	cmake -S "$ttf_dir/src" -B "$ttf_dir/build" "${cmake_flags[@]}" -DBUILD_SHARED_LIBS=OFF -DCMAKE_PREFIX_PATH="$PWD/vendor/sdl3" \
		-DCMAKE_INSTALL_PREFIX="$ttf_dir/install" -DCMAKE_INSTALL_LIBDIR=lib \
		-DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF >/dev/null
	cmake --build "$ttf_dir/build" --config Release -j >/dev/null
	cmake --install "$ttf_dir/build" --config Release >/dev/null
	mkdir -p vendor/sdl3_ttf/include
	find "$ttf_dir/install/lib" -maxdepth 1 -type f -name '*SDL3_ttf*' -exec cp {} vendor/sdl3_ttf/ \;
	cp "$ttf_dir/src/LICENSE.txt" vendor/sdl3_ttf/
	cp -r "$ttf_dir/src/include/SDL3_ttf" vendor/sdl3_ttf/include/
	rm -rf "$ttf_dir"
	echo "vendor/sdl3_ttf: $SDL_TTF, freetype $FREETYPE"
fi

# The shader compiler: GLSL to SPIR-V for the host's 3D shaders. No optimizer, so no SPIRV-Tools.
if [ ! -x vendor/glslang/glslang ]; then
	glslang_dir=$(mktemp -d)
	fetch "https://github.com/KhronosGroup/glslang/archive/refs/tags/$GLSLANG.tar.gz" "$glslang_dir/glslang.tar.gz" "$GLSLANG_SHA256"
	mkdir -p "$glslang_dir/src" && tar xzf "$glslang_dir/glslang.tar.gz" -C "$glslang_dir/src" --strip-components=1
	cmake -S "$glslang_dir/src" -B "$glslang_dir/build" "${cmake_flags[@]}" -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF \
		-DENABLE_HLSL=OFF -DBUILD_SHARED_LIBS=OFF >/dev/null
	cmake --build "$glslang_dir/build" --config Release -j --target glslang-standalone >/dev/null
	mkdir -p vendor/glslang
	find "$glslang_dir/build/StandAlone" -type f \( -name glslang -o -name glslang.exe \) -exec cp {} vendor/glslang/ \;
	cp "$glslang_dir/src/LICENSE.txt" vendor/glslang/
	rm -rf "$glslang_dir"
	echo "vendor/glslang: $GLSLANG"
fi

# JSON tokens for the sim's stage loader (modules/tk5/sim/stage_file.c).
if [ ! -f vendor/jsmn/jsmn.h ]; then
	mkdir -p vendor/jsmn
	fetch "https://raw.githubusercontent.com/zserge/jsmn/$JSMN/jsmn.h" vendor/jsmn/jsmn.h "$JSMN_SHA256"
	download "https://raw.githubusercontent.com/zserge/jsmn/$JSMN/LICENSE" vendor/jsmn/LICENSE
	echo "vendor/jsmn: $JSMN"
fi

if [ ! -f vendor/dr_flac/dr_flac.h ]; then
	mkdir -p vendor/dr_flac
	fetch "https://raw.githubusercontent.com/mackron/dr_libs/$DR_FLAC/dr_flac.h" vendor/dr_flac/dr_flac.h "$DR_FLAC_SHA256"
	echo "vendor/dr_flac: $DR_FLAC"
fi

# HTTPS for the network's files host: zlib and mbedTLS compiled as they are, curl through cmake with only HTTP(S).
# vendor:curl links "system:curl" and "system:z": libcurl.a holds mbedTLS too, so link order can not lose it.
# No CA bundle path is built in; the game finds the system's at run time.
if [ -z "$windows" ] && [ ! -f vendor/curl/libcurl.a ]; then
	curl_dir=$(mktemp -d)
	mkdir -p vendor/curl "$curl_dir/zlib" "$curl_dir/mbedtls" "$curl_dir/curl"
	fetch "https://github.com/madler/zlib/releases/download/v$ZLIB/zlib-$ZLIB.tar.gz" "$curl_dir/zlib.tar.gz" "$ZLIB_SHA256"
	fetch "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS/mbedtls-$MBEDTLS.tar.bz2" "$curl_dir/mbedtls.tar.bz2" "$MBEDTLS_SHA256"
	fetch "https://curl.se/download/curl-$CURL.tar.xz" "$curl_dir/curl.tar.xz" "$CURL_SHA256"
	tar xzf "$curl_dir/zlib.tar.gz" -C "$curl_dir/zlib" --strip-components=1
	tar xjf "$curl_dir/mbedtls.tar.bz2" -C "$curl_dir/mbedtls" --strip-components=1
	tar xJf "$curl_dir/curl.tar.xz" -C "$curl_dir/curl" --strip-components=1
	zig="$PWD/vendor/zig/zig"
	for dir in zlib mbedtls; do
		mkdir -p "$curl_dir/$dir-objects"
		sources=("$curl_dir/$dir"/*.c)
		[ "$dir" = mbedtls ] && sources=("$curl_dir/mbedtls/library"/*.c)
		for source in "${sources[@]}"; do
			"$zig" cc -O2 -fPIC -DHAVE_UNISTD_H -I"$curl_dir/zlib" -I"$curl_dir/mbedtls/include" -I"$curl_dir/mbedtls/library" \
				-c "$source" -o "$curl_dir/$dir-objects/$(basename "$source" .c).o"
		done
	done
	"$zig" ar rcs vendor/curl/libz.a "$curl_dir"/zlib-objects/*.o
	"$zig" ar rcs "$curl_dir/libmbedtls.a" "$curl_dir"/mbedtls-objects/*.o
	cmake -S "$curl_dir/curl" -B "$curl_dir/build" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_COMPILER="$zig" -DCMAKE_C_COMPILER_ARG1=cc -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
		-DBUILD_EXAMPLES=OFF -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF \
		-DHTTP_ONLY=ON -DENABLE_ARES=OFF -DCURL_DISABLE_LDAP=ON -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF \
		-DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
		-DCURL_USE_OPENSSL=OFF -DCURL_USE_MBEDTLS=ON -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=none \
		-DMBEDTLS_INCLUDE_DIR="$curl_dir/mbedtls/include" -DMBEDTLS_LIBRARY="$curl_dir/libmbedtls.a" \
		-DMBEDX509_LIBRARY="$curl_dir/libmbedtls.a" -DMBEDCRYPTO_LIBRARY="$curl_dir/libmbedtls.a" \
		-DCURL_ZLIB=ON -DZLIB_INCLUDE_DIR="$curl_dir/zlib" -DZLIB_LIBRARY="$PWD/vendor/curl/libz.a" > "$curl_dir/cmake.log"
	cmake --build "$curl_dir/build" --target libcurl_static -j"$(nproc)" > "$curl_dir/build.log"
	mkdir -p "$curl_dir/curl-objects" && (cd "$curl_dir/curl-objects" && "$zig" ar x "$curl_dir/build/lib/libcurl.a")
	"$zig" ar rcs vendor/curl/libcurl.a "$curl_dir"/curl-objects/*.o "$curl_dir"/mbedtls-objects/*.o
	cp "$curl_dir/curl/COPYING" vendor/curl/COPYING.curl
	cp "$curl_dir/mbedtls/LICENSE" vendor/curl/LICENSE.mbedtls
	cp "$curl_dir/zlib/LICENSE" vendor/curl/LICENSE.zlib
	rm -rf "$curl_dir"
	echo "vendor/curl: curl $CURL, mbedTLS $MBEDTLS, zlib $ZLIB"
fi

# glb reading: the cgltf binding and C source that ship with the installed Odin, so the two always match.
if [ ! -f vendor/cgltf/cgltf.odin ]; then
	odin_cgltf="$(odin root)/vendor/cgltf"
	[ -n "$windows" ] && odin_cgltf=$(cygpath -u "$odin_cgltf")
	mkdir -p vendor/cgltf/src
	cp "$odin_cgltf/cgltf.odin" "$odin_cgltf/LICENSE" vendor/cgltf/
	cp "$odin_cgltf/src/cgltf.c" "$odin_cgltf/src/cgltf.h" "$odin_cgltf/src/cgltf_write.h" vendor/cgltf/src/
	echo "vendor/cgltf: from $(odin version)"
fi

# The importer's audio: the game's codecs in, FLAC out (LGPL build, no asm so no nasm).
if [ ! -f vendor/ffmpeg/lib/libavcodec.a ]; then
	ffmpeg_dir=$(mktemp -d)
	fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz" "$ffmpeg_dir/ffmpeg.tar.xz" "$FFMPEG_SHA256"
	mkdir -p "$ffmpeg_dir/src" && tar xJf "$ffmpeg_dir/ffmpeg.tar.xz" -C "$ffmpeg_dir/src" --strip-components=1
	prefix="$PWD/vendor/ffmpeg"
	toolchain=()
	[ -n "$windows" ] && toolchain=(--toolchain=msvc --extra-cflags=-MT)
	(cd "$ffmpeg_dir/src" && ./configure --prefix="$prefix" "${toolchain[@]}" --disable-everything --disable-programs --disable-doc \
		--disable-network --disable-autodetect --disable-avformat --disable-avdevice --disable-avfilter --disable-swscale \
		--disable-swresample --disable-x86asm --disable-pthreads --enable-static --disable-shared \
		--enable-decoder=atrac3p,adpcm_psx --enable-encoder=flac >/dev/null && make -j >/dev/null && make install >/dev/null)
	cp "$ffmpeg_dir/src/COPYING.LGPLv2.1" vendor/ffmpeg/
	rm -rf "$ffmpeg_dir"
	echo "vendor/ffmpeg: $FFMPEG"
fi

if [ ! -f vendor/fonts/Michroma-Regular.ttf ]; then
	mkdir -p vendor/fonts
	fetch "https://raw.githubusercontent.com/google/fonts/$FONTS_COMMIT/ofl/michroma/Michroma-Regular.ttf" vendor/fonts/Michroma-Regular.ttf "$MICHROMA_SHA256"
	download "https://raw.githubusercontent.com/google/fonts/$FONTS_COMMIT/ofl/michroma/OFL.txt" vendor/fonts/Michroma-OFL.txt
	echo "vendor/fonts: Michroma"
fi
