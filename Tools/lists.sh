#!/bin/zsh
# Checks lists on this Mac: totals over entries, the checker, record changes, field changes and
# the quick-add bar (DreamTests/ListsTests.swift, run by Tools/tests.sh). With -talk 1, it also
# tries a few sentences on the on-device model (and Grok if that falls back; the key comes from
# the login Keychain and is never printed). With -edit 1, it changes a list's fields through the
# composer and moves the entries onto them.
# Usage: Tools/lists.sh [-talk 1] [-edit 1]
set -e
cd "$(dirname "$0")/.."
Tools/tests.sh ListsTests
[[ $# -eq 0 ]] && exit 0
out="${TMPDIR:-/tmp}/dream-lists"
swiftc -target arm64-apple-macos27.0 -o "$out" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift Tools/lists/main.swift
if [[ -z "$XAI_API_KEY" ]]; then
  export XAI_API_KEY="$(security find-generic-password -a xai -s dream -w 2>/dev/null || true)"
fi
"$out" "$@"
