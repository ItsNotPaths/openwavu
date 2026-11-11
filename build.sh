#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# ./build.sh [speed] [test] [server]: speed optimizes (slow build, ~5x faster import); server builds only the server.
# ODIN_FLAGS: extra flags for every Odin build (CI picks its linker with it).
read -ra odin_flags <<< "${ODIN_FLAGS:-}"
run_tests=0 only_server=0
for arg in "$@"; do
	case "$arg" in
		speed) odin_flags+=(-o:speed) ;;
		test) run_tests=1 ;;
		server) only_server=1 ;;
		*) echo "usage: ./build.sh [speed] [test] [server]" >&2; exit 2 ;;
	esac
done
mkdir -p build
if [ "$only_server" = 1 ]; then ./download-deps.sh server; else ./download-deps.sh; fi
# Host C libraries: cc, or zig for MSVC on Windows (MSYS2 bash), where Odin links with MSVC.
c_compiler=(cc -g -fPIC) archiver=(ar) exe= windows=
case "$(uname -s)" in
	MINGW*|MSYS*) c_compiler=(vendor/zig/zig cc -target x86_64-windows-msvc -g) archiver=(vendor/zig/zig ar) exe=.exe windows=1 ;;
esac
# Odin's default Windows linker, radlink, misses symbols in Odin's own libz.lib.
[ -n "$windows" ] && odin_flags+=(-linker:msvc)
if [ ! -f vendor/tomlc17/libtomlc17.a ] || [ vendor/tomlc17/tomlc17.c -nt vendor/tomlc17/libtomlc17.a ]; then
	"${c_compiler[@]}" -O2 -c vendor/tomlc17/tomlc17.c -o vendor/tomlc17/tomlc17.o
	"${archiver[@]}" rcs vendor/tomlc17/libtomlc17.a vendor/tomlc17/tomlc17.o
fi
# The server runs on Linux only.
[ -z "$windows" ] && odin build src/server -out:build/openwavu-server "${odin_flags[@]}" -vet -strict-style -extra-linker-flags:"-Lvendor/enet -Lvendor/curl"
[ "$only_server" = 1 ] && exit 0
if [ ! -f vendor/sqlite/libsqlite3.a ] || [ vendor/sqlite/sqlite3.c -nt vendor/sqlite/libsqlite3.a ]; then
	"${c_compiler[@]}" -O2 -DSQLITE_OMIT_LOAD_EXTENSION -c vendor/sqlite/sqlite3.c -o vendor/sqlite/sqlite3.o
	"${archiver[@]}" rcs vendor/sqlite/libsqlite3.a vendor/sqlite/sqlite3.o
fi
# The Clay binding links <os dir>/clay.a next to clay.odin.
case "$(uname -s)-$(uname -m)" in
	Darwin-arm64) clay_lib=vendor/clay/macos-arm64/clay.a ;;
	Darwin-*) clay_lib=vendor/clay/macos/clay.a ;;
	MINGW*|MSYS*) clay_lib=vendor/clay/windows/clay.lib ;;
	*) clay_lib=vendor/clay/linux/clay.a ;;
esac
if [ ! -f "$clay_lib" ] || [ vendor/clay/clay.h -nt "$clay_lib" ]; then
	mkdir -p "$(dirname "$clay_lib")"
	"${c_compiler[@]}" -O2 -DCLAY_IMPLEMENTATION -x c -c vendor/clay/clay.h -o vendor/clay/clay.o
	"${archiver[@]}" rcs "$clay_lib" vendor/clay/clay.o
fi
# The cgltf binding links lib/cgltf.a (lib/darwin/cgltf.a on macOS, lib/cgltf.lib on Windows) next to cgltf.odin.
case "$(uname -s)" in
	Darwin) cgltf_lib=vendor/cgltf/lib/darwin/cgltf.a ;;
	MINGW*|MSYS*) cgltf_lib=vendor/cgltf/lib/cgltf.lib ;;
	*) cgltf_lib=vendor/cgltf/lib/cgltf.a ;;
