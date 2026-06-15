#!/usr/bin/env bash
# Build a distributable DMG of ClaudePet — ad-hoc signed (no Apple Developer account).
# Users drag the app to /Applications; first launch needs a one-time Gatekeeper bypass
# (right-click → Open, or `xattr -dr com.apple.quarantine`), documented in the README.
#
#   ./release.sh            # test + build + package dist/ClaudePet-<version>.dmg
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJ"

VERSION="$(grep -Eo '"[0-9]+\.[0-9]+\.[0-9]+"' Sources/ClaudePetCore/ClaudePetCore.swift | head -1 | tr -d '"')"
[ -n "$VERSION" ] || { echo "✗ could not read version from ClaudePetCore.swift"; exit 1; }
echo "→ ClaudePet $VERSION"

# Version must match across all three hand-maintained sources, or downloads ship a mismatch.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/ClaudePet/Supporting/Info.plist)"
CHANGELOG_VERSION="$(grep -Eo '## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | head -1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"
[ "$PLIST_VERSION" = "$VERSION" ] || { echo "✗ version mismatch: Info.plist=$PLIST_VERSION vs ClaudePetCore=$VERSION"; exit 1; }
[ "$CHANGELOG_VERSION" = "$VERSION" ] || { echo "✗ version mismatch: CHANGELOG=$CHANGELOG_VERSION vs ClaudePetCore=$VERSION"; exit 1; }
echo "→ version in sync (ClaudePetCore / Info.plist / CHANGELOG)"

echo "→ swift test"
swift test

echo "→ building release app"
./bundle.sh release

APP="$PROJ/ClaudePet.app"
[ -d "$APP" ] || { echo "✗ $APP not found"; exit 1; }

STAGE="$(mktemp -d)/ClaudePet-$VERSION"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-install target

mkdir -p "$PROJ/dist"
DMG="$PROJ/dist/ClaudePet-$VERSION.dmg"
rm -f "$DMG"
echo "→ creating $DMG"
hdiutil create -volname "ClaudePet $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "✓ $DMG"
echo "  Upload to a GitHub Release:  gh release create v$VERSION \"$DMG\" --title \"v$VERSION\" --notes-file CHANGELOG.md"
