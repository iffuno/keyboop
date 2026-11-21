#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/keyboop-word-edit.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

swiftc -module-cache-path "$build_dir/module-cache" \
    "$repo/Sources/Keyboop/TextReplacer.swift" "$repo/Tests/WordEdit/main.swift" \
    -o "$build_dir/word-edit-test"
"$build_dir/word-edit-test"
