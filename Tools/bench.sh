#!/bin/zsh
# Builds the engine and composer for macOS and runs them on this Mac.
# Usage: Tools/bench.sh [-provider privateCloud|onDevice] [-reasoning light|moderate|deep]
#        [-mcp https://mcp.deepwiki.com/mcp] ["a request" ...]
# Pages are written by Apple's models: Private Cloud Compute, or the on-device model.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/dream-bench"
mcp=$(Tools/mcp-sdk.sh)
swiftc -target arm64-apple-macos27.0 -O -o "$out" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift Dream/Connections/*.swift Tools/bench/*.swift ${=mcp}
# Web search: the server's app key (account web), with the server as -webServer.
if [[ -z "$DREAM_WEB_KEY" ]]; then
  export DREAM_WEB_KEY="$(security find-generic-password -a web -s dream -w 2>/dev/null || true)"
fi
# Through Dream's server, as the app does: DREAM_SERVER=http://127.0.0.1:8787, from `npx wrangler
# dev` in Server/ with DEV_LOGIN=1 in .dev.vars, gives the bench a test user's session. Without
# it, the bench builds with Wikipedia alone.
if [[ -n "$DREAM_SERVER" ]]; then
  if [[ -z "$DREAM_SESSION" ]]; then
    export DREAM_SESSION="$(curl -sf -X POST "$DREAM_SERVER/api/dev/session?user=bench" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
  fi
  set -- -shareServer "$DREAM_SERVER" "$@"
fi
"$out" "$@"
