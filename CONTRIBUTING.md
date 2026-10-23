# Contributing to ClaudePet

Thanks for considering a contribution. ClaudePet is a small, single-maintainer project — keep
PRs focused and this'll be a quick, pleasant process.

## Two hard constraints

These aren't style preferences — they're the reason the app is trustworthy, and PRs that cross
them won't be merged regardless of how good the feature is.

1. **Local files only.** ClaudePet reads `~/.claude/projects/**/*.jsonl`, `~/.claude.json`, and
   (optionally) the [claude-statusline](https://github.com/andrewii23/claude-statusline) local
   cache at `/tmp/claude/statusline-usage-cache.json`, plus Codex's own session files in
   `~/.codex/sessions` for the Codex row. It never reads your OAuth token, never
   calls an Anthropic API, and makes **no network requests** of any kind. If a feature needs data
   ClaudePet doesn't already have locally, it's out of scope — don't add a network call or read
   the token to get it. The one non-file read is the Mac's own temperature sensors (IOKit, for the
   header's device readout) — still on-device, still no network.
2. **Original art only.** The mascot is a code-drawn homage to Clawd (the Claude Code terminal
   mascot) — every pixel is generated in `MascotArt.swift`/`PixelMatrixRenderer.swift`, nothing is
   copied from Anthropic's actual assets. Keep it that way; don't bundle third-party art.

## Project layout

- `Sources/ClaudePetCore/` — the pure-Swift data engine: JSONL parsing (`JSONLParser.swift`),
  dedup (`Deduplicator.swift`), scanning (`LogScanner.swift`), aggregation (`Aggregator.swift`),
  pricing (`Pricing.swift`), the 5h/weekly window engines, account/billing-cycle detection
  (`AccountInfo.swift`), and `MetricsStore` — the `@Observable` view model everything reads from.
  No AppKit/SwiftUI here, so it's fully unit-testable in isolation.
- `Sources/ClaudePet/` — the app layer: SwiftUI views (`UI/`), the pixel mascot renderer
  (`Mascot/`), and the `NSPanel`-hosted floating window (`App/`).
- `frontend/` — a self-contained HTML mirror of the widget's design (colors, mascot moods,
  gauges, both layouts), for previewing in a browser or importing into claude.ai/design. See
  `frontend/README.md`.
- `Tests/ClaudePetCoreTests/` — one file per subsystem (`AggregatorTests.swift`,
  `PricingTests.swift`, `WeeklyWindowTests.swift`, etc.), using Swift Testing (`@Test`/`#expect`).

## Building & testing

```bash
git clone https://github.com/jjnnaappaatt/ClaudePet.git
cd ClaudePet
swift test            # data-engine unit tests
./bundle.sh release   # build ClaudePet.app
open ClaudePet.app
```

A PR should leave `swift test` green — CI runs it on every push/PR (`.github/workflows/test.yml`,
macOS 15 / Swift 6). There's no external dependency to resolve (`Package.swift` has none), so
`swift test` works offline right after cloning.

**Write deterministic tests.** Anything that touches `Date()`/`Calendar.current` without pinning
a fixed reference instant can pass or fail depending on when the suite happens to run — this isn't
hypothetical: an existing test asserted "the last 10 hours land in the same weekly window," which
is false for roughly 10 hours out of every 7-day cycle, and it happened to fail during a routine
release check. Prefer injecting a fixed `now`/`calendar` (see `AggregatorTests`,
`WeeklyWindowTests`) or, where the code under test always calls `Date()` internally with no
injection seam (e.g. `MetricsStore.recompute()`), pin the *config* — reset weekday/hour, token
basis, etc. — so the real wall-clock moment can't change the outcome (see
`AutoPeakTests.pinWeeklyAnchorFarFrom`).

## Settings / persistence pattern

New user-facing settings on `MetricsStore` follow one consistent shape — search for
`weeklyResetWeekday` as a worked example: a `public var` with a default, a `Key` constant in the
`private enum Key` block, a load line in `loadConfig()`, and a save line in
`saveConfigAndRecompute()`. Optional (`Int?`/`Date?`) settings persist by presence-checking
`defaults.object(forKey:)` on load and calling `removeObject(forKey:)` on save when `nil` (see
`billingCycleDayOverride`) rather than persisting a sentinel value.

## Code style

- No comments explaining *what* code does — names should do that. Comments are for the *why*: a
  non-obvious constraint, a workaround, an invariant a future reader could break. Skim any
  existing file (`MetricsStore.swift` is representative) for the tone.
- `// MARK: -` sections to group related functionality within a file (existing files are full of
  examples).
- Prefer extending an existing pattern over inventing a new one — e.g. a new gauge/window follows
  `WeeklyWindowEngine`'s shape, a new display-basis toggle follows `TokenBasis`'s.

## Commit messages

Explain the *why* — the problem, the root cause if it's a fix, and what changed — over a
narration of *what* changed line-by-line. Recent commits on `main` are a good reference for tone
and depth.

## Release process (maintainer-only)

Version is kept in sync across three places — `Sources/ClaudePetCore/ClaudePetCore.swift`,
`Sources/ClaudePet/Supporting/Info.plist`, and the top dated heading in `CHANGELOG.md` — and
`release.sh` refuses to build if they disagree. Contributors don't need to bump these; just add
your change under `## [Unreleased]` in `CHANGELOG.md`.

## Issues & PRs

- Open an issue for anything beyond a small fix before writing code, so we can agree on the
  approach first.
- Keep PRs scoped to one change. Include the `swift test` output (or note the CI run) in the
  description.
- Screenshots for anything UI-visible are appreciated — the existing snapshot harness
  (`CLAUDEPET_SNAPSHOT`, see `AppDelegate.swift`) can render the widget headlessly with sample
  data (`CLAUDEPET_REAL` unset) if you don't want to expose your own usage numbers.
