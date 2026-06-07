# ClaudePet 🐾

A native macOS floating desktop companion that monitors your Claude usage with an
ambient pixel-art Claude mascot. Reads your local Claude Code logs — **no API key,
no network**.

![widget](docs/widget.png)

## What it shows

- **Today** — work tokens (input+output), total billable tokens (incl. cache), and cost
- **5-hour block** — a gauge toward your budget (switchable tokens / US$), burn rate, reset countdown
- **Per-model** — Opus / Sonnet / Haiku split with cost (unknown models flagged "unpriced")
- **Week & all-time** totals
- An **ambient pixel mascot** (sit / blink / walk / hop) that pauses when hidden / Low Power / Reduce Motion

## How it works

Parses `~/.claude/projects/**/*.jsonl` (incl. `subagents/agent-*.jsonl`), **deduplicates by
`message.id`** (~half of raw lines are duplicates), excludes `<synthetic>` lines, and computes
cost from an **editable, dated pricing table** (cache read 0.1×, write 1.25×/2× input). Live
updates via FSEvents with incremental re-parse (only changed files). Cost is notional
API-equivalent (you're likely on a subscription).

## Build & run

```bash
swift test            # data-engine unit tests
./bundle.sh release   # build ClaudePet.app (ad-hoc signed, non-sandboxed)
open ClaudePet.app
```

To keep it permanently: move `ClaudePet.app` to `/Applications`, then enable **Launch at login**
in Settings (gear icon). A stable path makes the login item reliable.

It runs as a dockless agent (no Dock icon). Drag it anywhere; it remembers its position,
floats above other windows, and shows on all Spaces. Quit via `pkill -x ClaudePet`
(a quit affordance can be added later).

## Settings (gear icon)

5-hour budget + unit (tokens/US$), include-subagent-usage toggle, launch-at-login, and an
editable pricing table (with "reset to defaults").

## Architecture

- **`ClaudePetCore`** (pure Swift, unit-tested) — models, JSONL parser, dedup, aggregator,
  5-hour block engine, pricing, file watcher, `MetricsStore`, and the pure mascot logic
  (`MascotArt`/`MascotMachine`/`MascotEngine`).
- **App** — `FloatingPanel` (NSPanel) hosting SwiftUI via `NSHostingView`; SwiftUI views;
  pixel-matrix mascot renderer.

## Verification

Built/verified headlessly with a permission-free `ImageRenderer` snapshot mode
(`CLAUDEPET_SNAPSHOT`, `CLAUDEPET_MASCOT`, `CLAUDEPET_SETTINGS`), on-screen window
geometry/level checks, a live file-watcher heartbeat, and 33 unit tests.
