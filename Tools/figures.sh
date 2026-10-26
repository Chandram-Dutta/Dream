#!/bin/zsh
# Checks the geometry behind figures and diagrams on this Mac: fitting, handles, labels and layout.
# Usage: Tools/figures.sh
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/dream-figures"
swiftc -target arm64-apple-macos27.0 -O -o "$out" Dream/Engine/*.swift Tools/figures/main.swift
"$out"
