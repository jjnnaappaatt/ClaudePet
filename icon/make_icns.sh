#!/usr/bin/env bash
# Regenerate AppIcon.icns from the 1024px master.
# Re-render the master first with:
#   CLAUDEPET_ICON="$PWD/icon/AppIcon-master.png" ./.build/debug/ClaudePet
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$HERE/AppIcon-master.png"
ISET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ISET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$M" --out "$ISET/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s*2))" "$((s*2))" "$M" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ISET" -o "$HERE/AppIcon.icns"
echo "✓ wrote $HERE/AppIcon.icns"
