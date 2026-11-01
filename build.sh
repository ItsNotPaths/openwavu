#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
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
odin build src/importer -out:build/openwavu-import -o:speed -vet -strict-style
# (hole module-build :tags (wasm tk5mod) :needs ow-cli) the stock gameplay.wasm and app.wasm are not built from modules/tk5 with ow build; the TK5 core needs -fwrapv -ffp-contract=off -fno-fast-math there too.
odin build src/game -out:build/openwavu -vet -strict-style
odin check src/tools/animconv -vet -strict-style
odin check src/tools/ow -vet -strict-style
odin test tests -out:build/tests -o:speed -vet -strict-style
