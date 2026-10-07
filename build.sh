#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
odin build src/importer -out:build/openwavu-import -o:speed -vet -strict-style
odin test tests -out:build/tests -o:speed -vet -strict-style