esac
if [ ! -f "$cgltf_lib" ] || [ vendor/cgltf/src/cgltf.h -nt "$cgltf_lib" ]; then
	mkdir -p "$(dirname "$cgltf_lib")"
	"${c_compiler[@]}" -O2 -c vendor/cgltf/src/cgltf.c -o vendor/cgltf/cgltf.o
	"${archiver[@]}" rcs "$cgltf_lib" vendor/cgltf/cgltf.o
fi
# ow_input.h is header-only; the Odin binding (src/command) links it.
if [ ! -f build/libow_input.a ] || [ sdk/include/ow_input.h -nt build/libow_input.a ]; then
	"${c_compiler[@]}" -std=c23 -O2 -DOW_INPUT_IMPLEMENTATION -x c -c sdk/include/ow_input.h -o build/ow_input.o
	"${archiver[@]}" rcs build/libow_input.a build/ow_input.o
fi
# The importer's ffmpeg glue; the Odin binding (src/audio) links it.
if [ ! -f build/libow_audio.a ] || [ src/audio/ffmpeg.c -nt build/libow_audio.a ]; then
	"${c_compiler[@]}" -std=c23 -O2 -Ivendor/ffmpeg/include -c src/audio/ffmpeg.c -o build/ow_audio.o
	"${archiver[@]}" rcs build/libow_audio.a build/ow_audio.o
fi
# The SDK's SQLite for pack modules (sdk/src/ow_db.c has its VFS): SQLITE_OS_OTHER, so only openwavu imports.
mkdir -p build/sdk
if [ ! -f build/sdk/libow_db.a ] || [ vendor/sqlite/sqlite3.c -nt build/sdk/libow_db.a ] || [ sdk/src/ow_db.c -nt build/sdk/libow_db.a ]; then
	vendor/zig/zig cc --target=wasm32-wasi -Os -DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION \
		-DSQLITE_OMIT_WAL -DSQLITE_DEFAULT_MEMSTATUS=0 -c vendor/sqlite/sqlite3.c -o build/sdk/sqlite3.o
	vendor/zig/zig cc --target=wasm32-wasi -Os -std=c23 -Isdk/include -c sdk/src/ow_db.c -o build/sdk/ow_db.o
	rm -f build/sdk/libow_db.a
	vendor/zig/zig ar rcs build/sdk/libow_db.a build/sdk/sqlite3.o build/sdk/ow_db.o
fi
# The SDK's sound helper, with dr_flac; its SDL calls become the pack's imports.
if [ ! -f build/sdk/libow_sound.a ] || [ -n "$(find sdk/src/ow_sound.c sdk/include/ow_sound.h vendor/dr_flac -newer build/sdk/libow_sound.a -print -quit)" ]; then
	vendor/zig/zig cc --target=wasm32-wasi -O2 -std=c23 -Isdk/include -Ivendor/sdl3/include -c sdk/src/ow_sound.c -o build/sdk/ow_sound.o
	rm -f build/sdk/libow_sound.a
	vendor/zig/zig ar rcs build/sdk/libow_sound.a build/sdk/ow_sound.o
