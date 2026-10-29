#!/bin/zsh
# Writes Server/test/golden/expected/ from Server/test/golden/cases/: what the app's own engine
# (Dream/Engine) makes of each model answer there, which the server's port of it must match
# (Server/test/engine.mjs, in `npm test`). Run it after changing the engine or adding a case, then
# port the change and run the server's tests. No model and no network.
#
# Each case is run in its reader's locale (its `locale`, en_US if none), since the checker reads
# the user's currency and units from it.
set -e
cd "$(dirname "$0")/.."
bin="${TMPDIR:-/tmp}/dream-engine-golden"
mcp=$(Tools/mcp-sdk.sh)
# Built again only when a source changed: it takes a couple of minutes.
if [[ ! -x "$bin" || -n $(find Dream/Engine Dream/Generation Dream/Connections Tools/engine-golden -name '*.swift' -newer "$bin") ]]; then
  swiftc -target arm64-apple-macos27.0 -O -o "$bin" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift Dream/Connections/*.swift Tools/engine-golden/main.swift ${=mcp}
fi
export TZ=UTC
cases=Server/test/golden/cases
expected=Server/test/golden/expected
rm -rf "$expected"
mkdir -p "$expected"
locales=$(/usr/bin/python3 -c 'import json,glob,sys; print("\n".join(sorted({json.load(open(f)).get("locale", "en_US") for f in glob.glob(sys.argv[1] + "/*.json")})))' "$cases")
for locale in ${(f)locales}; do
  "$bin" "$cases" "$expected" "$locale" -AppleLocale "$locale"
done
