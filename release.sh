#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# ./release.sh [--public] --version <tag> --notes <text>: .github/workflows/release.yml builds origin/main for Linux and
# Windows and puts it up as the GitHub release <tag>, a draft unless --public. Launchers find it through release.txt; see
# src/game/binary_update.odin.
usage() {
	echo 'usage: ./release.sh [--public] --version <tag> --notes "release notes"' >&2
	exit 2
}
public=false version= notes=
while [ $# -gt 0 ]; do
	case "$1" in
		--public) public=true; shift ;;
		--version) [ $# -ge 2 ] || usage; version=$2; shift 2 ;;
		--notes) [ $# -ge 2 ] || usage; notes=$2; shift 2 ;;
		*) usage ;;
	esac
done
[ -n "$version" ] && [ -n "$notes" ] || usage
git fetch -q origin main
last=$(git show origin/main:releases.txt | awk 'NF { last = $NF } END { print last }')
if [ "$last" != "$version" ]; then
	echo "release.sh: releases.txt on origin/main ends in $last: add $version to releases.txt, commit and push, then release." >&2
	exit 1
fi
gh workflow run release.yml --ref main -f version="$version" -f notes="$notes" -f public="$public"
echo "release.sh: started; follow it with gh run watch"
