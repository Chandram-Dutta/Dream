#!/bin/zsh
# Builds the MCP Swift SDK for this Mac, once per temp folder, and prints the swiftc flags that
# compile and link Dream/Connections against it. The bench scripts use it; the version matches
# the app's package (Dream.xcodeproj). Build output goes to stderr.
# Usage: flags=$(Tools/mcp-sdk.sh)
set -e
pkg="${TMPDIR:-/tmp}/dream-mcp-sdk"
mkdir -p "$pkg/Sources/Shim"
cat > "$pkg/Package.swift" <<'EOF'
// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "DreamMCPSDK",
    platforms: [.macOS("27.0")],
    dependencies: [.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")],
    targets: [.target(name: "Shim", dependencies: [.product(name: "MCP", package: "swift-sdk")])]
)
EOF
echo "import MCP" > "$pkg/Sources/Shim/Shim.swift"
swift build -c release --package-path "$pkg" >&2
bin="$pkg/.build/release"
echo "-I $bin $bin/MCP.o $bin/Logging.o $bin/EventSource.o"
