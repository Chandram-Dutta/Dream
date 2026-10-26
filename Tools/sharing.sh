#!/bin/zsh
# Checks sharing on this Mac: what leaves the phone, the web viewer's preview, and opening shared
# surfaces as untrusted input. With DREAM_SHARE_URL (say http://127.0.0.1:8787, from
# `npx wrangler dev` in Server/), it also goes through the Worker and back.
# Usage: Tools/sharing.sh
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/dream-sharing"
swiftc -target arm64-apple-macos27.0 -o "$out" Dream/Engine/*.swift Dream/Sharing/ShareServer.swift Tools/sharing/main.swift
"$out"
