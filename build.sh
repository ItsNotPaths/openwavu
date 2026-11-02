#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# ./build.sh [speed] [test]: speed optimizes the game and importer (slow build, ~5x faster import).
optimize=() run_tests=0
for arg in "$@"; do
	case "$arg" in
		speed) optimize=(-o:speed) ;;
		test) run_tests=1 ;;
		*) echo "usage: ./build.sh [speed] [test]" >&2; exit 2 ;;
	esac
done
mkdir -p build
./download-deps.sh
if [ ! -f vendor/sqlite/libsqlite3.a ] || [ vendor/sqlite/sqlite3.c -nt vendor/sqlite/libsqlite3.a ]; then
	cc -O2 -c vendor/sqlite/sqlite3.c -o vendor/sqlite/sqlite3.o
	ar rcs vendor/sqlite/libsqlite3.a vendor/sqlite/sqlite3.o
fi
# The Clay binding links <os dir>/clay.a next to clay.odin.
case "$(uname -s)-$(uname -m)" in
	Darwin-arm64) clay_lib=vendor/clay/macos-arm64/clay.a ;;
	Darwin-*) clay_lib=vendor/clay/macos/clay.a ;;
	*) clay_lib=vendor/clay/linux/clay.a ;;
esac
if [ ! -f "$clay_lib" ] || [ vendor/clay/clay.h -nt "$clay_lib" ]; then
	mkdir -p "$(dirname "$clay_lib")"
	cc -O2 -fPIC -DCLAY_IMPLEMENTATION -x c -c vendor/clay/clay.h -o vendor/clay/clay.o
	ar rcs "$clay_lib" vendor/clay/clay.o
fi
# ow_input.h is header-only; the Odin binding (src/command) links it.
if [ ! -f build/libow_input.a ] || [ sdk/include/ow_input.h -nt build/libow_input.a ]; then
	cc -std=c23 -O2 -DOW_INPUT_IMPLEMENTATION -x c -c sdk/include/ow_input.h -o build/ow_input.o
	ar rcs build/libow_input.a build/ow_input.o
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
# The stock TK5 modules, WASI reactors that import only from openwavu. The TK5 core needs exact floats and wrapping ints.
# (hole module-build :tags (wasm tk5mod) :needs ow-cli) build.sh builds the stock modules with zig itself; ow build should make them with the same pinned flags, reproducibly.
mkdir -p build/modules
tk5_core=(modules/tk5/sim/*.c modules/tk5/visual/hand_bank.c modules/tk5/load.c)
# tk5_module <out> <sources...>: rebuilt when anything under modules/tk5 or sdk is newer.
tk5_module() {
	out="build/modules/$1"
	shift
	if [ ! -f "$out" ] || [ -n "$(find modules/tk5 sdk build/sdk/libow_db.a -newer "$out" -print -quit)" ]; then
		vendor/zig/zig cc --target=wasm32-wasi -O2 -std=c23 -fwrapv -ffp-contract=off -fno-fast-math -mexec-model=reactor \
			-Imodules/tk5 -Isdk/include -Ivendor/sqlite -o "$out" "$@" build/sdk/libow_db.a
	fi
}
tk5_module gameplay.wasm "${tk5_core[@]}" modules/tk5/init.c modules/tk5/match.c modules/tk5/bot.c
odin build src/importer -out:build/openwavu-import "${optimize[@]}" -vet -strict-style
odin build src/game -out:build/openwavu "${optimize[@]}" -vet -strict-style -extra-linker-flags:"-Lvendor/sdl3_ttf"
odin check src/tools/animconv -vet -strict-style
odin check src/tools/ow -vet -strict-style
if [ "$run_tests" = 1 ]; then
	odin test tests -out:build/tests -o:speed -vet -strict-style
fi
