#!/bin/zsh
# Checks web search and citations on this Mac: addresses, the checker holding citations to what
# was read, fencing untrusted text for the model, and per-screen limits. No model is used. With
# DREAM_WEB_URL (say http://127.0.0.1:8787, from `npx wrangler dev` in Server/) and DREAM_WEB_KEY,
# it also searches and reads once through the Worker.
# Usage: Tools/web.sh
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/dream-web"
swiftc -target arm64-apple-macos27.0 -o "$out" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift Tools/web/main.swift
"$out"