fi
# The stock game modules (TK5, TK6 fork), WASI reactors. The sim imports only from openwavu; presentation modules also call SDL, whose
# functions become imports (env) through --import-symbols. The sim cores need exact floats and wrapping ints.
# (hole module-build :tags (wasm tk5mod) :needs ow-cli) build.sh builds the stock modules with zig itself; ow build should make them with the same pinned flags, reproducibly.
mkdir -p build/modules/tk5 build/modules/tk6
# game_module <module> <out> <link flags> <sources...>: rebuilt when anything under modules/<module> or sdk is newer.
# -s: zig's crt carries this machine's paths in its debug info, and the stock pack hash needs the same bytes everywhere.
game_module() {
	module="$1"
	out="$2"
	link="$3"
	shift 3
	if [ ! -f "$out" ] || [ -n "$(find "modules/$module" sdk build/sdk -newer "$out" -print -quit)" ]; then
		vendor/zig/zig cc --target=wasm32-wasi -O2 -std=c23 -fwrapv -ffp-contract=off -fno-fast-math -mexec-model=reactor -s \
			-I"modules/$module" -Isdk/include -Ivendor/sqlite -Ivendor/jsmn -Ivendor/sdl3/include -Ivendor/sdl3_ttf/include $link \
			-o "$out" "$@" build/sdk/libow_db.a build/sdk/libow_sound.a
	fi
}
# game_modules <module> <out dir>: the sim, app and presenter of one game.
game_modules() {
	core=("modules/$1"/sim/*.c "modules/$1"/load.c)
	game_module "$1" "$2/gameplay.wasm" "" "${core[@]}" "modules/$1"/{view,pack_file}.c "modules/$1"/gameplay/*.c
	game_module "$1" "$2/app.wasm" -Wl,--import-symbols "modules/$1"/app/*.c
	game_module "$1" "$2/gamerender.wasm" -Wl,--import-symbols "${core[@]}" "modules/$1"/pack_file.c "modules/$1"/gamerender/*.c
}
game_modules tk5 build/modules/tk5
game_modules tk6 build/modules/tk6
# The host's 3D shaders, SPIR-V; src/render embeds them.
mkdir -p build/shaders
for shader in src/render/shaders/*.vert src/render/shaders/*.frag; do
	out="build/shaders/$(basename "$shader").spv"
	if [ ! -f "$out" ] || [ "$shader" -nt "$out" ]; then
		vendor/glslang/glslang -V --quiet -o "$out" "$shader"
	fi
done
# The pack SDL imports, generated from the allowlist and SDL's own signatures.
glue=src/imports/sdl_glue.odin
if [ -n "$(find src/imports/sdl_allow.txt src/tools/sdlglue vendor/sdl3/dynapi vendor/sdl3_ttf/include -newer "$glue" -print -quit)" ]; then
	odin run src/tools/sdlglue -vet -strict-style
fi
odin build src/importer -out:build/openwavu-import$exe "${odin_flags[@]}" -vet -strict-style -extra-linker-flags:"-Lvendor/curl"
# vendor:sdl3, vendor:ENet and vendor:curl link "system:SDL3", "system:enet", "system:curl" and "system:z": the -L dirs
# make those the vendored static libs.
sdl_libs=-extra-linker-flags:"-Lvendor/sdl3/lib -Lvendor/sdl3_ttf -Lvendor/enet -Lvendor/curl"
if [ -n "$windows" ]; then
	# vendor:sdl3 links SDL3.lib and SDL3_ttf.lib from Odin's own folder, the DLL import libs: the static ones go over them.
	odin_sdl=$(cygpath -u "$(odin root)")/vendor/sdl3
	cp vendor/sdl3/lib/SDL3-static.lib "$odin_sdl/SDL3.lib"
	cp vendor/sdl3_ttf/SDL3_ttf*.lib "$odin_sdl/ttf/SDL3_ttf.lib"
	sdl_libs=-extra-linker-flags:"setupapi.lib winmm.lib imm32.lib version.lib ole32.lib oleaut32.lib gdi32.lib user32.lib shell32.lib advapi32.lib cfgmgr32.lib uuid.lib"
fi
odin build src/game -out:build/openwavu$exe "${odin_flags[@]}" -vet -strict-style "$sdl_libs"
# Stage viewer title pack: build/stageview.tar.
mkdir -p build/stageview
vendor/zig/zig cc --target=wasm32-wasi -O2 -std=c23 -mexec-model=reactor -s -Wl,--import-symbols \
	-Isdk/include -Ivendor/sqlite -Ivendor/jsmn -Ivendor/sdl3/include \
	-o build/stageview/stageview.wasm modules/stageview/*.c build/sdk/libow_db.a
cp modules/stageview/pack.toml build/stageview/
build/openwavu --package build/stageview >/dev/null
odin build src/tools/bot -out:build/openwavu-bot$exe "${odin_flags[@]}" -vet -strict-style -extra-linker-flags:"-Lvendor/enet -Lvendor/curl"
odin check src/tools/animconv -vet -strict-style
odin check src/tools/ow -vet -strict-style
if [ "$run_tests" = 1 ]; then
	# (hole test-parallel-interrupt :tags tools :sev gap) parallel test runs end on 'Caught interrupt signal' with one test undone; single-threaded runs pass (-define:ODIN_TEST_THREADS=1).
	odin test tests -out:build/tests -o:speed -vet -strict-style "$sdl_libs"
fi
