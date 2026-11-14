#!/bin/zsh
# Runs DreamTests (Swift Testing, in DreamTests/) on this Mac, without a Simulator or an iPhone.
# The code the Mac tools already build (Dream/Engine, Dream/Generation, Dream/Sharing/ShareServer*.swift,
# and a saved page from Dream/Memory) is compiled for macOS as a module named Dream, in a Swift package under $TMPDIR that links to the
# sources, so the tests' `@testable import Dream` works just as it does in Xcode's DreamTests
# target. It's optimized, like the tools, so the timing checks mean something, and later runs
# only rebuild what changed. No model and no network.
#
# Usage: Tools/tests.sh [filter]     a regular expression over test names, like FiguresTests or "Lists|Sharing"
#
# In Xcode the same tests run in the app (scheme Dream, Product › Test). From the command line
# that needs an iOS 27 Simulator runtime, or the iPhone:
#   xcodebuild test -project Dream.xcodeproj -scheme Dream -destination 'platform=iOS Simulator,name=iPhone 17'
# A generic destination can only build them: xcodebuild build-for-testing … -destination 'generic/platform=iOS Simulator'
set -e
cd "$(dirname "$0")/.."
root=$PWD
pkg="${TMPDIR:-/tmp}/dream-tests"
[[ -L "$pkg/Sources/Dream" ]] && rm "$pkg/Sources/Dream"
mkdir -p "$pkg/Sources/Dream/Sharing" "$pkg/Sources/Dream/Memory" "$pkg/Tests"
ln -sfn "$root/Dream/Engine" "$pkg/Sources/Dream/Engine"
ln -sfn "$root/Dream/Generation" "$pkg/Sources/Dream/Generation"
ln -sfn "$root/Dream/Sharing/ShareServer.swift" "$pkg/Sources/Dream/Sharing/ShareServer.swift"
ln -sfn "$root/Dream/Sharing/ShareServer+Links.swift" "$pkg/Sources/Dream/Sharing/ShareServer+Links.swift"
# A saved page.
for file in SavedSurface PageTurn PageHistory; do
  ln -sfn "$root/Dream/Memory/$file.swift" "$pkg/Sources/Dream/Memory/$file.swift"
done
ln -sfn "$root/DreamTests" "$pkg/Tests/DreamTests"
# Written only when it changes, so an unchanged package isn't worked out again.
manifest=$(cat <<'EOF'
// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "DreamTests",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "Dream", path: "Sources/Dream", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DreamTests", dependencies: ["Dream"], path: "Tests/DreamTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
EOF
)
if [[ "$(cat "$pkg/Package.swift" 2>/dev/null)" != "$manifest" ]]; then
  print -r -- "$manifest" > "$pkg/Package.swift"
fi
# A debug build (testable, and rebuilt a file at a time) with the optimizer on.
args=(--package-path "$pkg" -Xswiftc -O)
[[ -n "$1" ]] && args+=(--filter "$1")
swift test "${args[@]}"
