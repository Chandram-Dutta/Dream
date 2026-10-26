#!/bin/zsh
# Checks the geometry behind figures and diagrams on this Mac: fitting, handles, labels and layout
# (DreamTests/FiguresTests.swift, run by Tools/tests.sh).
# Usage: Tools/figures.sh
set -e
cd "$(dirname "$0")/.."
Tools/tests.sh "FiguresTests|DiagramsTests"
