# Changelog

All notable changes to ClaudePet are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com); versions are dated on release.

## [Unreleased]

### Added
- **Device readout in the Today header** — the Mac's SoC temperature (hottest die sensor), macOS's
  thermal state, and ClaudePet's own CPU use, in the space under the cost that used to sit empty.
  Tinted only when the Mac is under thermal pressure. The temperature comes from IOKit's private
  `IOHIDEventSystemClient` API, loaded with `dlsym` so a macOS that drops it falls back to the
  public thermal state instead of failing. On-device only; nothing leaves the machine.
  `CLAUDEPET_DEVICE="<°C>,<state>,<cpu>"` fakes it for snapshots.

### Changed
- **Idle CPU: from 45–107% of a core to near zero.** Measured on the installed v0.14.0 after 3.7 days
  up: 101–107% of a core, sustained, almost all of it in `MetricsStore.refresh()`. Every transcript
  write started its own scan — overlapping — and each one walked and stat'd all ~2,000 transcripts,
  re-sorted and re-deduplicated all ~130k entries, then re-aggregated the whole history on the main
  thread, pricing every entry by re-parsing a date string through `Calendar`. Now:
  - scans run one at a time, at most one every 2 s, with a burst of events coalesced into one;
  - only the files FSEvents names are stat'd (a full walk every 5 minutes is the safety net);
  - a purely additive change is merged as a delta, not by re-sorting the history;
  - pricing resolves each model's rate once per pass instead of once per entry;
  - the 30 s timer skips the full re-aggregate unless an hour, session, week, cycle or server
    window boundary has passed, new data arrived, or a side file changed.
- **The dashboard's lifetime figures show their precision** — project rows as `123.14M` and
  `$20,915`, the /stats headline as `272.32M`. At `123.1M` / `$21.2k` a correctly updating row moved
  once per 100k tokens or $100 and read as frozen.
- **The /stats per-model rows are extended across the same days as the headline**, so they keep
  summing to it instead of stopping at Claude Code's cache date while the total moved. The four
  tiles that can't be extended honestly (sessions, messages, busiest hour, longest session) now say
  `· to 17 Sep` when the cache lags.

- **Device readout on three lines, larger.** Temperature, thermal state and CPU each get their own
  line under the cost, in the widget and the dashboard alike. The dashboard used to squeeze work and
  cache onto one line to save height; it now stacks them like the widget, which fits within the
  mascot's sky block and moves nothing below the header.

### Fixed
- **The widget can be dragged again on macOS 27.** `isMovableByWindowBackground` stopped moving a
  borderless panel whose content is a SwiftUI hosting view (a plain `NSView` still drags), so the
  widget couldn't be moved at all. The card now carries a `WindowDragGesture` on macOS 15+; the
  resize grips and the footer buttons still take their own clicks.
- **Notional cost was overstated by stale rates.** Opus 5.5 is $4/$20 with cache reads at 0.05×
  (was priced $5/$25 at 0.10×); Fable 5.1 and Mythos 5.1 cache reads are 0.025× (were 0.10× — 4× too
  high, on the token class that is ~97% of volume); Sonnet 5 and 5.5 stay at $2/$10 (were reverting
  to $3/$15 after 2026-08-31). Measured on the developer's corpus: today's estimate $1,885 → $1,088
  with no change in tokens.
- **Saved pricing tables now pick up new rate overrides.** They were restored only when a saved
  table had none at all, so a table saved with one override never received another. A saved
  override equal to a retired shipped default is replaced; anything the user edited is kept.
- **Dated price overrides never applied on a non-Gregorian calendar.** `throughDate` was read with
  `Calendar.current`; under the Thai Buddhist calendar 2026 is Gregorian 1483, so every dated
  override had already lapsed. The test helper used the same calendar, which is how it passed.
- **The widget panel now follows its content, and no longer launches clipped.** The panel was sized
  to its SwiftUI content exactly once at launch — before the first scan — and then only on a
  settings change or a resize drag. Measured on a fresh launch: fitted to 427pt of near-empty
  content, grown by the scan to 611pt eight seconds later, and left at 427, clipping the header and
  the footer with its buttons until something happened to refit it. Every launch had this; a
  settings change or a drag usually masked it. `FittingHostingView` now refits whenever the
  content's size is invalidated, whatever caused it. `CLAUDEPET_PANELFIT=1` checks it — the snapshot
  path can't, because `ImageRenderer` draws the content at its own size and never asks the panel.
- **The landscape widget's "This week" chart no longer swallows the card's spare height.** In a
  two-column `HStack` the taller column sets the height and SwiftUI proposes that height back to the
  shorter one, where a `VStack` hands its surplus to whichever children are flexible. The left
  column's only flexible child was this chart — each bar is `VStack { Spacer; bar; label }` and a
  `Spacer` is vertically unbounded — while its `barArea` stayed pinned at `40 * scale`. So the bars
  did not grow into the slack, they were pushed **down** it: 283px of void at scale 1.5, about a
  third of the card, between the chart's header and its own bars. The hour chart below was spared
  only because its bars carry no `Spacer`.
- **The two left-column charts now absorb that slack as bar height instead**, split evenly and
  capped at twice the base bar. Measured at scale 1.5 across four data shapes, the largest interior
  gap in either column goes 283 → 67px (two Codex rows), 95 → 67, 82 → 67 and 140 → 89, with the
  card's own height unchanged in every case but one, where it is 17px shorter. Scale-invariant:
  identical results at 1.0, 1.5 and 2.0. The tall layout and the dashboard are untouched.

## [0.14.0] — 2026-08-12

### Added
- **A Codex quota bar, under the two Claude gauges, in the widget and the dashboard.** Read from
  `/tmp/claude/codex-usage-cache.tsv`, the same class of local-file read as the Claude limits — no
  token, no network, and nothing new asked of the machine. Cyan rather than the Claude ramp,
  because it is a different quota and a Codex bar in Claude gold reads as a fourth Claude limit;
  the track floor is the warm one **mirrored**, `(49,40,36)` → `(36,40,49)`, which keeps the
  measured relationships (track 1.74–1.89:1 on the card, fill ≥4.68:1 above the track) instead of
  the grey-brown a warm floor produces under a cyan fill.
- **The row hides itself when there is no Codex reading.** A 0% bar for a tool that isn't installed
  is a claim, not a default — and the dashboard's divider is hidden with it, so no orphaned rule
  is left behind.
- **Three age bands, because the number only moves when Codex runs.** Under an hour it reads like
  the rows above it; past an hour the text drops a tier; past a day it shows how old it is instead
  of when the window resets. That last one is not cosmetic: a 65-hour-old reading was promising a
  reset that had already happened, behind a percentage that had since gone 47% → 0%. The reset is
  also dropped whenever it lies in the past, whatever the reading's age.
- **Tokens spent in the window, on the same line as the reset**, matching the Weekly row above
  (`2M work used this week`). Codex reports a percentage and never a count, so the statusline sums
  it from Codex's own session rollouts and passes it through as a fifth field in the cache — the app
  keeps reading one small file rather than scanning 22 MB of rollouts every 30 seconds. The count
  is optional: a four-field cache from an older statusline still renders the row without it, and a
  0 means "could not tell" and shows nothing rather than claiming a week of zero usage.
