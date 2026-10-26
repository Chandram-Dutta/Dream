#!/bin/zsh
# Checks the geometry behind 3D scenes on this Mac: placement, fit, projection, meshes and
# molecules (DreamTests/ScenesTests.swift, run by Tools/tests.sh). No model and no network involved.
# Usage: Tools/scenes.sh
set -e
cd "$(dirname "$0")/.."
Tools/tests.sh ScenesTests
