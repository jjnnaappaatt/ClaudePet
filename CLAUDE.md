# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
swift test                          # full data-engine suite (Swift Testing, no XCTest)
swift test --filter AutoPeakTests   # one suite; --filter also matches a single test name
./bundle.sh                         # debug build → ClaudePet.app (ad-hoc signed)
./bundle.sh release                 # release build → ClaudePet.app
open ClaudePet.app
./release.sh                        # version check + swift test + bundle + dist/ClaudePet-<v>.dmg
```

There are no external dependencies (`Package.swift` declares none), so `swift test` works offline
immediately after cloning. CI (`.github/workflows/test.yml`) runs `swift test` on macOS 15 / Swift 6.

`swift-tools-version: 6.0`, but every target sets `.swiftLanguageMode(.v5)` — don't assume Swift 6
strict-concurrency diagnostics are on.

### Headless UI verification (no screen-recording permission needed)

`AppDelegate` checks env vars at launch, renders a SwiftUI view to PNG via `ImageRenderer`, and
exits. Use this instead of screenshots to check UI changes:

```bash
CLAUDEPET_SNAPSHOT=/tmp/w.png ./ClaudePet.app/Contents/MacOS/ClaudePet   # widget, sample data
CLAUDEPET_SNAPSHOT=/tmp/w.png CLAUDEPET_REAL=1 ...                       # real ~/.claude data
CLAUDEPET_LAYOUT=vertical CLAUDEPET_SCALE=1.5 ...                        # override without touching saved prefs
CLAUDEPET_UTIL=96,40 ...            # fake statusline utilization → force gauge/weather/mood states
CLAUDEPET_HANDLES=1 ...             # force resize grips visible
```

Other paths: `CLAUDEPET_SETTINGS` (Settings view), `CLAUDEPET_MASCOT` (all mascot frames),
`CLAUDEPET_ICON` (1024px icon master), `CLAUDEPET_HEARTBEAT` (writes metrics JSON per recompute),
`CLAUDEPET_OPENSETTINGS` (diagnoses the real gear→Settings activation flow).

## Two hard constraints

From `CONTRIBUTING.md` — these are why the app is trustworthy, not style preferences:

1. **Local files only.** Reads `~/.claude/projects/**/*.jsonl`, `~/.claude.json`, and optionally
   `/tmp/claude/statusline-usage-cache.json`. Never reads the OAuth token, never makes a network
   request. A feature needing data that isn't already local is out of scope.
2. **Original art only.** The mascot is code-drawn in `MascotArt.swift` / `PixelMatrixRenderer.swift`
   as an homage to Clawd. Don't bundle third-party art.

## Architecture

Two SwiftPM targets: `ClaudePetCore` (pure Swift — no AppKit/SwiftUI, fully unit-testable) and
`ClaudePet` (the executable: SwiftUI + AppKit). Tests only cover Core.

### Data pipeline

`FileWatcher` (FSEvents, 0.25s debounce) → `UsageScanner` (actor; per-file `(mtime, size)` cache so
only changed files re-parse) → `JSONLParser` (streams 1 MB chunks per file — transcripts reach
100 MB+, so never `Data(contentsOf:)`) → `Deduplicator` → `Aggregator` + `FiveHourBlockEngine` +
`WeeklyWindowEngine` → `MetricsStore` → SwiftUI.

**Dedup is load-bearing:** ~51% of assistant lines repeat the same `message.id` with *identical*
usage — they are not streaming deltas. Keep the first per `messageID`, never sum, or tokens and cost
roughly double.

### MetricsStore

`@MainActor @Observable`, the single view model. `recompute()` re-aggregates `lastEntries` against a
fresh `now` with the current config — cheap, no disk hit. A 30s timer calls it so the 5h/day/week/
cycle windows roll to empty on the clock while the user is idle, not only when a token is logged.

### The gauge value chain (spread across several files — read this before touching a gauge)

`blockFraction` / `weeklyFraction` resolve in order:

1. **Server-driven** — `serverUsage` from the statusline cache, if fresh (`serverDataMaxAge` = 30 min)
   and its window hasn't already reset (`ServerLimit.isUsable`). This is Claude's real %, and drives
   the `live` badge plus the real reset date.
2. Otherwise `value / budget`, where `budget` comes from `blockBudget` / `weeklyBudget`:
   fresh manual calibration → your own peak completed window × `(1 + peakHeadroom)` → plan estimate
   → custom. `budgetSource` (`.auto`/`.plan`/`.custom`) is a UI facade over the `autoPeakBudget` /
   `autoBudgetFromPlan` flags. `budgetBasisDescription` must stay honest about which one is active.

Peaks come from **completed** windows only (the still-growing one is excluded) so the denominator
doesn't chase the numerator.

### Token bases — three distinct things, easy to conflate

- `workTokens` = input + output. `totalTokens` = work + cache reads + cache writes. Under always-on
  prompt caching, work is ~1% of total.
- `weightedTokens` = work tokens scaled by model cost relative to Sonnet (`PricingTable.weight`) —
  used by the **gauges** when `weightTokensByModel` is on, so Opus burns the limit faster.
- `TokenBasis` (`.work`/`.total`, default `.total`) is **display-only**. Every per-day/hour/model
  token figure must route through `MetricsStore.tokens(work:total:)` and friends. Cost is always
  cache-inclusive and never routed through it.

Also: `week` is the **fixed weekly-reset window** total (mirrors the Claude app, resets to zero at
each boundary), while `weekDaily` is the **rolling last-7-calendar-days** chart. Different bases on
purpose — don't unify them.

### Pricing

`PricingTable` is user-editable and persisted. `defaultOverrides` handles version-specific rates
(e.g. deprecated Opus 4.1 at $15/$75; Sonnet 5 introductory pricing through 2026-08-31). Restoring a
table saved before a model family existed goes through `mergingMissingDefaults()` so new families
get priced instead of silently counting as free. Costs are *notional* API-equivalent — the user is
likely on a subscription.

### Mascot & weather

`MascotEmotion` is the single source of truth: `MetricsStore.mascotEmotion` derives mood from the
larger of the two gauge fractions, and `WeatherCondition.from(emotion)` derives the sky from that
same value — so face and weather can never disagree. One-shot moments (`WeatherEvent.confetti`,
`.lightningStrike`) are edge-detected in `detectWeatherEdges()` at the end of each `recompute()`,
queued, and drained once by `ContentView`; nothing fires on the first pass after launch.

`MascotEngine` and `WeatherEngine` are deliberately plain `@MainActor` classes, **not** `@Observable`
— they're mutated inside `TimelineView` draw closures, and observation there would cause re-render
loops. Same reason the edge-detection state in `MetricsStore` is `@ObservationIgnored`.

### App layer

`FloatingPanel` (an `NSPanel` subclass) hosts SwiftUI. Its header documents load-bearing AppKit facts
verified against Apple docs (frameless comes from *omitting* `.titled`; `.nonactivatingPanel` must be
set at init; `level = .floating` is required for always-on-top) — don't "clean up" those settings.
`WindowController` sizes the panel to `content.fittingSize` and remembers position **per display
arrangement**, clamping back on-screen if a monitor is unplugged. Dockless agent app
(`LSUIElement`, `.accessory` policy).

Widget scaling multiplies font sizes via the `widgetScale` environment key rather than
`.scaleEffect`, so text stays crisp.

## Conventions

**Adding a setting on `MetricsStore`** — follow `weeklyResetWeekday` exactly: a `public var` with a
default, a `Key` constant, a load line in `loadConfig()`, a save line in `saveConfigAndRecompute()`.
Optional settings presence-check `defaults.object(forKey:)` on load and `removeObject(forKey:)` on
save when nil (see `billingCycleDayOverride`) — never persist a sentinel.

**Tests must be deterministic.** Anything touching `Date()`/`Calendar.current` without a pinned
reference can pass or fail depending on when the suite runs — this has already caused a real flaky
failure. Inject a fixed `now`/`calendar` (see `AggregatorTests`, `WeeklyWindowTests`), or where the
code always calls `Date()` internally, pin the *config* instead (see
`AutoPeakTests.pinWeeklyAnchorFarFrom`). Tests build entries via `TestSupport.entry(...)` and use
fresh throwaway `UserDefaults` suites.

**Comments explain *why*, never *what*** — a non-obvious constraint, a workaround, an invariant a
future reader could break. `MetricsStore.swift` is representative. Group with `// MARK: -`.

**Prefer extending an existing pattern** over inventing a new one — a new window engine follows
`WeeklyWindowEngine`'s shape, a new display toggle follows `TokenBasis`'s.

## Version bumps

The version lives in three hand-maintained places and `release.sh` refuses to build if they disagree:
`Sources/ClaudePetCore/ClaudePetCore.swift`, `Sources/ClaudePet/Supporting/Info.plist`
(`CFBundleShortVersionString`), and the top dated heading in `CHANGELOG.md`. Ordinary changes just
go under `## [Unreleased]`.

## frontend/

A self-contained HTML mirror of the widget for claude.ai/design (`/design-sync` skill). Each file's
first line is a `<!-- @dsCard group="..." -->` marker; each inlines the same `:root` tokens so it
renders with zero external requests. It's generated output — the mascot SVGs come from the same
pixel logic as `MascotArt.swift`, so changing the mascot means regenerating rather than hand-editing.
