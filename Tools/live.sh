#!/bin/zsh
# Checks sources, live inputs and actions on this Mac: days and times, units, the checker's
# bindings and actions (DreamTests/LiveTests.swift, run by Tools/tests.sh), then the live tool
# against real exchange rates and MapKit. Weather stands in, since WeatherKit won't authorize an
# unsigned tool. No model is used.
# Usage: Tools/live.sh
set -e
cd "$(dirname "$0")/.."
Tools/tests.sh LiveTests
out="${TMPDIR:-/tmp}/dream-live"
swiftc -target arm64-apple-macos27.0 -o "$out" Dream/Engine/*.swift Dream/Generation/*.swift Dream/Generation/Providers/*.swift Tools/live/main.swift
"$out"
