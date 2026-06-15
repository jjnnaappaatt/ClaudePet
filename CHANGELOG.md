# Changelog

All notable changes to ClaudePet are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com); versions are dated on release.

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
