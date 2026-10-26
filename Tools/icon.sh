#!/bin/zsh
# Draws Dream's app icon (Tools/icon/main.swift) and writes its three appearances, any, dark and
# tinted, into the asset catalog. Change the parameters at the top of main.swift, then run this.
# Usage: Tools/icon.sh [output folder]
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/dream-icon"
swiftc -target arm64-apple-macos27.0 -O -o "$out" Tools/icon/main.swift
"$out" "${1:-Dream/Assets.xcassets/AppIcon.appiconset}"
