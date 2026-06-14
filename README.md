# ClaudePet 🐾

A tiny native-macOS desktop pet that watches your Claude usage. A coral pixel critter sits on
your desktop and shows, at a glance, how close you are to your limits — reading your **local**
Claude Code logs only. **No API key, no network, no token.**

<p align="center">
  <img src="docs/widget-compact.png" width="280" alt="Compact one-glance widget">
  &nbsp;&nbsp;
  <img src="docs/widget-large.png" width="430" alt="Large tiered widget">
</p>

## What it shows

- **One glance (compact):** the pet, the limit you're closest to as a single big %, a status
  word, and one muted line — "Resets in 2h 19m · ~$26.38 today."
- **Tiered (large):** the pet + a plain-language status, both limits (the binding one in coral),
  a real per-model split (Opus / Sonnet / Haiku tokens + cost), and a daily/weekly summary.
- **The pet reacts.** It's *Cruising* with headroom and *At the wall* near a cap — the status
  word carries the same signal as the colour, so it reads even if you're colour-blind.

## Install (macOS 14+)

1. Download **`ClaudePet-x.y.z.dmg`** from the [Releases](../../releases) page.
2. Open the DMG and **drag ClaudePet to Applications**.
3. **First launch only** — the app is signed ad-hoc (not via a paid Apple Developer account), so
   macOS Gatekeeper asks for a one-time confirmation:
   - **Right-click** `ClaudePet` in Applications → **Open** → **Open** in the dialog. *(Just
     double-clicking the first time will refuse — use right-click → Open.)*
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/ClaudePet.app`

After that it opens normally. It's a **dockless agent** (no Dock icon) — the pet just appears on
your desktop. Drag it anywhere; it floats above other windows, shows on all Spaces, and remembers
its position. Enable **Launch at login** in Settings to keep it around.

## Using it

- **Drag** the pet to reposition. Hover to reveal resize handles.
- Click the **⚙ gear** for Settings.
- Two layouts (Settings → Appearance): **compact** (one glance) and **large** (tiered).
- Hover the gauges/numbers for tooltips explaining each value.

## Settings (⚙)

Budget source (auto-peak / plan / custom), tokens-vs-US$ unit, live-data toggle (reads
[claude-statusline](https://github.com/andrewii23/claude-statusline)'s local cache when present
for Claude's *real* numbers), manual calibration, billing-this-cycle, widget size, layout,
launch-at-login, and an editable pricing table.

## Privacy

ClaudePet reads only local files under `~/.claude` (your transcripts, `~/.claude.json`, and —
if installed — the statusline's local cache). It **never** reads your OAuth token, and it makes
**no network requests**. Token counts come straight from your transcripts; cost is a *notional*
API-equivalent estimate (you're likely on a subscription).

## Uninstall

Quit (Settings → Quit, or `pkill -x ClaudePet`), then drag `/Applications/ClaudePet.app` to the
Trash. Preferences live in `~/Library/Preferences/com.napat.ClaudePet.plist`.

## Build from source

Requires Xcode 16 / Swift 6 on macOS 14+.

```bash
git clone https://github.com/jjnnaappaatt/ClaudePet.git
cd ClaudePet
swift test            # data-engine unit tests
./bundle.sh release   # build ClaudePet.app (ad-hoc signed, non-sandboxed)
open ClaudePet.app
./release.sh          # optional: package dist/ClaudePet-<version>.dmg
```

**Architecture:** `ClaudePetCore` is pure, unit-tested Swift (models, JSONL parser + dedup,
aggregator, 5-hour/weekly engines, pricing, `MetricsStore`, mascot logic). The app layer is a
`FloatingPanel` (NSPanel) hosting SwiftUI, with a pixel-matrix mascot renderer. A web mirror of
the UI (for [claude.ai/design](https://claude.ai/design)) lives in `frontend/`.

## License

[MIT](LICENSE) © 2026 JJ_NAPAT.
