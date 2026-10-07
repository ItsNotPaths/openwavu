#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
./download-deps.sh
if [ ! -f vendor/sqlite/libsqlite3.a ] || [ vendor/sqlite/sqlite3.c -nt vendor/sqlite/libsqlite3.a ]; then
	cc -O2 -c vendor/sqlite/sqlite3.c -o vendor/sqlite/sqlite3.o
	ar rcs vendor/sqlite/libsqlite3.a vendor/sqlite/sqlite3.o
fi
odin build src/importer -out:build/openwavu-import -o:speed -vet -strict-style
# (hole module-build :tags (wasm tk5mod) :needs seam-abi) the default modules in modules/tk5 are not built to WASM (zig cc --target=wasm32-freestanding, or clang + wasm-ld).
odin check src/game -vet -strict-style
odin check src/tools/animconv -vet -strict-style
odin test tests -out:build/tests -o:speed -vet -strict-style
