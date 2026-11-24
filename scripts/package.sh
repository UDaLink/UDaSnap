#!/bin/bash
# Create the release zip and SHA-256 file from dist/UDaSnap.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/UDaSnap.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="UDaSnap-${VERSION}-macos-universal-unsigned.zip"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/$ZIP"
(cd "$ROOT/dist" && shasum -a 256 "$ZIP" > SHA256SUMS.txt)

echo "Created dist/$ZIP"
echo "Created dist/SHA256SUMS.txt"
