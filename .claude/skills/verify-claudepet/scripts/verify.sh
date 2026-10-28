#!/usr/bin/env bash
# Drive ClaudePet for verification without touching the user's running copy.
#   verify.sh build                     debug build -> .build/verify/ClaudePet.app (never ./ClaudePet.app);
#                                       VERIFY_CONFIG=release for performance measurements
#   verify.sh doctor                    read-only: is the verify bundle current and safe to drive?
#   verify.sh run <label> [K=V ...]     run the bundle once with env K=V, log to .verify-artifacts/<run>/<label>.log
#   verify.sh cleanup                   kill only the pids this script started; artifacts are kept
# "@ART@" inside any K=V value expands to this run's artifact dir.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
APP="$ROOT/.build/verify/ClaudePet.app"
BIN="$APP/Contents/MacOS/ClaudePet"
ARTROOT="$ROOT/.verify-artifacts"
RUN_ID="${VERIFY_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
ART="$ARTROOT/$RUN_ID"
PIDS="$ARTROOT/pids"
TIMEOUT="${VERIFY_TIMEOUT:-200}"   # PANELFIT gives up at 180s by itself
CONFIG="${VERIFY_CONFIG:-debug}"   # release only for performance numbers; debug scans ~2x slower

cmd="${1:-}"; shift || true
case "$cmd" in
build)
  swift build -c "$CONFIG" --package-path "$ROOT"
  bin_dir="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$bin_dir/ClaudePet" "$BIN"
  cp "$ROOT/Sources/ClaudePet/Supporting/Info.plist" "$APP/Contents/Info.plist"
  [ -f "$ROOT/icon/AppIcon.icns" ] && cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/"
  # Without these the binary traps at launch in resource_bundle_accessor ("ClaudePet_ClaudePet").
  for b in "$bin_dir"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
  codesign --force --sign - --entitlements "$ROOT/Sources/ClaudePet/Supporting/ClaudePet.entitlements" "$APP" 2>/dev/null \
    || codesign --force --sign - "$APP"
  echo "$CONFIG" > "$APP/Contents/Resources/verify-config"
  git -C "$ROOT" rev-parse --short HEAD > "$APP/Contents/Resources/verify-rev"
  git -C "$ROOT" status --porcelain -- Sources | grep -q . && echo dirty >> "$APP/Contents/Resources/verify-rev" || true
  echo "built $APP ($CONFIG, $(tr '\n' ' ' < "$APP/Contents/Resources/verify-rev"))"
  ;;
doctor)
  ok=1
  if [ -x "$BIN" ]; then echo "bundle: $APP"; else echo "FAIL bundle missing: run verify.sh build"; ok=0; fi
  if [ $ok = 1 ]; then
    echo "version: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    echo "config: $(cat "$APP/Contents/Resources/verify-config" 2>/dev/null || echo debug)"
    echo "built from: $(tr '\n' ' ' < "$APP/Contents/Resources/verify-rev" 2>/dev/null || echo unknown)  HEAD: $(git -C "$ROOT" rev-parse --short HEAD)"
    newer="$(find "$ROOT/Sources" -name '*.swift' -newer "$BIN" | head -3)"
    if [ -n "$newer" ]; then echo "FAIL stale: sources newer than the bundle, e.g. $newer"; ok=0; else echo "fresh: no source newer than the bundle"; fi
  fi
  live="$(pgrep -f "$ROOT/ClaudePet.app/Contents/MacOS/ClaudePet" || true)"
  echo "user's live widget: ${live:-not running} (never drive or kill it)"
  if [ -f "$PIDS" ]; then
    while read -r p; do kill -0 "$p" 2>/dev/null && echo "WARN verify pid $p still running: verify.sh cleanup"; done < "$PIDS"
  fi
  [ $ok = 1 ] && echo "doctor: OK" || { echo "doctor: FAIL"; exit 1; }
  ;;
run)
  label="${1:?usage: verify.sh run <label> [K=V ...]}"; shift
  [ -x "$BIN" ] || { echo "no bundle: run verify.sh build"; exit 1; }
  mkdir -p "$ART"
  envs=()
  for kv in "$@"; do envs+=("${kv//@ART@/$ART}"); done
  log="$ART/$label.log"
  { echo "# command: env ${envs[*]} $BIN"; echo "# rev: $(tr '\n' ' ' < "$APP/Contents/Resources/verify-rev")"; echo "# started: $(date -u +%FT%TZ)"; } > "$log"
  env "${envs[@]}" "$BIN" >>"$log" 2>&1 &
  pid=$!
  echo "$pid" >> "$PIDS"
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$TIMEOUT" ]; do sleep 1; waited=$((waited+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "# TIMEOUT after ${TIMEOUT}s, killed $pid" >> "$log"; code=124
  else wait "$pid" && code=0 || code=$?; fi
  echo "# exit: $code" >> "$log"
  grep -v '^$' "$log"
  echo "artifacts: $ART"
  exit "$code"
  ;;
cleanup)
  if [ -f "$PIDS" ]; then
    while read -r p; do kill -0 "$p" 2>/dev/null && kill "$p" && echo "killed verify pid $p"; done < "$PIDS"
    rm -f "$PIDS"
  fi
  echo "artifacts kept in $ARTROOT"
  ;;
*) sed -n 2,9p "$0"; exit 2 ;;
esac
