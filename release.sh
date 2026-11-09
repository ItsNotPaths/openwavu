#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# ./release.sh: a speed build of openwavu goes up as the GitHub release named by the last tag in releases.txt.
# Launchers find it through release.txt (tag and SHA-256); see src/game/binary_update.odin.
# (hole release-ci :tags tools :sev polish) the release is built on the releaser's machine; no CI build.
tag=$(awk 'NF { last = $NF } END { print last }' releases.txt)
./build.sh speed
mkdir -p build/release
cp build/openwavu build/release/openwavu-linux
echo "$tag $(sha256sum build/release/openwavu-linux | cut -d' ' -f1)" > build/release/release.txt
gh release create "$tag" build/release/openwavu-linux build/release/release.txt --title "openwavu $tag" --notes ""
