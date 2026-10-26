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
# Web search: the server's app key (account web), with the server as -webServer.
if [[ -z "$DREAM_WEB_KEY" ]]; then
  export DREAM_WEB_KEY="$(security find-generic-password -a web -s dream -w 2>/dev/null || true)"
fi
# Through Dream's server with DREAM_SERVER, as in bench.sh; otherwise straight to Grok.
provider=(-provider xai)
if [[ -n "$DREAM_SERVER" ]]; then
  if [[ -z "$DREAM_SESSION" ]]; then
    export DREAM_SESSION="$(curl -sf -X POST "$DREAM_SERVER/api/dev/session?user=bench" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
  fi
  provider=(-provider dream -shareServer "$DREAM_SERVER")
fi
settings=()
while [[ "$1" == -* ]]; do
  settings+=("$1" "$2"); shift 2
done
for request in "$@"; do
  "$bin" "${provider[@]}" "${settings[@]}" "$request" > "$out/$(echo $request | tr ' /' '--').txt" 2>&1 &
done
wait
