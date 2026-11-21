#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/keyboop-boundary.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

swiftc -module-cache-path "$build_dir/module-cache" \
    "$repo/Sources/Keyboop/KeystrokeBuffer.swift" "$repo/Tests/Boundary/main.swift" \
    -o "$build_dir/boundary-test"
"$build_dir/boundary-test"
