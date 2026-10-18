#!/bin/zsh
# Builds a universal (arm64 + x86_64) ClaudeUsageBar.app, min macOS 13.
# Usage: ./build.sh [output-dir]   (default: ~/Applications)
set -e
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications}"
APP="$OUT/ClaudeUsageBar.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O -target arm64-apple-macos13.0  main.swift -o "$TMP/arm64"
swiftc -O -target x86_64-apple-macos13.0 main.swift -o "$TMP/x86_64"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/ClaudeUsageBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built: $APP"
