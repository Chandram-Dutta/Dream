#!/bin/zsh
# Checks sync on this Mac: the merge rules with two phones and a stand-in for the server (changes
# made offline on both, deletions, a slow clock, ties, pages of changes, payloads from other
# versions), and reading changes from SwiftData's history in a real store. With DREAM_SYNC_URL
# (say http://127.0.0.1:8787, from `npx wrangler dev` in Server/ with DEV_LOGIN=1 in .dev.vars),
# the same two phones also sync through the real Worker.
# Usage: Tools/sync.sh
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/dream-sync"
swiftc -target arm64-apple-macos27.0 -o "$out" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift \
  Dream/Memory/PageTurn.swift Dream/Memory/PageHistory.swift Dream/Memory/SavedSurface.swift Dream/Memory/MemoryFact.swift Dream/Lists/StoredRecord.swift \
  Dream/Sync/SyncItem.swift Dream/Sync/SyncPayloads.swift Dream/Sync/SyncLedger.swift Dream/Sync/SyncClient.swift Dream/Sync/SyncHistory.swift \
  Tools/sync/main.swift
"$out"
