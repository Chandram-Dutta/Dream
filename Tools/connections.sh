#!/bin/zsh
# Checks connected services on this Mac without a model. First what needs no server
# (DreamTests/ConnectionsTests.swift, run by Tools/tests.sh): JSON Schemas made into generation
# schemas, picking tools, when Dream asks before a tool runs and what each answer does, readings
# and the lists they fill, service buttons, services a request names, and what sharing leaves out.
# Then it starts the local test server (Tools/mcp-test-server.py) and talks to it through the MCP
# SDK: connecting, calling tools as the model does, reading one again, and a button's tap.
# Usage: Tools/connections.sh
set -e
cd "$(dirname "$0")/.."
Tools/tests.sh ConnectionsTests
out="${TMPDIR:-/tmp}/dream-connections"
mcp=$(Tools/mcp-sdk.sh)
swiftc -target arm64-apple-macos27.0 -o "$out" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift Dream/Connections/*.swift Tools/connections/main.swift ${=mcp}
port=8766
python3 -I Tools/mcp-test-server.py $port > "${TMPDIR:-/tmp}/dream-connections-server.log" 2>&1 &
server=$!
trap "kill $server 2>/dev/null" EXIT
sleep 1
"$out" "http://127.0.0.1:$port/mcp" "${TMPDIR:-/tmp}/dream-connections-server.log"