- **That count excludes cache reads, which took subtracting them explicitly.** Codex reports tokens
  the opposite way round from Anthropic — its `input_tokens` is gross, with `cached_input_tokens` a
  *subset* of it — so the rollouts' `total_tokens` is `input + output` with cache **included**.
  Measured over a real week that is **93.6% cache reads: 28.2M against a work-equivalent 2.0M**.
  Left alone, a row sitting directly beneath the Claude weekly gauge (which prints work, cache
  excluded) would have read 7× the Claude figure while actually being under half of it. The
  statusline differences `input_tokens - cached_input_tokens + output_tokens` instead, and the row
  spells "work" out literally rather than taking the basis label — this figure is always
  cache-excluded, while the Claude rows follow the setting, so under `.total` the row above names a
  different unit instead of inviting a comparison it can't support.
- `CLAUDEPET_CODEX=<pct>[,<age>[,<tokens>]]` (or `none`) for the snapshot paths, so all four states
  are checkable headlessly.
- **An age chip on the `/stats` "Total tokens" headline.** `+4d` when ClaudePet has extended the
  figure past Claude Code's cache — which also explains why the headline no longer equals the
  per-model rows beneath it, since those are the cache alone — or `to 4 Aug` in coral when it
  couldn't, meaning the number genuinely stops there. Measured off the render at 6.3:1 and 9.6:1
  against the card. Nothing showed before, which is the entire reason a week-old figure went
  unnoticed.
- `CLAUDEPET_STATSAGE=<days>` re-dates a **copy** of the `/stats` cache (never the real file) so
  both of those states can be rendered. Neither happens on demand: the dated one needs Claude Code
  to be further behind than the local history reaches.

### Changed
- **Idle CPU: 45–100% of a core → ~6.5%.** The widget floats on screen all day, and every prior
  optimisation round here was about memory, so nobody had ever profiled it. The cause was not the
  animation — the main thread was blocked in `mach_msg2_trap` for 3110 of 3178 samples — it was the
  scanner: the per-file cache is keyed `(mtime, size)`, so **one appended line re-parsed the whole
  file**. Transcripts are append-only and huge; measured live, one line cost a **180 MB** re-parse on
  one session and **682 MB** on another, against ~220 KB of genuinely new data over twelve minutes.
- **Parsing resumes from a byte offset instead of restarting.** Guarded by an FNV-1a fingerprint of
  the 4 KB ending at that offset, so a truncated, rotated or rewritten file falls back to a full
  re-parse — being wrong there costs the old behaviour and never correctness. An unterminated final
  line is parsed but not counted as consumed, so a line split across two scans isn't counted twice.
- **Timestamps are decoded arithmetically.** `ISO8601DateFormatter` runs through ICU and measured
  **19% of the scan**, and it tried the fractional formatter *first* with a fallback, so any
  timestamp without a fraction paid two ICU parses. 6,014 timestamps across 120 random files were
  **100.0%** one fixed layout; anything else still goes to the formatters, checked bit-for-bit.
- **Line splitting and the `"usage"` probe are byte scans** (`memchr`/`memcmp`) rather than
  `Data.split` (28% of the scan) and `Data.range(of:)`, which bridged to `NSData` Boyer-Moore per
  line (7%). The probe's semantics are unchanged.
- **`String.contains` is gone from the two hottest string paths.** On a `String` argument it resolves
  to locale-aware NSString searching; it sat in `ModelFamily.init` (per parsed line) and
  `PricingTable.effectivePrice` (per entry, from three full-history loops per recompute — order 384k
  calls every 30s), each after a `lowercased()` allocation.
- **`DashboardView.refHeight` takes a conditional `+70` while the Codex row is on screen.** The
  left card had already spent its slack: uncompensated, the bottom-most card pixel at 1990×820 went
  from 12px clear of the edge to 0, and 1470×923 did the same. It is a conditional term rather than
  a bigger `refHeight` so that anyone without Codex keeps the type size they have today. 28 and 45
  were both still clipping; 60 cleared every size but left real data 4px tighter than sample at
  1470×923, and 70 closes that.
- **The `/stats` headline now fills every day Claude Code's cache is missing, not just today.** The
  old rule added today alone, and only when the cache stopped exactly at yesterday; anything staler
  showed the cache's own figure unchanged. Claude Code recomputes that file when it feels like it,
  not daily — measured here it sat at 4 August through seven days of continuous use, so the panel
  read **151.4M against Claude Code's own 160.9M**. Six days were missing, not one. The added days
  are ClaudePet's accounting, which ran within ~±7% of `/stats`' on a full measured day: over a
  six-day gap that is ±0.4M on a 157M headline (±0.26%), against 3.7% low for not filling it.
- **The fill is refused, and the figure marked dated, when local history doesn't reach the cache.**
  Claude Code deletes transcripts past `cleanupPeriodDays`, so a cache left un-recomputed long
  enough outlives the days it would be extended with; adding only what survives would give a total
  that is neither the cache's nor ours.
- **`StatsCache.endsYesterday` is gone.** It encoded the one-day-gap-only rule and now has no
  caller, and a predicate like that left lying around is an invitation to wire the rule back in.

Measured back-to-back on the same 2.29 GB corpus: cold scan **12.4–13.0s → 2.25–3.78s** wall clock
and **11.7–12.3s → 1.79–1.80s** of CPU; `JSONLParser` went from ~2941 profile samples to **0**. Max
RSS is unchanged at ~785 MB — this was never a memory problem. Equivalence checked on real data:
27,561 lines and 14,666 timestamps A/B'd against the old code with **0 mismatches**, and old and new
binaries render pixel-identical dashboards apart from the burn rate, whose denominator is wall clock.

### Removed
- `AccountInfo.weeklyAnchorBase()` and `WeatherEngine.debugCloudCount` — no callers anywhere,
  including tests. A sweep of all 343 public `ClaudePetCore` symbols found only those two.

### Fixed
- **`Format.relativeAge` understated the day bucket.** It truncated, so 65 hours printed "2d ago".
  Days are 24 hours wide, so truncation there loses most of a day — and a staleness label that
  undersells its own staleness is the one thing it must not do. Rounds now; minutes and hours still
  truncate, where the error is inside the noise. Affects the two calibration-age tooltips as well.
- **README said "By project — which projects burned the cycle's tokens".** That card moved to
  lifetime in 0.11.0 and its own header reads "all time"; the README had been wrong for three
  releases. Also documents the lifetime KPI tiles, the Subagents today / Subagents/day pair, the
  widget's own layout button, the 30-day pace baseline, and the fact that **This week** and
  **Subagents/day** run on a fixed Sunday-to-Saturday calendar week rather than the weekly-limit
  window. Screenshots regenerated — the old ones predate all of it.
- **The preview fixture shipped real project names.** `loadSampleForPreview` hard-coded four of the
  developer's own directories, which are rendered into every screenshot and into `claude.ai/design`
  imports. Generic now.
- **The preview's "By project" card read "no usage recorded yet".** The fixture set
  `cycleByProject` but never `allTimeByProject`, which is what `ProjectBreakdownView` actually
  reads — so every non-`CLAUDEPET_REAL` render showed an empty panel, the one state a layout check
  can learn nothing from.
- **The preview's "Subagents today" bar read 0.** The fixture's one no-delegation day was pinned to
  a fixed index, so it landed on "today" whenever the sample was rendered on that weekday. It is now
  placed relative to the current day, keeping the "0%" vs "–" distinction visible without making
  zero the resting state.

