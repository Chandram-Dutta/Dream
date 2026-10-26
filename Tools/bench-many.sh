#!/bin/zsh
# Builds the bench, then runs each request on Grok in parallel, one output file per request.
# The xAI key comes from the login Keychain (service dream, account xai) and is never printed.
# Settings for every run go before the folder's requests as "-name value" pairs, like
# Tools/bench-many.sh out -mcp https://mcp.deepwiki.com/mcp "request" ...
# Usage: Tools/bench-many.sh <output folder> "request" ...
cd "$(dirname "$0")/.."
out=$1; shift
mkdir -p "$out"
bin="${TMPDIR:-/tmp}/dream-bench"
mcp=$(Tools/mcp-sdk.sh) || exit 1
swiftc -target arm64-apple-macos27.0 -O -o "$bin" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift Dream/Connections/*.swift Tools/bench/*.swift ${=mcp} || exit 1
if [[ -z "$XAI_API_KEY" ]]; then
  export XAI_API_KEY="$(security find-generic-password -a xai -s dream -w 2>/dev/null || true)"
fi
settings=()
while [[ "$1" == -* ]]; do
  settings+=("$1" "$2"); shift 2
done
for request in "$@"; do
  "$bin" -provider xai "${settings[@]}" "$request" > "$out/$(echo $request | tr ' /' '--').txt" 2>&1 &
done
wait
