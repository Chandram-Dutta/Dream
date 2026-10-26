#!/bin/zsh
# Renders 3D scenes to PNG files on this Mac with the app's own stage, to look at them without a
# device. With no requests, renders the built-in examples (and molecules from PubChem); with
# requests, composes each on Grok first, like the bench, saves the surface as JSON, and renders
# the scenes it makes. A .json file from an earlier run is rendered again without the model.
# Usage: Tools/scene-preview.sh <output folder> ["a request" | surface.json ...]
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/dream-scene-preview"
swiftc -target arm64-apple-macos27.0 -O -o "$out" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift Dream/UI/Blocks/SceneStage.swift Tools/scene-preview/main.swift
if [[ $# -gt 1 && -z "$XAI_API_KEY" ]]; then
  export XAI_API_KEY="$(security find-generic-password -a xai -s dream -w 2>/dev/null || true)"
fi
"$out" "$@"
