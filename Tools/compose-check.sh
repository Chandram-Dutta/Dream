#!/bin/zsh
# Follows pages made on a scripted stand-in for the server's page loop (Tools/compose-mock.py)
# through the app's own client, over the network on this Mac: a page to its end, a dropped line,
# a question, a failure, a page picked up again after the app left it, a job the server no longer
# has, and a photo; then a change of each kind, and the phone's own tools run for the server (one
# answered, one the server stopped waiting for, one the loop went past). The events themselves are
# checked without the network by Tools/tests.sh (DreamTests/ServerComposeTests.swift). No model,
# no Cloudflare.
# Usage: Tools/compose-check.sh       (COMPOSE_MOCK_PORT picks the mock's port; 8790 otherwise)
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/dream-compose-check"
swiftc -target arm64-apple-macos27.0 -o "$out" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift \
  Dream/Sharing/ShareServer.swift Dream/Sharing/ShareServer+Links.swift Tools/compose-check/main.swift
port=${COMPOSE_MOCK_PORT:-8790}
python3 Tools/compose-mock.py $port 2> "${TMPDIR:-/tmp}/dream-compose-mock.log" &
mock=$!
trap "kill $mock 2>/dev/null" EXIT
for i in {1..50}; do
  curl -s -o /dev/null "http://127.0.0.1:$port/mock/jobs/none" && break
  sleep 0.1
done
DREAM_SESSION=mock-session DREAM_WEB_KEY=mock-key "$out" -shareServer "http://127.0.0.1:$port"