## [0.13.0] — 2026-08-03

### Changed
- **`UsageEntry` is 96 bytes instead of 128, and no longer allocates a string per entry.** Two copies
  of every entry stay resident for the life of the process — the scanner's per-file cache and the
  merged list — so at ~128k entries each byte costs ~250 KB twice over.
  - **14 of those 128 bytes were alignment padding.** `family` and `isSidechain` are one byte each and
    each sat between 8-aligned fields, dragging a 7-byte hole behind it. Grouping them at the end,
    and narrowing the five token counts to `Int32` (a single turn's counts are thousands to low
    millions; `Int32` reaches 2.1 billion), gives **96 bytes — 25% off**. The counts are still read as
    `Int` and their sums still computed in `Int`, so no caller changed, and a corrupt oversized value
    saturates rather than wrapping negative and quietly subtracting from a total.
  - **`messageID` is a 128-bit `MessageKey` rather than a `String`.** It is unique per entry, so
    unlike `model` and `cwd` interning can't help it — and measured, each was a 28-character string
    landing in the 64-byte malloc class: **129,692 heap nodes, 8.3 MB**, allocated only to be compared
    for equality and never read. Nothing needs the text back; the only readers are the two dedup sets.
    128 bits, not 64, because dedup keeps the *first* entry per key — a collision would silently drop
    a real turn. Verified against all **129,806 message ids** in a real corpus: **0 collisions**.
  - Measured, settled, at matched uptime: live set **73.3 MB → 40.6 MB**, entry arrays 39.6 → 28.3 MB,
    `StringStorage` 8.3 MB → 21.7 KB, total malloc nodes **215,283 → 86,206**, peak 679.6 → 629.7 MB.
  - Neither change moves any figure, so the suite passes either way. `AllocationTests` pins the
    stride and the key's distinctness for the same reason it pins the copy elimination.

## [0.12.0] — 2026-08-03

### Added
- **The "N/day avg" pace baselines now average your last 30 active days**, not the current
  rate-limit week. A weekly reset empties that week's buckets, so for the rest of reset day both pace
  bars had no prior days to average and fell back to "building daily average…" beside a perfectly
  correct figure — every week, by construction. The new lifetime series (`allTimeDaily`) has no such
  cliff. Rolling rather than all-time so the baseline tracks how you work now: on real data all-time
  read 3.11M against the window's 3.53M, and that gap only grows. Days with no usage don't count as
  light days — they don't count at all — and the subagent baseline picks its own active days, so a
  day you worked alone doesn't drag it down. The captions are unchanged; the span is in the tooltips.

### Changed
- **Two full copies of the entry list are no longer made every cycle**, by code whose comments already
  claimed they weren't. On this corpus each is ~15.7 MB, and `vmmap` showed the residue as empty
  `MALLOC_LARGE` regions of exactly that size.
  - `UsageScanner.merge` now takes its parameter **`consuming`**. It always intended to sort in place,
    but a plain parameter is *borrowed*: the caller's array stays live for the call, so
    `var sorted = entries` left the buffer non-uniquely referenced and `sort()` quietly took a
    copy-on-write copy. One allocation claimed, two made — on **every scan**, and FSEvents rescans on
    every transcript write.
  - `FiveHourBlockEngine` no longer re-sorts an already-sorted list. `merge` sorts before returning,
    so its two `entries.sorted { }` calls were sorting sorted data — except `.sorted` allocates
    unconditionally, twice per `recompute()`, on a 30-second idle timer.
  - Observed peak **744.5 MB → 679.6 MB**, and empty `MALLOC_LARGE` regions of ≥10 MB down from 2 to 1
    at matched uptime. Both figures sit inside the documented 526–790 MB band, so the allocation
    counts — which are pinned by tests — are the solid result, not the footprint delta.
  - These produce byte-identical output, so every functional test passes either way. `AllocationTests`
    exists for exactly that reason: it compares buffer base addresses, and is the only thing in the
    suite that fails if either copy comes back.
- **Aggregation got ~15% faster despite gaining a series.** The new lifetime buckets need a day key
  for every entry, and `recompute()` runs on the main actor on a 30s timer, so that could not be
  paid naively. Caching one `startOfDay` per *day* — and reusing that key for the per-entry
  `isDate(_:inSameDayAs:)` the "today" branch already called — more than covers it. Measured over 21
  runs on 127k real entries (p50): **275.5 ms before the feature, 345.3 ms if added naively,
  233.9 ms as shipped.**

- **A layout button on the widget itself**, beside the existing expand and gear icons — switches
  between the wide two-column card and the tall single-column one without opening Settings. Same call
  Settings' own "Widget layout" picker makes (`saveConfigAndRecompute`), so the panel resizes to fit
  exactly as it already did from there; this just gives it a second, faster door. The icon shows the
  layout you're *in* — `rectangle.split.2x1` (side-by-side panes) for wide, `rectangle.split.1x2`
  (stacked panes) for tall — with the destination spelled out in the tooltip so the icon doesn't have
  to carry that on its own. Hidden in the dashboard, where "wide vs tall" has no visible effect.

### Fixed
- **A verification recipe in `CLAUDE.md` that quietly overcounted.** Claude Code symlinks a
  workflow's agent directory into every session that resumed it, so one physical transcript is
  reachable by several paths. A `**/*.jsonl` walk follows those symlinks; `FileManager`, which the
  app uses, does not — so hand-checks read higher than the app and the app looked like it was
  undercounting. Here it was 11 duplicate paths inflating one day by 113,808 tokens: small, stable,
  and written off as "live drift" more than once. The recipe now says to dedupe by inode, and with
  that the same scan matches the app to the token.
- **The Week/Cycle line no longer truncates real numbers.** `Week 15.5M · Cycle 94.3M` was rendering
  as `W... 15.... · Cy... 94....` in the widget's landscape layout — pre-existing in 0.11.0, not
  something the new button caused, though a third icon in the same tight row made it slightly worse.
  `.minimumScaleFactor` was hitting its floor and then truncating the token figures themselves, which
  are the one thing on that line that must stay exact. Fixed the way the rest of the app already
  handles a row that doesn't fit: `ViewThatFits` drops the least essential piece — the reset countdown
  — instead of shrinking everything, and the token figures are `.fixedSize()` so they're never what
  gives first. The dropped countdown is still in Cycle's own tooltip.

## [0.11.0] — 2026-08-01

### Added
- **Lifetime KPI tiles** fill the empty band in the totals card: sessions, messages, active days,
  first session, current and longest streak, all-time busiest hour, and longest session. Every figure
  is **read from Claude Code's own stats cache**, the same rule that governs the `/stats` total above
  them — the file already carried all of it.
  - Three of the tiles Claude Code shows are deliberately absent, because they'd restate their
    neighbours: Total tokens is the hero of that very card, Favourite model is row 1 of the model grid
    directly above it, and tokens/day is what the Today pace bar prints.
  - **Figures the cache can undercount are extended with our own days.** It is recomputed at most
    daily, so a streak read straight out of it understates — it said 24 where the truth was 26, and
    active days 71 where Claude Code itself showed 73. Current streak, longest streak and active days
    all extend across the same span, so they can't contradict each other.
  - A missing field renders as "—", never "0": an older Claude Code writes a cache without these keys,
    and "0 messages" would be a confident lie rather than "this file doesn't say".
