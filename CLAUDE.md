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
CLAUDEPET_BASIS=total ...           # render work-vs-total side by side, saved pref untouched
CLAUDEPET_UTIL=96,40 ...            # fake statusline utilization → force gauge/weather/mood states
CLAUDEPET_HANDLES=1 ...             # force resize grips visible
CLAUDEPET_NOLIVE=1 ...              # ignore the statusline + drop the calibration anchor, so the
                                    # local-history budget estimate is what you're looking at
```

```bash
CLAUDEPET_DASHBOARD=/tmp/d.png ...                  # the dashboard window's view
CLAUDEPET_DASHBOARD=/tmp/d.png CLAUDEPET_DASHSIZE=900x800 CLAUDEPET_REAL=1 ...   # at its minimum
```

`DashboardView` is layout-driven, so unlike the widget it has no intrinsic size — the snapshot path
wraps it in an explicit `.frame`, and `CLAUDEPET_DASHSIZE` sets that. Always re-check the **minimum**
size with `CLAUDEPET_REAL=1`: the sample data's short project list hides overflow that real data
(8 rows plus a "+N more" line) exposes. Guessing the minimum was wrong twice — 620 cut the billing
footer off entirely, 740 fit the sample and still clipped on real data.

`CLAUDEPET_OPENDASHBOARD` is the dashboard's equivalent of `CLAUDEPET_OPENSETTINGS`: it drives the
real expand-button flow and reports the things that fail *silently* rather than erroring — whether
the window can go full screen, whether ⌃⌘F is actually wired, whether `contentMinSize` stuck, and
whether the widget gets out of the way and comes back.

Other paths: `CLAUDEPET_SETTINGS` (Settings view), `CLAUDEPET_MASCOT` (all mascot frames),
`CLAUDEPET_ICON` (1024px icon master), `CLAUDEPET_HEARTBEAT` (writes metrics JSON per recompute —
today's tokens plus both Auto budgets and `budgetBasisDescription`, the only way to check those
against real data since Settings isn't on screen; note `CLAUDEPET_NOLIVE` pairs with it, and unlike
the snapshot vars it runs in the normal app flow rather than rendering and exiting),
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
   unexpired fitted budget → `PeakEstimator` anchor over your completed windows ×
   `(1 + peakHeadroom)` → plan estimate → custom. `budgetSource` (`.auto`/`.plan`/`.custom`) is a
   UI facade over the `autoPeakBudget` / `autoBudgetFromPlan` flags.
   `budgetBasisDescription(for:)` must stay honest about which one is active, **per gauge** — there
   are two very different denominators behind "Auto" and the two gauges are often on different ones.

**A fitted budget expires by age (`calibrationExpiry`, 14 days), never by window reset.** A reset
expires the *percentage*; the limit belongs to the plan. Tying the budget to the window discarded a
good fit 4–5× a day and showed the local anchor instead — 6.2M against a real ~1.9M.
`blockCalibrationIsStale` / `weeklyCalibrationIsStale` survive only as the "same window?" test that
`shouldAcceptFit` needs; don't wire them back into the budget.

**Newer is not better.** `budget = used ÷ %` has error ∝ 1/%, so a window that just reset (10–12%)
gives a far worse fit than one near its limit — the same cap read anywhere from 1.87M to 3.16M
depending only on when it was sampled. `shouldAcceptFit` stores each fit's percentage and defends
it, decaying that claim linearly to nothing over `calibrationExpiry`. Readings ≥
`autoCalibrationMaxPercent` (98) are refused — throttled turns still get logged, so `used ÷ 1.0`
overshoots.

The anchor comes from **completed** windows only (the still-growing one is excluded) so the
denominator doesn't chase the numerator. It is **not** `max`: the 5h grid accumulates completed
windows ~15× faster than the weekly grid (137 vs 9 on real data), and max-of-n climbs with n, so a
plain max left the two gauges calibrated ~2× apart and drifting. `PeakEstimator` takes a fixed
quantile instead, degrading to `max` below 21 windows.

Even so, **the anchor is an upper bound on your habits, not an estimate of Anthropic's cap** — it
measured ~3× the real 5h limit. Our 5h windows are reconstructed; Claude re-anchors its own per
session (its resets were 13:00 one day and 12:59 the next, which can't share a 5h lattice), so a
reconstructed span straddling one of its resets holds more than one limit's worth. Not recoverable
locally: a fixed lattice and a chained model gave 5.72M and 6.67M against the same ~1.9M truth.
Don't try to retune it — prefer a fitted budget and treat this as the last resort.

That anchor still only describes **your own habits**, never Anthropic's cap — measured against the
live numbers it ran 5.9× high on the 5h gauge. So `applyServerCalibration` (in `recompute`)
back-solves `budget = used ÷ server%` whenever the statusline cache offers a usable window, writing
the same fields the Calibrate sheet does so step 1 of the list above picks them up unchanged. It
also phase-aligns our own windows to `resetsAt`, which is what keeps step 2's numerator honest.

**The two gauges are independent everywhere in this path.** They reset on different clocks, so they
carry separate stamps (`lastCalibratedAt` / `weeklyCalibratedAt`), separate staleness
(`blockCalibrationIsStale` / `weeklyCalibrationIsStale`), separate noise-floor checks, and separate
`budgetBasisDescription(for:)` strings. Coupling them meant every 5h rollover — several a day —
expired a perfectly good weekly fit (22M → 57M). Don't re-merge them, and don't let one side's
stamp stand in for the other's: a session-only fit must not make the weekly budget read as synced.

Four traps this code already handles — don't undo them:

- **Count the tokens over Claude's window, not ours.** `activeBlock` is gap-anchored to the user's
  first message and drifts off Anthropic's 5h grid; a block spanning a server reset divided by the
  fresh % gave a 21.1M session budget instead of 2.3M. Use `resetsAt` minus the window length.
- **Fold the 5h alignment correction backwards.** `activeSession` clamps `steps` at 0, so an anchor
  pushed past `now` pins the window's start into the future instead of re-phasing the grid.
- **Round the weekly reset to the minute and gate it on elapsed drift**, not on whether the
  (weekday, hour, minute) triple differs. The server's instant wobbles across the minute boundary
  (`07:59:59.74Z`, then `08:00:00.46Z`), which flipped the stored anchor 15:00 ⇄ 14:59 forever.
- **Never call `calibrateLimits` from inside `recompute()`** — it ends in `saveConfigAndRecompute()`,
  which recomputes. And clear `autoBudgetFromPlan`, or `init` re-mirrors the plan estimate over the
  stored budgets on next launch.

`MetricsStore.statuslineCachePath` defaults to the **real** `/tmp/claude` file, so any test that
asserts a budget must go through `TestSupport.store(defaults:)` — otherwise it passes or fails by
time of day, on the developer's own live usage.

### Token bases — three distinct things, easy to conflate

- `workTokens` = input + output. `totalTokens` = work + cache reads + cache writes. Under always-on
  prompt caching, work is ~1% of total.
- `weightedTokens` = work tokens scaled by model cost relative to Sonnet (`PricingTable.weight`) —
  used by the **gauges** when `weightTokensByModel` is on, so Opus burns the limit faster.
- `TokenBasis` (`.work`/`.total`, default `.total`) is **display-only**. Every per-day/hour/model
  token figure must route through `MetricsStore.tokens(work:total:)` and friends. Cost is always
  cache-inclusive and never routed through it.

Also: `week` is the **fixed weekly-reset window** total (mirrors the Claude app, resets to zero at
each boundary), and `weekDaily` is the **seven weekday slots of that window** — so the chart bars sum to `week`
while staying real weekdays. A mid-day reset makes the window touch 8 calendar dates, so the
trailing reset-day hours fold back (`% 7`) onto the slot the window opened with, rather than
growing an 8th bar. `Aggregator.compute` falls back to a rolling last-7-days only when no
`weekWindow` is passed.

Two traps, both hit in practice:

- Anything asking "which bar is today?" must use `MetricsStore.isCurrentDayBucket`, which matches on
  **weekday**, not date — reset day's slot is dated to the window's opening date even once `now` is
  the closing date a week later. Never use the last array index either: mid-week the last slot is
  still in the future.
- Do **not** re-anchor the buckets to the reset *instant*. That sums correctly too, but the bucket
  holding `now` then begins the previous afternoon, so the chart labels and highlights the wrong
  weekday (Saturday on a Sunday, flipping at 15:00). Weekday letters have to mean weekdays.

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

### Per-project attribution

`UsageEntry` carries two different things and they are **not** interchangeable:

- `project` — the turn's own `cwd`. Present on **every** assistant line (audited: 12,244 with, 0
  without), and the only exact source of a project's real *name*.
- `projectDir` — the `~/.claude/projects/<dir>` folder the transcript lives in, supplied by
  `UsageScanner` (the parser can't know it from a line). This is the **grouping key**.

Group by `projectDir`, never by `cwd`: `cwd` is per-turn, so on real data it took **120 distinct
values across 11 projects** — every `.claude/worktrees/wf_…` from a workflow agent (~90 of them) and
every incidental subdirectory (`node_modules/lucide-react/dist/esm/icons`) counts as its own. A list
grouped by `cwd` reads "+92 more".

Then name each group by **re-encoding**, in `ProjectKey.resolveRoot`. The folder name is
`[^A-Za-z0-9] → -` applied to the session's original cwd, which is lossy and not invertible — but a
candidate can be *checked* by re-encoding it and comparing. That resolved 11 of 11 real projects
exactly, and the obvious alternatives don't: picking the most frequent `cwd` labels `-Users-napat` as
"ClaudePet" and `-Users-napat-Desktop-AAI` as "aai_next_dashboard", because in those projects most
turns ran in a subdirectory. `projectDir` is the component **under** the root, not the file's parent —
subagent transcripts sit at `<project>/<session>/subagents/`, so the parent would scatter one project
across a folder per session.

Two directories can resolve to the same path (one session opened in the root, another in a
subdirectory); they're one project, so `Aggregator` merges them after resolving.

### Cycle breakdowns

`cycleDaily` and `cycleByProject` use the **identical** in-cycle predicate as the `cycle` total, so
each sums to it exactly — the dashboard shows all three together and a chart that didn't add up to
the headline above it would read as a bug. That predicate is half-open at *both* ends; it used to be
unbounded above, which let a clock-skewed turn inflate `cycle` while belonging to no bucket.

`cycleDaily` has one bucket per calendar date the cycle touches, and deliberately does **not** copy
`weekDaily`'s `% 7` fold — that trick exists because a week must be exactly 7 *weekday* slots,
whereas these bars are labelled by date, so a short partial first/last bar is honest. The loop is
`while d < cw.end`: with `billingCycleDayOverride` set the bounds land exactly on midnight, and `<=`
adds a spurious empty trailing bar (a mid-day cycle boundary hides this — test both).

`Aggregator`'s row order is a deterministic default keyed on `totalTokens`. A view showing `work` or
`$` must **re-sort by the figure it prints**, or the list looks unsorted — under `work` the default
order put 4M above 8.2M on screen.

### App layer

`FloatingPanel` (an `NSPanel` subclass) hosts SwiftUI. Its header documents load-bearing AppKit facts
verified against Apple docs (frameless comes from *omitting* `.titled`; `.nonactivatingPanel` must be
set at init; `level = .floating` is required for always-on-top) — don't "clean up" those settings.
`WindowController` sizes the panel to `content.fittingSize` and remembers position **per display
arrangement**, clamping back on-screen if a monitor is unplugged. Dockless agent app
(`LSUIElement`, `.accessory` policy).

Widget scaling multiplies font sizes via the `widgetScale` environment key rather than
`.scaleEffect`, so text stays crisp.

`DashboardWindowController` hosts `DashboardView` in a second, real window. Facts verified by spike,
each of which fails *silently* if undone:

- Flipping `.accessory` → `.regular` **does** give the app a main menu, but SwiftUI's **View menu is
  completely empty** (it only populates one for a scene it owns, and this app's only scene is
  `Settings`). So the green button works while ⌃⌘F is dead — which traps the user once the title bar
  is hidden. `AppPolicy.installFullScreenMenuItem` adds the item; `target` stays nil so it routes
  through the responder chain like AppKit's own.
- `.resizable` in the style mask is what creates the green button at all; `toggleFullScreen` is a
  no-op without it. `.fullScreenPrimary` gets the separate Space.
- Use `contentView` + a style mask set **at init**, not `NSWindow(contentViewController:)`. Also set
  the minimum in **SwiftUI** (`.frame(minWidth:minHeight:)`), not only `contentMinSize`: `NSHostingView`
  drives the window's limits from its root view, and `DashboardView`'s root is a `GeometryReader` with
  no intrinsic size, so a window-level `contentMinSize` alone read back as **0×0** and the window
  could be dragged smaller than the layout fits at.
- Both real windows revert the policy through `AppPolicy.revertToAccessory(unless:)`. Reverting
  unconditionally meant closing one window yanked the Dock icon and menu bar from the other.
- The dashboard owns its **own** `PanelVisibility` (the mascot's animation gate is optional in the
  environment). Sharing the widget's would freeze the dashboard's pet whenever the widget got covered.
- It must **not** drain `metrics.pendingWeatherEvents` — `ContentView` is the single drain point, and a
  second consumer would swallow celebrations meant for the other window. The ambient sky still works;
  `WeatherView` reads `weatherCondition` directly.
- No `Form`/`.formStyle(.grouped)` and no `ScrollView` in the dashboard: `Form` is why
  `CLAUDEPET_SETTINGS` renders blank through `ImageRenderer`, and the dashboard has to stay
  snapshot-verifiable. That's why its minimum size is measured rather than papered over by scrolling.

`DashboardView.scale(for:)` takes the **min of both axes**, never width alone. Every fixed height in
the layout (the mascot's sky, bar heights) multiplies by scale, so a width-only scale made a wider
window need *more* height — and full screen on a 16:10 display is wide and **short** (1470×923 here),
so it clipped the billing footer while having horizontal room to spare. Check any layout change at
that ratio, not just at the minimum size.

Exactly one row stretches — the cycle chart, whose bars fill the height they're given. The others stay
snug around their content. Stretching every row instead just moved the slack inside the cards (~180pt
of dead air beside the mascot), which reads as unfinished; growing the one panel worth looking at
large is what actually uses a big display. Related: the top row is split ~38/62, not evenly, because
the mascot card holds a pet plus a short stats column while the limits card holds three full-width
gauges.

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
