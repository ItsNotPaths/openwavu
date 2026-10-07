#!/usr/bin/env bash
# Prebuilt libraries into vendor/: wasmtime's C API.
set -euo pipefail
cd "$(dirname "$0")"
WASMTIME=v49.0.2
case "$(uname -s)-$(uname -m)" in
	Linux-x86_64) target=x86_64-linux ;;
	Linux-aarch64) target=aarch64-linux ;;
	Darwin-arm64) target=aarch64-macos ;;
	Darwin-x86_64) target=x86_64-macos ;;
	*) echo "download-deps: no wasmtime build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
name=wasmtime-$WASMTIME-$target-c-api
mkdir -p vendor
curl -fL --retry 3 "https://github.com/bytecodealliance/wasmtime/releases/download/$WASMTIME/$name.tar.xz" | tar xJ -C vendor
rm -rf vendor/wasmtime
mv "vendor/$name" vendor/wasmtime
echo "vendor/wasmtime: $WASMTIME $target"