- **Subagents/day**, in its own box beside This week: how much of each day ran under the Task tool,
  as a **share of that day on a fixed 0–100% scale**. The track is the whole day, the fill is the
  delegated part, and the percentage is printed under each weekday.
  - It was briefly a second bar chart of the same shape, and that was wrong. Each chart normalises to
    its own maximum, so Tuesday's subagent bar stood exactly as tall as Tuesday's total bar while
    being ~6× smaller — two identical marks side by side invite that comparison, and giving them
    separate boxes made it worse rather than better. A share has no free maximum, so there is nothing
    left to misread.
  - Deliberately **not** the gauge ramp. Every ramped bar in the app means "close to a limit", and a
    heavy-delegation day is not a warning — the same argument that made Subagents today a pace bar.
  - The header carries the week's own share, and drops it whole rather than clipping it when the card
    is too narrow.
  - `DayTotal` carries the subagent split per day now, not just per window, and the buckets sum to
    the window's own subagent figure exactly the way This week's sum to Week.

### Changed
- **Memory: idle footprint drops from 368 MB to ~181 MB, and the scan's peak from 1.2 GB to 724 MB.**
  A pet widget that idles between 30-second recomputes was sitting on its own high-water mark, and
  `vmmap` said why: **998 MB of `MALLOC_SMALL` regions marked "(empty)"** — arenas grown to parse
  1.9 GB of transcripts, freed, and then kept against a next allocation that doesn't come for hours.
  `heap` now puts the live set at **82.5 MB** across 230k nodes, of which 41.9 MB is the per-file entry
  cache and 8.1 MB is one interned string per entry.
  - Read `Physical footprint`, not `ps` RSS: RSS counts clean resident pages and still reads ~709 MB
    against a 181 MB footprint. And compare like ages — an idle process sheds hundreds of MB, so a
    17-minute "before" against a 1-minute "after" measures the clock, not the change.
  - **Intern `model` and `cwd` while parsing.** Both come back from `JSONDecoder` as a fresh `String`
    per line and both exceed Swift's 15-byte inline limit, so each one heap-allocated: **250,200
    allocations carrying about 130 distinct values** on a 125,806-entry corpus. `heap` confirms it —
    126,461 `Swift.StringStorage` nodes remain, one per entry rather than four.
  - **Stop building the entry list three times.** The merge used `flatMap` (which reallocates as it
    grows) and then `filter` for dedup (which returns a second full array). It now counts first,
    reserves once, and compacts in place.
  - **Hand the freed pages back**, with one `malloc_zone_pressure_relief` after a scan — never after a
    recompute, which touches no disk. Empty small-zone regions fell 266 → 141.
  - **Skip 56.5% of lines before `JSONDecoder` ever sees them.** Of 289,259 logged lines only 125,806
    contain a `usage` key; the rest were being decoded into a full `LogRecord` purely to be dropped one
    line later. A substring test rejects them first. It also removes two redundant copies per line —
    `Data.SubSequence` *is* `Data`, so the chunk copy and the per-line copy bought nothing.
    **This did not move the peak** (724 MB against 692–790 MB before it), so it is a scan-speed and
    allocation-churn change, not a footprint one; it is kept on those terms.
- **Subagents today is a pace bar**, read against your own recent subagent days rather than as a share
  of today. As a share it had no ceiling, so the gauge ramp would have been lying: 60% subagents is a
  fact about how you worked, not a warning, and the same day reads ~15% of work but ~8% of
  cache-inclusive total depending on a display setting. Against your usual subagent day it asks the
  same question the Today bar asks, so the colour means what it means everywhere else — full bar = a
  usual day, pinned once past it, exact % in the caption. A day with no history says "building
  subagent average…" instead of drawing a bar. Its caption no longer carries "18% of today" as a third
  clause — that share now has a chart of its own, where it is the point rather than an aside.
- **The subagent percentage sits on top of its own bar**, rising with it, and 15% smaller. It went
  centred (floating in an empty track with the bar far below) → pinned to the top of the track (a tidy
  row, but a 7% day labelled 100pt above the 7% bar) → riding the fill. Clamped so a near-100% day puts
  it on the coral rather than off the top. Dropping the second label row also lands the weekday letters
  on the same baseline as This week's beside it.
  - The size reduction nearly shipped as a no-op. Declared 12pt and scaled, the old label asked for
    16.65pt — too wide for a ~34pt slot — so `minimumScaleFactor` had been silently shrinking it to
    ~14pt. Taking 15% off the declared size changed the picture by 3%, because the declared size was
    never what was on screen. Measured from pixels instead: "48%" is 32 → 27px wide, cap 11 → 9px.
- **"+N more" lines up with the token column** it continues. It carried neither the row's horizontal
  padding nor its trailing cost reservation, so it drifted 63pt right, into the *cost* column: a token
  total sitting under the dollar figures, reading as a dollar figure.
- **The model grid and lifetime tiles are 15% larger.** Their fonts are declared at 9–10.5pt but the
  dashboard floors every font at 12, so editing those numbers does nothing — only the card's boost
  moves them. The height came out of that card's own inter-section gaps rather than the page: at the
  same boost with the old gaps the top row grew 48pt and clipped the bottom card off the window.
  `"Busiest hr · all time"` now fits in full, where it truncated to `"all ti…"` even before the
  increase.
- **Tuesday and Thursday no longer both read "T".** English initials are S M T W T F S — *two* pairs
  collide, and only the weekend one had been fixed. The weekly charts begin on the weekly reset day,
  which moves, so the order rotates and position can't separate either pair. Both now get two letters:
  `M Tu W Th F Sa Su`. The billing calendar shares the same helper even though its fixed Sunday-first
  columns would disambiguate on their own — it sits on the same screen as both charts, and one view
  showing "T" and another showing "Tu" for the same weekday is its own small lie.
- **Four boxes in the lower left, not two cards of two panels**: Today by hour, Today by model,
  Subagents/day and This week each get their own card, with the two weekday charts on an exact 50/50
  split — equal widths are what make them fair to compare. The vertical seam therefore doesn't line up
  with the row above, which is accepted: matching it would mean taking width from the 24-bar hour
  chart or handing Subagents/day more room than This week.
- **By project is all time**, not this cycle. Its header says so, and the empty state no longer claims
  the cycle is quiet when what it means is that nothing has been read yet. The cycle split is still
  computed and still sums exactly to the Cycle figure — this adds a lifetime series beside it rather
  than changing what that one means.
- **"Billing cycle"**, not "This billing cycle", and the title now sits against the middle of the
  figure beside it rather than hugging its top. At the 900×800 minimum the shorter name fits on one
  line, which brings back the full date range and the legend's peak-per-day figure.
- **Thicker gauge bars and the slack spread between the rows, not pooled under them.** The complaint
  was the gap between the three bars, not the bars themselves: all the card's spare height used to
  collect at the bottom, so the gauges bunched under the mascot with a void beneath. Equal spacers
  distribute it into the gaps instead. Widget and dashboard both.
- **The dashboard's type is ~3% smaller** at every size where height binds. The subagent pace bar made
  the left card the taller of the two, so it now sets the top row's height, and the lower row — which
  was already at its minimum on a wide, short window — lost the difference and clipped "By project"
  off the bottom edge at 1990×820. The reference height it scales against had to grow to match what
  the layout actually needs. Nothing on screen looks tight before it clips, because every gauge and
  chart in that card stretches; the check is the bottom-most *card* pixel, not the text.
