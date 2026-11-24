#!/bin/bash
# Build → assemble .app → sign → optionally install into /Applications.
#
# Usage:
#   bash ./build.sh                 # package into dist/UDaSnap.app
#   bash ./build.sh install         # package and install into /Applications
#
# Signing:
#   Default is ad-hoc ("-"). Pass a stable identity explicitly when you want
#   TCC/Keychain permissions to survive recompilation:
#     SIGN_IDENTITY="Your Certificate" bash ./build.sh install
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="UDaSnap"
EXEC_NAME="UDaSnap"
BUNDLE_ID="com.udalink.udasnap"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ARCH_FLAGS=(--arch arm64 --arch x86_64)

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    echo "!! Signing identity '$SIGN_IDENTITY' not found, falling back to ad-hoc."
    SIGN_IDENTITY="-"
fi

cd "$ROOT"

echo "==> Building universal release (arm64 + x86_64)"
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSScreenCaptureUsageDescription</key><string>UDaSnap 需要屏幕录制权限来截取屏幕、窗口和滚动长图。</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 UDaLink. MIT License.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

mkdir -p "$APP/Contents/Resources/Legal"
cp "$ROOT/PRIVACY.md" "$APP/Contents/Resources/Legal/PRIVACY.md"
cp "$ROOT/TERMS.md" "$APP/Contents/Resources/Legal/TERMS.md"

echo "==> Signing ($SIGN_IDENTITY)"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"

if [ "${1:-}" = "install" ]; then
    echo "==> Installing into /Applications"
    for pid in $(ps -eo pid,comm | grep "/$EXEC_NAME\$" | awk '{print $1}'); do
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 0.5
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "Done: /Applications/$APP_NAME.app"
else
    echo "Done: $APP"
fi
