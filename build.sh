#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
[ -d vendor/wasmtime ] || ./download-deps.sh
odin build src/importer -out:build/openwavu-import -o:speed -vet -strict-style
# (hole module-build :tags (wasm tk5mod) :needs seam-abi) the default modules in modules/tk5 are not built to WASM (zig cc --target=wasm32-freestanding, or clang + wasm-ld).
odin check src/game -vet -strict-style
odin check src/tools/animconv -vet -strict-style
odin test tests -out:build/tests -o:speed -vet -strict-style
