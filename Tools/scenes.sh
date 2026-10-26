#!/bin/zsh
# Checks the geometry behind 3D scenes on this Mac: placement, fit, projection, meshes and
# molecules. No model and no network involved. Build and run with Tools/scenes.sh.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/dream-scenes"
swiftc -target arm64-apple-macos27.0 -O -o "$out" Dream/Engine/*.swift Tools/scenes/main.swift
"$out"
