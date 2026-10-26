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
# Web search: the server's app key (account web), with the server as -webServer.
if [[ -z "$DREAM_WEB_KEY" ]]; then
  export DREAM_WEB_KEY="$(security find-generic-password -a web -s dream -w 2>/dev/null || true)"
fi
# Through Dream's server, as the app does: DREAM_SERVER=http://127.0.0.1:8787, from `npx wrangler
# dev` in Server/ with DEV_LOGIN=1 in .dev.vars, gives the bench a test user's session. Without
# it, the bench calls Grok directly with the xAI key.
if [[ -n "$DREAM_SERVER" ]]; then
  if [[ -z "$DREAM_SESSION" ]]; then
    export DREAM_SESSION="$(curl -sf -X POST "$DREAM_SERVER/api/dev/session?user=bench" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
  fi
  set -- -shareServer "$DREAM_SERVER" "$@"
fi
"$out" "$@"
