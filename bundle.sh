#!/usr/bin/env bash
# Assemble ClaudePet.app from the SwiftPM build product (no Xcode project needed).
#   ./bundle.sh            -> debug build
#   ./bundle.sh release    -> release build
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-debug}"
APP_NAME="ClaudePet"
SUPPORT="$PROJ/Sources/ClaudePet/Supporting"
APP="$PROJ/$APP_NAME.app"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$PROJ"

BIN_DIR="$(swift build -c "$CONFIG" --package-path "$PROJ" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$SUPPORT/Info.plist" "$APP/Contents/Info.plist"
[ -f "$PROJ/icon/AppIcon.icns" ] && cp "$PROJ/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Copy any SwiftPM resource bundles next to the binary into the app (none yet, but future-proof).
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/" || true
done

echo "→ ad-hoc codesign"
codesign --force --sign - --entitlements "$SUPPORT/$APP_NAME.entitlements" "$APP" 2>/dev/null \
  || codesign --force --sign - "$APP"

echo "✓ Built $APP"
