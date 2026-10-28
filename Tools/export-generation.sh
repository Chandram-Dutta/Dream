#!/bin/zsh
# Writes Server/src/generated/generation.json from the app's prompts, schemas and tools, so the
# server makes pages with exactly what the app would send (docs/ServerGeneration.md). Run it after
# changing any of them, then deploy.
set -e
cd "$(dirname "$0")/.."
bin="${TMPDIR:-/tmp}/dream-export-generation"
mcp=$(Tools/mcp-sdk.sh)
swiftc -target arm64-apple-macos27.0 -O -o "$bin" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift Dream/Connections/*.swift Tools/export-generation/main.swift ${=mcp}
mkdir -p Server/src/generated
"$bin" | /usr/bin/python3 -c 'import json,sys; json.dump(json.load(sys.stdin), sys.stdout, ensure_ascii=False, indent=1); print()' > Server/src/generated/generation.json
echo "Wrote Server/src/generated/generation.json"