- **The billing-cycle header wraps its title and pins the figure top-right.** Every earlier
  arrangement fought the card's narrowness: one line needed ~420pt and set the card's minimum width,
  and stacking the figure under the title spent ~45px of height — which is what the square cells are
  sized by. Letting the *words* wrap spends the one thing the header has spare and buys the grid
  ~24px of width back.
- **Today's cell in the calendar is properly marked** — a ring at double the weight and full-strength
  coral. At 1.5px against a shaded fill it read as an artifact of the shading.
- **Each gauge bar is one flat colour again**, chosen by that bar's own percentage, instead of a
  gradient along its length. It is also what the statusline does: `build_bar` resolves a single rgb
  for the whole bar. A bar shaded along its length implies the early part of the window was "cooler"
  than the later part, which isn't a thing that happened — every token counts the same.
- **The billing-cycle calendar is wider**, with correspondingly bigger cells — 279 → 302px at
  1470×923, and 279 → 339px at the 900×800 minimum. Widening it alone could never have worked: with
  square cells its width is set by its *height*, so it was already at its cap and the extra would have
  become dead space. The height had to come out of the top row.
  - It reached +50% mid-way and gave most of it back, because everything added to the top row
    afterwards — the 30% larger mascot, the KPI tiles, the subagent pace bar — is height the lower row
    no longer has. The end state is +8%, and saying +50% would describe a build nobody will run.
- **Today by hour sits above This week**, and shares its card with a new **Today by model** column —
  which models you used today, the one thing the widget showed that the dashboard didn't. (The model
  grid in the card above is Claude Code's *all-time* `/stats` split, a different question.) The column
  hides itself when the card is too narrow to hold it and the chart.
- **The hour axis runs 0–24** rather than 12a/6a/12p/6p. The bars are 24 hourly buckets, so a 24-hour
  axis maps onto them one-to-one instead of making the reader translate first. The peak-hour caption
  follows, zero-padded so it doesn't reflow as it ticks past 09.
- **The mascot block is 30% larger** in the dashboard. Not free: the mascot row is the taller of the
  sky and the Today header, and the sky binds — so every point of it pushes the top row down into the
  lower one, measured at 1.9px of calendar width per point. That trade was made deliberately, and it
  is most of why the calendar's +50% ended up at +8%.
- **"Today by model" is larger and looser** — bigger names and figures, more space between rows.
- **One name for the peak hour, with am/pm.** The widget said "most active ~09" and the dashboard
  "peak ~09" for the identical figure, which read as two different measurements. Both now say
  `peak ~9am`. The chart's axis stays on 0–24 deliberately: it's a scale read by position, where the
  numbers map one-to-one onto the twenty-four buckets, while the caption is a single time read as a
  word.
- **The axis labels have room to breathe** — the weekday letters and hour numbers were touching the
  bottom edge of their cards, which read as clipped rather than finished.

## [0.10.1] — 2026-07-31

### Changed
- **The gauge bars now use the terminal statusline's colours.** Same six stops — pale yellow, gold,
  Claude clay, orange-red, official red — so the two readouts of the same limits speak the same
  language. The track keeps the statusline's shape (the fill's own shadow) but its floor is re-solved:
  the terminal's is tuned to Ghostty's `rgb(40,44,52)` and this card is `rgb(14,14,16)`, so copying it
  verbatim made the track compete with the fill. Verified from rendered pixels against the
  statusline's own invariants — track 1.6–2.1:1 against the card, fill ≥1.55:1 above the track.
- **The billing-cycle calendar is tight, with square cells.** Its column is now sized from the row
  height rather than being a fixed share of the window, because with square cells its width *is* a
  function of its height — the fraction that fitted at the minimum window size stranded 91px a side at
  full screen. The width it gives up goes to This week and Today by hour. Its header stacks onto two
  lines, which is what let the card get narrow at all.
- **Card headers read as headings**, not captions — larger and full-contrast.
- **The pet is bigger** in the full-screen layout, grown into height the Today header already forced
  open, so it costs no type size elsewhere.
- **The top-left card is wider and the top-right narrower**, faded in with window width so the model
  grid doesn't truncate at the minimum size.
- **The widget's text is larger throughout.** It ran with no floor on its type ramp, leaving its
  7–9.5pt captions the smallest type in the product on the surface furthest from the eye.

### Removed
- **Duplicated figures in the two chart cards.** This week's total is already printed twice elsewhere
  on the same screen, and Today by hour's is the Today gauge's own number. The hour chart now shows
  its peak hour in that slot instead — the one thing it knows that nothing else does.

## [0.10.0] — 2026-07-31

### Added
- **The pet now shows two numbers instead of one.** Its face and sky follow your **5-hour session**;
  the **ground it stands on** follows your **weekly limit** — lush and green with headroom, drying
  through the week, cracked and bare at the edge. The mood used to be `max(5h, weekly)`, so a stormy
  pet could mean either limit and there was no way to tell which. Now a calm pet on cracked earth says
  something precise: plenty of session left, almost no week. Hover the pet for both in words.
- **More of everything to say it with**: nine moods (`content`, `focused` and `exhausted` are new —
  the ramp used to jump straight from happy at 49% to neutral at 50%, and had nothing at all for being
  *past* the limit) and eight skies (`partlyCloudy`, `overcast`, `drizzle`).

### Changed
- **The two top panels have swapped sides.** The limit gauges now sit under the mascot on the left,
  where the pet's mood and the bars that produced it read as one statement; Claude Code's lifetime
  `/stats` total and the per-model grid move to the right, above the week/cycle/billing lines.
- **The lower half is three columns**: This week over Today by hour in a narrow column, then the
  billing-cycle calendar with width priority, then By project. It is also *cheaper* than the two-row
  arrangement it replaced — the project list's fixed rows used to add to a chart row's height, and now
  every column is independent, so the row's minimum is the tallest single one rather than a sum. That
  paid for the project list going back to 8 rows and for a scale boost on all four lower cards.
- **Text contrast, measured rather than eyeballed.** Grey captions were written as
  `textSecondary.opacity(0.6)`, but `textSecondary` is *already* white at 0.70 — so that compounds to
  0.42 absolute and 4.0:1, under the 4.5:1 AA floor for body text. Seventeen call sites did some
  version of this, the worst at 2.3:1. There are now four named tiers, each documented with its
  measured ratio, and nothing carrying words sits below the floor. Verified from the rendered pixels,
  not from the source. The widget gets the same lift.
- **The gauge bars are a gradient along their length**, not one flat interpolated colour. A stop sits
  at its own percentage, so the pixel standing for 50% is the same coral whether the bar is at 60% or
  at 100%. The ramp itself was rebuilt: nine stops sampled at equal *perceptual* distance instead of
  three interpolated in RGB, which moved 1.51× faster in some parts of the bar than others and kinked
  visibly at the middle anchor — now 1.12×, near uniform. Its ends are pushed out too for more
  perceptual travel — 75% more — because the old ramp was so nearly monochrome that the gradient could
  barely be seen.
- **The unfilled part of a gauge is now a dark tint of the bar's own colour** rather than flat grey,
  an idea measured out of Claude's own Usage panel. It roughly doubles how clearly "how full" reads.
