# Changelog

All notable changes to ClaudePet are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com); versions are dated on release.

## [0.2.0] — 2026-06-14

A "prioritise-and-restraint" redesign — the pet earns its name — plus first public release.

### Changed
- **Compact (vertical) widget → one glance.** Just the mascot, the *binding* limit (whichever
  of the 5-hour / weekly limit is closer) as one large %, a status word, and a single muted line
  (`Resets in … · ~$… today`). Everything else moved out of the glance.
- **Large (landscape) widget → tiered, pet-anchored.** Mascot anchor + a plain-language status
  sentence; a **LIMITS** block (5-hour + weekly) where **only the binding one wears coral**; a real
  **by-model** split; and one muted summary line. The billing block now lives in Settings.
- **The mascot is bigger and speaks.** A status word ("Cruising / Steady / Getting tight / At the
  wall") carries the same signal as the gauge colour, so state reads even without colour.
- **Accessibility:** a ≥13px legible-type floor, and **one coral accent per card** (coral is spent
  only on the binding limit; other numbers are neutral).

### Added
- `MetricsStore` status API: `bindingFraction`, `bindingIsWeekly`, `bindingResetDate`,
  `statusWord`, `statusLine(now:)`, `statusLevel` (with unit tests).
- First public packaging: MIT `LICENSE`, end-user `README`, and a `release.sh` that builds a DMG.

### Notes
- Palette, charcoal card, rounded tabular numerals, and the pixel mascot are unchanged — this is a
  restraint pass, not a rebuild.

## [0.1.0]

- Initial build: live Claude-usage widget (5h + weekly gauges, per-model split, weekly chart,
  billing), statusline live-data integration, calibration, and the emotional pixel mascot.
