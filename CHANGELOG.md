# Changelog

All notable changes to ClaudePet are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com); versions are dated on release.

## [Unreleased]

### Added
- **Today daily-pace bar** in the gauges column, beneath the 5h and weekly bars — today's tokens
  measured against your recent daily average (from the 7-day data the app already tracks). Claude
  has no daily limit, so it's an informational pace gauge: the average day sits at the midpoint, so
  a full bar is roughly twice a usual day. Respects the tokens/USD unit; local data only.
- **Reactive weather & celebrations** behind the pet — an ambient pixel sky that follows your usage,
  driven by the same mood signal as the mascot's face: a gentle sun when idle or with headroom,
  drifting clouds at mid-usage, rain as you approach a limit, and a heavy storm with lightning at the
  edge. A fresh 5-hour window triggers a confetti burst; crossing into the danger zone (≥95%)
  triggers a lightning strike (each fires once, on the transition). The sky sits in a taller scene
  above the pet so the two never overlap. Honors Reduce Motion, pauses when occluded / in Low Power,
  and can be turned off via Settings → Appearance → "Weather effects" (on by default).

### Changed
- Wide layout: grouped the numeric blocks (5h, weekly, by-model, totals, billing) in the right
  column and kept the pet header + weekly chart on the left, so the two columns balance in height.
- The 5h and weekly gauge captions now render at a single consistent size (no per-block shrinking).

### Fixed
- **Much lower memory use.** Transcript files (which reach 100 MB+) are now read in 1 MB streaming
  chunks instead of loaded whole, and the JSON parse drains an autorelease pool per chunk/file so
  temporaries don't pile up. On a ~900 MB history the scan peak dropped from ~885 MB to ~260 MB and
  the steady footprint from ~250 MB to ~170 MB, with no change to the parsed results.

## [0.2.1] — 2026-06-15

### Fixed
- The plan badge ("Max 5×") in the wide layout's Today header no longer wraps one character
  per line when space is tight — it stays on a single line like the adjacent labels.

### Changed
- Live statusline data is now treated as **stale after 30 minutes**. If the statusline hasn't
  refreshed its local cache recently, ClaudePet drops the `live` badge and falls back to the
  local estimate instead of presenting an outdated percentage as current. The cache age
  ("2m ago") still shows so you can see why.

## [0.2.0] — 2026-06-14

First public release.

### Added
- MIT `LICENSE`, an end-user `README` (install + Gatekeeper steps, statusline/live-data setup,
  screenshots), and `release.sh` — builds a drag-install DMG, ad-hoc signed (no Apple Developer
  account needed).
- A web mirror of the UI for [claude.ai/design](https://claude.ai/design) under `frontend/`.

### Notes
- Ships the classic widget: Today header (work / cache / cost), live 5-hour + weekly gauges,
  by-model split, a weekly chart, Week & cycle totals, billing, and the ambient pixel mascot.

## [0.1.0]

- Initial build: live Claude-usage widget (5h + weekly gauges, per-model split, weekly chart,
  billing), statusline live-data integration, calibration, and the emotional pixel mascot.
