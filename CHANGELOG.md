# Changelog

All notable changes to ClaudePet are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com); versions are dated on release.

## [Unreleased]

## [0.3.0] — 2026-07-20

### Added
- **"Override billing cycle day" setting** (Settings → Match the Claude app) for accounts — mainly
  team/org plans — whose real Stripe billing anchor doesn't match the subscription date ClaudePet
  reads locally (that date can reflect when *your seat* was created, not when the organization's
  invoice recurs). Enter the day-of-month your invoices actually land on and the Cycle total/countdown
  switches to it immediately; off by default (uses the subscription-derived anchor).
- **Cycle reset date** on the "Cycle" line — now shows "· resets in Nd Nh" and the tooltip lists the
  actual billing-cycle date range (e.g. "Jun 16 – Jul 16"), matching the "resets in" treatment the 5h
  and weekly gauges already have. Local data only.
- **"Count tokens as: Work / Total" setting** (Settings → Appearance) that governs every per-day
  token figure — the weekly chart, the "Today by hour" sparkline, the daily-pace bar, the per-model
  split, the Week & cycle line, and the Today header's headline. It now defaults to **Total**
  (input + output + cache reads & writes), so the numbers reflect the tokens Claude actually
  processes. Previously these showed **work** (input + output) only, which under always-on prompt
  caching is ~1% of real volume — so a day could read ~100× lower than expected. Switch back to
  **Work** to restore the old view. Cost ($) is unchanged (always cache-inclusive). Local data only.
- **"Today by hour" sparkline** in the wide layout's left column, beneath the weekly chart — a 24-bar
  mini chart of today's tokens bucketed by local hour, so you can see *when* in the day you worked.
  Highlights the current hour, respects the tokens/USD unit, and captions your busiest hour. Local
  data only (the usage the app already scans; no token, no network).
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
- **Mascot redesigned as a faithful Clawd** — the Claude Code terminal mascot: flat coral
  rounded-rectangle body, plain dark square eyes (no glints), no mouth, small side claw-arms, and
  four tiny feet, matching the CLI sprite's proportions and poses. It now emotes the way the real
  sprite does: idle glances left/right, arms raised to celebrate a fresh window, closed eyes +
  zzz asleep, wide eyes with sweat/alarm marks under pressure. The app icon was regenerated to
  match. Still 100% original code-drawn pixels (an homage — no artwork copied or bundled).
- Wide layout: grouped the numeric blocks (5h, weekly, by-model, totals, billing) in the right
  column and kept the pet header + weekly chart on the left, so the two columns balance in height.
- The 5h and weekly gauge captions now render at a single consistent size (no per-block shrinking).

### Fixed
- **Billing-cycle start date.** The monthly cycle now anchors to the exact subscription *instant*
  (its monthly anniversary) instead of reconstructing a day-of-month by hand. This fixes three latent
  bugs that mis-mapped the cycle for some accounts (verified correct for a day-16 subscription; not
  previously exercised for others): subscriptions created on the 29th–31st renewed a day late on short
  months (e.g. an anchor of the 31st still showed the prior cycle through all of June 30 instead of
  resetting that day); the anchor day could be misread when the subscription's UTC timestamp fell near
  local midnight in timezones far from UTC; and the cycle boundary landed at local midnight rather than
  the real renewal time-of-day, misattributing up to a day of usage right at the boundary.
- **Model pricing accuracy.** Mythos 5 is now priced as Fable ($10/$50) instead of showing as
  unpriced; deprecated Opus 4.1 uses its true $15/$75 rate rather than the current Opus $5/$25; and
  Claude Sonnet 5's introductory $2/$10 rate is applied to usage through 2026-08-31, reverting to
  $3/$15 after. Version-specific rates are handled by a new per-model override layer over the
  family rates; the four family rates are unchanged and verified current.
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