- **The calendar fills its card.** Cells were forced square, which caps them at the scarcer axis —
  at 1470×923 that left 84px of dead space on each side, a third of the card. Width now comes from the
  card and height from the row (capped at 2.6:1), which brings the dead space to single digits at
  every window size except a wide-but-short one, where six rows of calendar genuinely cannot fill a
  wide card without the cells becoming stripes.
- **"Today by hour" and "This week" carry their totals as hero figures** in the dashboard, with the
  unit caption on the title line. In a narrow column the caption is dropped whole rather than clipped
  to "peak ~1…". The widget keeps both lines, unchanged.
- **Scale boosts now fade in with window width.** They buy height and are paid for in width, and at
  the 900pt minimum there is none to spend — the top row overflowed, the gap between its two cards
  collapsed and the model grid truncated to "In 22…". They reach full strength at 1350pt, where they
  were measured.

- **The animation runs at 15 fps, not 6.** On a fixed pixel lattice the frame rate is a correctness
  constraint, not a smoothness preference: heavy rain falls up to 13.8 grid rows a second, so at 6 fps
  each drop jumped 2.3 rows between frames and skipped rows entirely — which is why the rain looked
  sparse and broken rather than falling. There's now one shared `AnimationRate` for the mascot and the
  weather, with a test tying it to the rain speed. Rain is denser too (a storm went 12 drops to 16, a
  heavy one 20 to 26).

### Fixed
- **The pet no longer floats above the ground** at 75%+ of the weekly limit. The surface row is where
  the feet land, and the two barest states left it empty — so the terrain read as a detached slab.
- **Rain no longer falls through the ground.** The terrain stopped one row short of its frame and
  drops appeared underneath it.
- **The By project card no longer floats mid-column** when a cycle has only a few projects. Its fill
  frame was outside the card, so the background was drawn around the content and then centred in a
  slot twice its height.
- **Weekday letters for days that haven't started yet are readable** (they were white at 0.21 —
  1.8:1 — so the week chart's axis appeared to stop at today).

## [0.9.1] — 2026-07-30

### Changed
- **Dollar figures keep their digits below $10,000.** `$1,001` was printing as "$1k", so the headline
  cost read the same for days while the real number climbed past $1,900. Abbreviation now starts at
  $10k, where it stops hiding anything that matters. Applies to the widget too.
- **A legend under the calendar** says what the shading means, and names the heaviest day's figure — a
  density grid can't be read without one, and every other panel already states its units.
- **"This billing cycle" is a headline**, sized with its total to match the card it now heads.

## [0.9.0] — 2026-07-30

### Added
- **The billing cycle is a calendar.** One shaded cell per day, denser where you worked harder, in the
  style of Claude Code's `/stats` grid. Same data as the bar strip it replaces, so the cells still add
  up to the Cycle figure exactly; today is outlined and days still to come are empty. The week layout
  follows your locale's first weekday.

### Changed
- **The lower half is rearranged**: the calendar owns the whole left column, with This week and Today
  by hour side by side to its right and By project full-width beneath them. A calendar's aspect ratio
  is fixed by its shape, so it needed two rows' worth of height — squeezed into one, the cells
  flattened into stripes.
- **Gauge bars ramp through the Claude palette** instead of jumping to system orange and red at 70%
  and 90%. Light coral with headroom, deepening to an ember at the limit, interpolated so there's no
  colour cliff where one token flips the whole bar.
- **Bigger limits card**: its text is ~20% larger and the bars are thicker.
- **"Total tokens" is now a hero figure**, sized like the cost and token counts above it.
- The summary rail grew to match — the taller limits card beside it hands the rail slack, and filling
  that costs nothing elsewhere.

## [0.8.4] — 2026-07-30

### Fixed
- **The bottom row no longer clips.** At 1470×923 — full screen on a 16:10 display — the "By project"
  card's bottom edge sat exactly on the window edge. The cause was structural rather than a bad number:
  `refHeight` had been tuned by finding where the layout *just* fits, which makes the layout's required
  height equal to it, and therefore leaves ~zero margin at **every** window size where height is the
  binding axis. Fixed by trimming the cards' unscaled padding, which is the only lever that returns
  absolute pixels, plus a small `refHeight` increase. Margin is now 13–26px across 900×800 to 2560×1440.

### Changed
- **Today's figures are much larger.** That row is as tall as the mascot beside it, and two lines of text
  reached only about 60% of it. Growing them is free — the mascot governs the row's height — so the
  headline cost, the token count and the cache figure now fill it. Verified at the minimum window size,
  where the column is narrowest, that both lines still fit without wrapping or truncating.
- Dashboard type elsewhere is ~2.6% smaller, the cost of the bottom margin above.

## [0.8.3] — 2026-07-30

### Changed
- **The summary card's text is larger and the card is full.** Its content reached only about four-fifths
  of the card — 23% blank at 900×800, 22% at 1470×923, 20% at 1990×1256 — because the card beside it sets
  the row height. That slack was free: the rail now runs at its own scale, so the Today figures, the
  total and the whole model grid grow into it and the blank falls to 6–10%. Nothing else on the dashboard
  changes size; the layout's height and the bottom margin are identical to before.

## [0.8.2] — 2026-07-30

### Changed
- **The two top cards are the same height**, so the band they form has one bottom edge. Left to their
  natural sizes the summary card ended well short of the limits card, leaving a strip of dead canvas
  beside it.
- **Every model is listed** — the height that equalising freed pays for the fourth grid row, so the
  "+N more" line no longer appears on a normal account.

### Fixed
- The mascot row no longer opens a hole beneath the Today header. Its right column was greedy for
  height, so once the card started stretching it swallowed the slack instead of the model grid.

## [0.8.1] — 2026-07-30

### Changed
- **The model list is two columns**, so the top-left card shows six models instead of three — for the
  same height, and with no change to the type size. The card is wider (52% of the row) to carry the
  In/Out line under each name; the limits card beside it is bars and text, which reflow happily in what's
  left.
- **Closed the gap under the mascot.** Once "Today by model" moved out of that card, the pet's sky block
  was the taller side of the row again rather than the stats beside it, so the block came down to suit.

## [0.8.0] — 2026-07-30

### Added
- **Claude Code's own "Total tokens", and the per-model breakdown behind it**, in the top-left card —
  each model's share with its input/output split, matching the `/stats` Models tab. These are **read
  from `~/.claude/stats-cache.json`**, Claude Code's own local cache, because the figure cannot be
  recomputed from the transcripts: measured against one complete day where `/stats` read 3,063,775,
  counting every logged line gave +7.2%, excluding subagent lines −3.3%, and deduplicating by message id
  ×0.36. Nothing lands on it. Still local-files-only — no network, no token.
