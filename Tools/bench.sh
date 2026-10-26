#!/bin/zsh
# Builds the engine and composer for macOS and runs them on this Mac.
# Usage: Tools/bench.sh [-xaiModel grok-4.7] [-mcp https://mcp.deepwiki.com/mcp] ["a request" ...]
# For Grok, keep the key in the login Keychain: security add-generic-password -a xai -s dream -w
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/dream-bench"
mcp=$(Tools/mcp-sdk.sh)
swiftc -target arm64-apple-macos27.0 -O -o "$out" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift Dream/Connections/*.swift Tools/bench/*.swift ${=mcp}
if [[ -z "$XAI_API_KEY" ]]; then
  export XAI_API_KEY="$(security find-generic-password -a xai -s dream -w 2>/dev/null || true)"
fi
"$out" "$@"