- That cache lags up to a day, so today's usage is added on top when it stops exactly at yesterday, and
  never when it already covers today. Today's slice uses ClaudePet's own accounting (~±7% off Claude
  Code's), which the tooltip states rather than glossing.

### Changed
- **Subagents moved to the top-right card**, beside the three usage bars it's a share of. The
  week / cycle / billing lines moved there too — that card had slack, the left rail had none.
- **The small grey labels are bigger**: the hour axis +42%, "work/day" +17%, "resets in" +5%, "Week" and
  "Cycle" unchanged. The type ramp was drawn for a 300pt widget card, so the dashboard now floors font
  sizes before scaling instead of relying on the global scale, which lifts headlines equally.
- The all-time row and "Today by model" are gone from that card — the new panel supersedes both. Without
  a `/stats` cache (older Claude Code) they come back automatically.
- **Headline figures are ~17% smaller.** Nothing scrolls, and seven new lines had to come from somewhere.
  Verified: `ScrollView` renders blank through `ImageRenderer` just as `Form` does, so scrolling isn't
  available as an escape.

### Fixed
- **The live delta never fired on a non-Gregorian locale.** `stats-cache.json` dates are Gregorian
  strings; compared against `Calendar.current` under the Thai Buddhist calendar, today's year reads 2569
  rather than 2026, so the cache always looked stale and the total silently omitted today.

## [0.7.3] — 2026-07-30

### Fixed
- **Corrected a backwards claim about subagents** in the "Include subagent usage" caption and the new
  Subagents tooltip. Both said subagent cost is "nearly all cache reads", so they "barely register
  under Work and only show their true size under Total". Measured against real transcripts it is the
  other way round: subagents were **15% of work but 8% of cache-inclusive total**. A subagent runs in
  a short-lived context while the main conversation re-reads a large cached one every turn, so cache
  tokens accumulate faster on the main thread, not on the subagents.

## [0.7.2] — 2026-07-30

### Changed
- **Today's header is two lines in the dashboard**, with the token count and the cache count side by
  side instead of stacked. That line back is worth ~6% on every label, so the type is now slightly
  larger than it was in 0.7.0 *and* keeps the Subagents / All-time rows 0.7.1 added. The widget keeps
  its three-line header — its stats column is only ~200pt wide and the two figures wouldn't fit.

## [0.7.1] — 2026-07-30

### Added
- **Subagents and All time in the summary card.** Two figures that appeared nowhere else: today's
  subagent (Task-tool) tokens with their share of the day, and your all-time total with its notional
  cost. They fill the gap that opened in that card on a quiet day — and they were picked precisely
  because they're always there, where the model list above is one row on a single-model day and four on
  a mixed one, so anything sized to it leaves a hole exactly when there's least to look at.

### Changed
- Dashboard type is ~5% smaller than 0.7.0 (still ~40% above 0.6.0). Nothing scrolls, so the two new
  rows had to come out of the vertical budget; filling the card was the better trade.

## [0.7.0] — 2026-07-30

### Changed
- **Three-column dashboard, and no more footer strip.** "This week" and "Today by hour" now have a
  column each instead of stacking in one card, and the week / cycle / billing totals moved out of
  their full-width footer row into the summary card at the top left — which is exactly the space that
  card was wasting. Three rows instead of four.
- **Dashboard text is larger again, ~12% at full screen** (~48% over 0.6.0). Nothing scrolls, so type
  size is bounded by what has to fit vertically; losing a whole row is what paid for this one.
- The week and hourly charts now grow their bars into the height available, as the cycle chart already
  did, so the three bottom columns fill rather than leaving voids under the shorter two.

## [0.6.2] — 2026-07-30

### Changed
- **Dashboard text is larger again — about 17% on top of 0.6.1, ~32% over 0.6.0.** Nothing on the
  dashboard scrolls, so type size is bounded by what has to fit vertically; the only way to enlarge it
  is to make the layout need less room. So: the mascot shrank again, card padding and the gaps between
  cards tightened, and the project list now shows 6 rows instead of 8. Nothing was dropped — the tail
  is still totalled on the "+N more" line. Very large displays also get a higher ceiling.

## [0.6.1] — 2026-07-30

### Changed
- **True black theme.** The cards were a mid-grey gradient, which on a large dark display washed
  everything out — grey on grey, with the coral fighting both. Canvas is now pure black and the cards
  near-black, so the coral and the white figures carry the contrast instead of the background. Card
  borders and secondary text were lifted to stay legible against it. Applies to the widget too.
- **Larger text in the dashboard, ~12%.** Nothing scrolls, so type size is capped by what has to fit
  vertically — and the biggest single consumer was the decorative mascot. Shrinking it is what paid
  for the text. The scale ceiling also rose, so very large displays get proportionally bigger type.

### Fixed
- The billing footer no longer clips at full screen on a 16:10 display. The reference height the type
  scale divides by was below what the layout actually needs, which clips at *every* window height
  rather than just small ones.

## [0.6.0] — 2026-07-30

### Added
- **A full-screen dashboard window.** The expand button beside the gear opens a real, resizable Mac
  window — green button and ⌃⌘F take it to its own full-screen Space, and closing it returns the app
  to being dockless. It shows everything the widget does with room to breathe, plus two things the
  widget has no space for: the whole billing cycle day by day, and a per-project breakdown. The
  widget is untouched and stays where it is (it hides itself while the dashboard is full screen, so
  it can't float on top of it).
- **Usage by project.** Which repos actually burned the cycle's tokens. The name comes from the
  working directory each transcript line records, so it's exact — the `~/.claude/projects` folder
  name can't supply it, because that encoding replaces every non-alphanumeric character with `-`
  (`/Users/you/Desktop/LiDAR + HPE` is stored as `-Users-you-Desktop-LiDAR---HPE`) and isn't
  reversible. Grouping is by the transcript's own project folder rather than by that per-turn
  directory: on real data the raw directories took **120 distinct values across 11 projects**,
  because every workflow worktree and every incidental subdirectory gets its own. Subagent turns
  count toward the project that launched them.
- Both new breakdowns are computed with the same in-cycle test as the Cycle figure itself, so the
  day bars and the project rows each sum to it exactly rather than approximately.

### Fixed
- The Cycle total no longer counts turns stamped after the cycle has ended. It was bounded only at
  the start, so a clock-skewed timestamp inflated the headline while belonging to no day bucket.
- Closing Settings while another window is open no longer drops the Dock icon and menu bar out from
  under it.

## [0.5.1] — 2026-07-29

### Fixed
- **The session budget no longer reverts to a much worse estimate every few hours.** A budget fitted
  from Claude's percentage was discarded the moment its window reset — 4–5× a day for the 5-hour
  gauge — falling back to the estimate built from your own history. On real data that meant a
  genuine 3.17M sitting unused in preferences while Settings displayed **6.2M against a real limit
  of ~1.9M**. The premise was wrong: a reset expires the *percentage*, not the limit, which belongs
  to the plan. A fitted budget now stands until something better replaces it, and only ages out
  after two weeks so a plan change can still move it.
- **A precise reading is no longer overwritten by a noisy one just for being newer.** The error in
  `budget = used ÷ %` scales as 1/%: ±0.5% rounding is ±0.5% of the budget at 96% but ±7% at 7%. A
  window that has just reset reads 10–12%, and those readings were replacing ones taken near the
  limit — the same session's implied cap ranged **1.87M to 3.16M** purely by when it was sampled.
  Each fit now records the percentage it came from and defends itself against less precise ones,
  with that claim decaying to nothing over two weeks so it yields without a cliff. Readings at
  ≥99% are ignored, where you may be throttled and still logging turns. Within one window
  percentages only climb, so later readings there always refine the fit.
- **Settings no longer calls a synced budget an estimate.** The caption tested whether *either*
  gauge was stale, so with the weekly synced and the 5-hour not, it described both as "estimated
  from your own heavy completed windows" — directly above a weekly figure that was Claude's own
  number. Each budget now states its own basis, including the percentage it was fitted at.

### Changed
- **The local fallback is described as what it is.** It was worded as an approximation of your
  ceiling; measured against Claude's live percentages it runs **~3× above the real 5-hour limit**.
  The cause is structural and not fixable from local files: ClaudePet reconstructs 5-hour windows,
  Claude re-anchors its own per session, and a reconstructed span that straddles one of its resets
  holds more than one limit's worth (one held 2.92M against a 2.3M cap). Re-bucketing doesn't help —
  a fixed lattice and a chained model landed at 5.72M and 6.67M against the same ~1.9M truth. It is
  now labelled a rough upper bound, and the "a window reset — re-calibrate" prompt is gone, since
  nothing needs re-aligning.

## [0.5.0] — 2026-07-28

### Added
- **The Auto budget now syncs itself to Claude's real percentages** whenever the statusline cache
  has a usable reading, instead of resting on the estimate built from your own history. That
  estimate measures your habits and says nothing about where Anthropic's cap sits: measured against
  the live numbers it ran **5.9× high on the 5h gauge and 2.7× high on the weekly one**, so the
  bars read far cooler than Claude's own. The back-solve is the same one the Calibrate sheet has
  always done (`budget = used ÷ %`), now re-fitted on every refresh, and Settings says which
  denominator is live. Gated so a bad sync can't overwrite good budgets: both windows must be
  present, unreset and at or above 10% (the cache stores whole percents, so a 3% reading carries
  ±17% of budget error), and "Use Claude's live usage" is the opt-out. Still local files only —
  same cache the gauges already read, no token, no network.
  - Tokens are counted over **Claude's** window, not ClaudePet's. Our 5h block is gap-anchored to
    your own first message and drifts off Anthropic's grid; dividing a block that spanned a reset
    by the fresh percentage on the other side of it produced a 21.1M session budget where the
    right answer was 2.3M.
  - Both units are fitted every sync, so switching Gauge unit between Tokens and US$ no longer
    shows a budget left over from whenever that unit was last selected.
- **The 5-hour and weekly windows auto-align to Claude's real reset times** from the same cache,
  so "Calibrate reset time" and the weekly reset-day pickers maintain themselves. They were out by
  4 hours in practice (ours 09:15–14:15 against Claude's 13:00–18:00), which misattributes every
  token logged between the two boundaries and makes "resets in" wrong; they now track to within a
  second. Only the phase moves — the correction is folded into ±2.5h and always applied backwards,
  since an anchor pushed past *now* would pin the window's start into the future.

### Fixed
- **A 5-hour reset no longer expires the weekly calibration.** One timestamp covered both gauges,
  so each 5h rollover — several a day — dropped a perfectly good weekly fit back to the local
  estimate (seen live: 22M → 57M and back). The two now carry their own stamps and their own noise
  floor, so each syncs, expires and falls back on its own clock; one window being unusable or too
  quiet to divide no longer holds the other hostage. Prefs saved with the old single stamp migrate
  across, and each gauge's tooltip states its own denominator rather than sharing one sentence.
- **The Auto budget no longer gets stricter on one gauge than the other just because it has seen
  more windows.** It was the single heaviest completed window, and `max` over n samples climbs
  with n — on real data the 5h grid had accumulated 137 completed windows against the weekly
  grid's 9, so the 5h denominator sat deep in its own tail (its top window was 1.5× the next and
  7× the median) while the weekly one sat beside a typical heavy week (1.05× the next). The same
  "% of your own record" meant two different things: a heavy session filled 42% of its bar while a
  heavy week filled 79%, and the gap widened every week. It's now a fixed quantile of the
  completed windows, which converges instead of climbing — heavy session 88% vs heavy week 79% —
  and one exceptional session no longer pins the denominator for good. Below 21 windows it still
  takes the heaviest, which is the only sensible answer on a short history.

## [0.4.0] — 2026-07-26

### Added
- `CONTRIBUTING.md` — build/test steps, the project layout, the two non-negotiable constraints
  (local-file-only, original art only), the settings-persistence pattern, and a deterministic-tests
  note prompted by a real flaky test fixed this release.
- **Sub-agent share** in the tooltips on the Today header, both gauges and the Week/Cycle line —
  "Sub-agents (the Task tool) account for N% of this …". Sub-agent turns were always counted, but
  their cost is almost entirely cache reads, so on the Work basis they look like they aren't: on
  real data they were 43% of turns yet 2.6% of the weekly *work* total. `Totals` and `UsageBlock`
  now carry the sidechain split, accumulated in place at no extra cost. The "Include subagent
  usage" toggle finally gets a caption, which also states the thing that surprises people — with
  live usage on it changes the token counts but **not** the bar percentages, because those are
  Claude's own accounting, which always includes sub-agents.
- **"Count repeated log lines (match /stats)"** in Settings → Appearance, off by default. Claude
  Code writes the same assistant turn to its transcript several times — 62% of logged lines on real
  data repeat a `message.id` already seen, with byte-identical usage — and its own `/stats` counts
  the lines rather than the turns, which is why `/stats` reports roughly 2.4× ClaudePet's figure.
  Turning this on reproduces that counting. It finds no missing usage; it counts one API response
  more than once, and inflates **cost** along with the token counts, so it's for reconciling the
  two tools rather than for daily use. Related: `/stats` "Total tokens" is `input + output` only —
  cache is excluded there, so it maps to ClaudePet's *Work*, never its *Total*.

### Changed
- **The "used this window/week" line under each gauge now follows "Count tokens as" and names its
  unit** ("4.2M work used this week"). It was hard-wired to work tokens while the header, charts,
  per-model split and Week/cycle line all honoured the setting — so on the default Total basis the
  weekly bar read "4.2M used this week" directly above a footer reading "Week 1.3B", the same
  window ~300× apart, with the unit printed on neither. The `%` beside it is Claude's server-side
  number and the count below it is a local token sum; the tooltips now say so outright.
- **The "This week" chart now covers the weekly-limit window** — one bar per weekday of that
  window — instead of the rolling last-7-calendar-days, so the bars sum to exactly the weekly
  total above them. With a mid-afternoon reset the two disagreed by everything logged earlier on
  reset day: 682,822 work tokens, ~16%, on real data. Still seven bars: reset day counts only the
  hours inside the window, and the window's trailing reset-day hours fold back onto the same
  weekday rather than adding an eighth. Today is highlighted, days still to come are dimmed.
- **The daily-pace bar now reads as "today, as a share of a usual day".** A usual day fills the
  bar, so the fill and the percentage beside it always agree: "679.1k/day avg · today 70%" next to
  a bar 70% full. It used to put the average at the *midpoint* (full ≈ 2× a usual day), so a day
  at 70% of normal drew a third of a bar — which reads as "barely a third of normal", and once the
  caption spelled the percentage out the bar and the number plainly contradicted each other. A day
  heavier than usual now pins the bar full and turns it coral, with the percentage carrying the
  overshoot past 100%.

### Fixed
- **A failed transcript read is no longer cached as "empty".** `UsageScanner` keyed a swallowed
  read error to the file's `(mtime, size)`; finished sub-agent transcripts are never written again,
  so one transient failure zeroed that file permanently for the life of the process — silently, and
  they are 96% of the transcripts on a heavy user's disk. It now leaves the file uncached and
  retries on the next scan.

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
