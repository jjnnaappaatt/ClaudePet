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
CLAUDEPET_CODEX=47 ...              # fake the Codex row: "<pct>[,<age_seconds>]", or "none" for a
                                    # machine without Codex. Writes its own temp file — never point
                                    # anything at the live /tmp/claude/codex-usage-cache.tsv.
CLAUDEPET_STATSDELTA=2026-09-18 ... # print what StatsReplica adds on top of a /stats cache whose
                                    # last day is the day before, as JSON, and exit — the check that
                                    # the port still agrees with Claude Code (see "/stats figures")
CLAUDEPET_HANDLES=1 ...             # force resize grips visible
CLAUDEPET_DEVICE=88,serious,3 ...   # fake the header's device readout: "<°C|none>,<state>,<cpu%>"
CLAUDEPET_NOLIVE=1 ...              # ignore the statusline + drop the calibration anchor, so the
                                    # local-history budget estimate is what you're looking at
```

**The snapshot path cannot see the widget panel's size.** `ImageRenderer` draws the content at its
own ideal size and never asks the panel, so a panel stuck 184pt short of its content — header and
footer clipped in the real app — rendered perfectly here. `CLAUDEPET_PANELFIT=1` runs the normal app
flow, waits for the first scan, and prints `OK` or `FAIL: panel is Npt off its content`. Run it after
anything that changes how the panel is sized or when the content's height changes.

```bash
CLAUDEPET_DASHBOARD=/tmp/d.png ...                  # the dashboard window's view
CLAUDEPET_DASHBOARD=/tmp/d.png CLAUDEPET_DASHSIZE=900x800 CLAUDEPET_REAL=1 ...   # at its minimum
CLAUDEPET_DASHBOARD=/tmp/d.png CLAUDEPET_DASHSCALE=2 ...  # retina capture for docs only; default 1 keeps px == pt for measuring
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
   `/tmp/claude/statusline-usage-cache.json`, `/tmp/claude/codex-usage-cache.tsv`, `~/.claude/stats-cache.json`,
   and Codex's own rollouts in `~/.codex/sessions` (`CodexRolloutReader`). Never reads the OAuth token, never makes a network
   request. A feature needing data that isn't already local is out of scope. The one non-file read
   is the Mac's temperature sensors (`DeviceMonitor`, private IOKit API via `dlsym`) — on-device,
   and it degrades to `ProcessInfo.thermalState` if the symbols go away. `.claude/hooks/no-network.sh`
   flags any networking API written into `Sources/` (PostToolUse); extend its pattern, don't silence it.
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

**This pipeline sets the app's memory high-water mark, and the peak is what you pay for.** Parsing
1.9 GB of transcripts into ~125k entries once drove the footprint to 1.2 GB and left it there: `vmmap`
showed ~1 GB of `MALLOC_SMALL` regions marked **"(empty)"** — freed arenas the allocator keeps against
a next allocation an idle widget won't make for hours. Three things hold it down now, and all three
are easy to undo by accident:

- `malloc_zone_pressure_relief` after a **scan** (`MetricsStore.refresh`), never after a recompute.
- A `StringInterner` threaded through the parse. `model` and `cwd` arrive as a fresh `String` per line
  and both exceed Swift's 15-byte inline limit, so each heap-allocates — 250k allocations for ~130
  distinct values. Any new per-entry `String` field belongs in the same table.
- One allocation in `UsageScanner.merge`: count, `reserveCapacity`, then compact **in place**.
  `flatMap` + `filter` built the 125k-entry array three times over.
- A `"usage"` substring test before `JSONDecoder` in `JSONLParser.entries`. Only 125,806 of 289,259
  logged lines carry the key; the rest were decoded into a full `LogRecord` just to be dropped. Safe
  in one direction only, which is the point: a false positive costs a decode that was happening
  anyway, a false negative is impossible. It bought **scan speed, not footprint** — the peak did not
  move — so don't cite it as a memory fix.

**Two full-array copies were being made per cycle by code whose comments said otherwise.** Both are
now pinned by `AllocationTests`, which exists because these produce *byte-identical output* — every
functional test in the suite passes either way, so the only visible symptom is memory:

- **`UsageScanner.merge` takes its parameter `consuming`.** It always meant to sort in place, but a
  plain parameter is *borrowed*: the caller's array stays live for the call, so `var sorted = entries`
  left the buffer non-uniquely referenced and `sort()` silently took a full COW copy. ~15.7 MB
  allocated and freed on **every scan**, and FSEvents rescans on every transcript write.
- **`FiveHourBlockEngine.timeOrdered` replaces two `entries.sorted { }` calls.** `merge` had already
  sorted, so those were re-sorting sorted data — but `.sorted` allocates unconditionally, twice per
  `recompute()`, on a 30s idle timer. It returns the same array (copy-on-write; both callers only
  read) when input is already ordered, and the O(n) check is real rather than a precondition comment
  because `ingestForTesting` assigns arbitrary arrays straight to `lastEntries`.

**`UsageEntry` is 96 bytes and holds no per-entry string.** Two copies are resident for the process's
life, so every byte costs ~250 KB twice at 128k entries. Field order is load-bearing: `family` and
`isSidechain` are one byte each and, declared between 8-aligned fields, each dragged a 7-byte hole —
14 bytes of the original 128 were padding. Grouped at the end, with the five counts narrowed to
`Int32` (stored `Int32`, read `Int`, summed in `Int`, clamped on construction so a corrupt value
saturates instead of wrapping negative), it is 96. `messageID` is a 128-bit `MessageKey`: unique per
entry so interning cannot help it, and as a 28-char `String` it cost a 64-byte heap node each —
129,692 nodes, 8.3 MB, allocated only to be compared. 128 bits rather than 64 because dedup keeps the
first entry per key, so a collision silently drops a real turn; verified 0 collisions over 129,806
real ids. Measured settled: live set 73.3 → 40.6 MB, malloc nodes 215,283 → 86,206. Pinned by
`AllocationTests` — both changes leave every figure identical, so nothing else can see them regress.

**The cold scan's peak was the largest transcript, held whole — fixed by moving one line.**
`JSONLParser.parse` read each 1 MB chunk in its `while` condition, outside the per-chunk
`autoreleasepool`. `readData` autoreleases, so every chunk of a file stayed live until the whole file
finished: 36 live 1 MB nodes mid-file in `heap`, and afterwards **~250 MB of "Malloc Small/Large
(empty)"** that malloc kept. Peak was **483–495 MB → 271–280 MB** with nothing else changed. The same bug
was in `CodexRolloutReader` and (briefly) `StatsReplica`, where it reached 3.8 GB. **Any loop that reads
a file in chunks must call `readData` inside the pool.** `heap` showing a live set far below the
footprint, with `(empty)` regions making up the difference, is this bug's signature.

**The dedup-mode per-file cache keeps only the earliest copy of each message per file**
(`UsageScanner.appendKeepingEarliest`). Claude Code re-logs one response several times, always within
one file, so a cache of every line was 2.5× the merged result: 56 MB of per-file arrays for a 22 MB merge,
and `fullMerge` concatenated all of it. Cross-file copies are kept per file, so deleting the file with
the kept copy still resurrects the other. The cost: the cache no longer serves both counting modes, so
toggling "Count repeated log lines" **re-reads** every file. With the fix above, end to end: peak
**450–488 → 206 MB**, settled **170–202 → 116–152 MB**, CPU over the first ~5 min 29–40 → 19–22 s.
`InFileDedupTests` pins the cache size —
the merge is identical either way, so nothing else can see this regress.

**Dedup order is `UsageEntry.keptBefore`, a total order — never sort by timestamp alone.** 1,555 messages
have their earliest copy logged at the same instant in more than one place, 35 of them with different
usage, and the unstable sort picked a different survivor per launch: two simultaneous runs of one build
read 761,647 vs 764,068 for the 30-day daily average. That made every A/B between builds noise. The
tie-break prefers the more complete record (more output, input, cache reads), then the project folder.
Use it wherever a copy is chosen — `merge`, the delta batch, `appendKeepingEarliest` — and note the
delta path re-merges on a repeat **at or before** `baseLast`, not just before it, because a tie can now
beat the kept copy.

**Two more that looked obvious and measured WORSE — do not re-propose:**

- **Exact-sizing the per-file arrays** (`reserveCapacity` + copy at the end of `JSONLParser.entries`).
  The premise was geometric-doubling slack. Measured on the real corpus: natural `append` growth is
  only **1.09×** count, while `reserveCapacity(count)` rounds up to **1.21×** — the "fix" was **1 MB
  worse**. Swift's growth and malloc's size classes already land tighter than an explicit reserve.
- **Routing `scanOnce` through `concatenated`.** Correct for the *cached* path, wrong here: `scanOnce`
  has no cache, so collecting `[[UsageEntry]]` to count them holds every per-file array alive
  *alongside* the merged result, where the unreserved `append(contentsOf:)` frees each as it goes.
  Measured **+20.6 MB**.

**Three measurement traps, all hit while doing the above:**

- `grep`ing `vmmap` for a literal region size (`"15.6M"`) reported the regions as *gone* when the
  corpus had merely grown and they were now `15.7M`. Match the shape, not the number.
- Hand-rolled `awk` over `vmmap` mis-parsed the columns twice (`$2` is `(empty)`, not the address).
  Parse it in Python and print what you matched.
- Instantaneous `Physical footprint` swings **123–527 MB at the same uptime** depending on where in
  the scan cycle you sample. Single samples cannot support a delta; the snapshot path's peak is set
  during *parsing*, so it cannot see a 15 MB transient at merge time at all.

`.claude/skills/measure-claudepet` scripts everything in this paragraph (and records config, binary
hash, uptime, corpus size and load with each figure) — use it rather than hand-running the tools.
Measure with `vmmap -summary <pid>`, not `ps` — RSS counts clean resident pages and still reads
~709 MB against a 181 MB footprint. `heap <pid>` is the one that ends arguments: it put the live set
at 82.5 MB (41.9 MB of per-file entry arrays, 8.1 MB of interned strings), which is what proved the
~500 MB of "(empty)" arenas really were free rather than leaked. Compare **`Physical footprint (peak)`**, and quote it as a
range: FSEvents re-scans on every transcript write and each re-scan re-peaks, so over 11 minutes of
active use it wandered 526–790 MB. Do **not** compare current footprint between two runs of different
ages — an idle process sheds hundreds of MB, so a 17-minute "before" against a 1-minute "after" is not
a measurement, it is a clock.

**Dedup is load-bearing:** on a real corpus **8,349 of 12,259 `message.id`s appear more than once**,
almost every repeat inside the same file — re-logs of one API response, not streaming deltas (3.7% of
repeats do carry different usage; the earliest copy is kept). Keep one per `messageID` — the first by
`UsageEntry.keptBefore` — never sum, or tokens and cost roughly triple.

**…but it is switched off by a setting, so never read a figure as deduped without checking.**
`countRepeatedLogLines` (Settings → "Count repeated log lines (match /stats)") passes
`deduplicated: false` all the way down; it is a supported mode, not a bug. This paragraph used to stop
at the sentence above, which reads as a guarantee — and cost a full investigation into a "3× overcount"
that was the user's own preference working correctly. **Check the preference before diagnosing any
figure that looks too large.** With it on, ClaudePet's all-time work reads 185.6M against `/stats`'
140.5M; with it off, 60.6M.

Verify a token figure against the transcripts directly rather than against another figure in the app:
sum `input_tokens + output_tokens` over `~/.claude/projects/**/*.jsonl`, keyed on
`message.id ?? requestId`. That is what settled it, and it takes about a minute.

**But dedupe the walk by inode, or the check is wrong and looks right.** Claude Code **symlinks a
workflow's agent directory into every session that resumed it** — e.g.
`<sessionA>/subagents/workflows/wf_…` → `<sessionB>/subagents/workflows/wf_…`, one physical file
(same inode, byte-identical) reachable by two paths. Python's `glob(recursive=True)` follows those
directory symlinks and counts the file once per path; `FileManager`'s enumerator, which the app uses,
does not. A scan built the obvious way therefore reports MORE than the app and the app looks like it
is undercounting. Measured here: 11 duplicate paths, one day (2026-07-29) inflated by 113,808
sidechain tokens, which moved a 30-day mean by 3,794/day — small, stable, and easy to write off as
"live drift", which is exactly what happened for several verifications before it was caught. Skip any
path whose `(st_dev, st_ino)` you have already read; with that one line the same scan matched the app
**to the token** on both pace baselines.

### CPU — the scan, not the animation

Every optimisation round before this one was about memory, so the first CPU measurement found the
widget burning **45–100% of a core, sustained, while Claude Code was in use**. Memory was fine at the
time (93.6 MB settled) and is not the lever here.

**Profile before touching anything, and split by thread.** `sample <pid> 5` showed the main thread
**blocked in `mach_msg2_trap` for 3110 of 3178 samples** while the scanner's cooperative queue was
on-CPU for **3619 of 3621**. A UI review had concluded the mascot's `TimelineView` was the top cost;
it was not, and after the fixes below the whole animation stack measures **0.8% of main-thread
samples on a thread that is 90.7% blocked**. Don't optimise the mascot — gating it further risks
freezing the pet for a saving that does not exist.

**Root cause: an append re-parsed the whole file.** The per-file cache is keyed `(mtime, size)`, so
one new line invalidated everything. Transcripts are append-only and huge — measured live, one
appended line cost a **180 MB** re-parse on one live session and **682 MB** on another, against
~220 KB of genuinely new data over twelve minutes. `JSONLParser.parse(fileAt:from:)` now resumes from
a byte offset, guarded by an FNV-1a fingerprint of the 4 KB ending at that offset.

Four things about that guard, all of which have already caught something:

- **`parsedUpTo` stops at the last complete *newline*.** An unterminated final line is still parsed
  and returned, but not counted as consumed — and `FileParse.tailCount` says how many entries came
  from it, so the scanner drops them before appending. Without that, a line split across two scans is
  counted twice; dedup hides it in the default mode while `countRepeatedLogLines` shows a doubled
  figure. Verified: 400 of 400 sampled transcripts end with a newline, so this is the mid-write case.
- **`size >= hit.size` is a cheap early-out, not the truncation guard.** Mutation testing says so —
  deleting it leaves every test green, because a file shorter than `parsedUpTo` cannot produce a
  fingerprint there. The fingerprint is what makes this safe.
- **The `StringInterner` moved onto the actor.** It was per-scan, correctly, while every changed file
  was re-parsed whole. Now a file's head is parsed once and its tail by hundreds of later scans, so a
  per-scan table would hand out a fresh `String` per append and the sharing would decay as the app ran.
- **Transcripts really are append-only**, verified rather than assumed: the first line is
  `type: last-prompt` and looks like a mutable header, but there are **822 of them at strictly
  increasing offsets**, and a file with 12 compaction markers still held all 180 MB.

Three hot spots inside the parse, each replaced by a byte scan, each one-directional:

- **`TimestampParser` used `ISO8601DateFormatter`** — ICU `SimpleDateFormat::parse`, **676 of 3103
  samples (19%)** — and tried the *fractional* formatter first with a fallback, so any timestamp
  without a fraction paid two ICU parses. 6,014 timestamps sampled across 120 random files were
  **100.0% `NNNN-NN-NNTNN:NN:NN.NNNZ`**, so that shape is decoded arithmetically and everything else
  still goes to the formatters. Pinned bit-for-bit against them.
- **`Data.split(separator:)`** for lines — **1015 samples (28%)** — is now a `memchr` walk.
- **`Data.range(of:)`** for the `"usage"` probe — **261 samples (7%)** — bridged to `NSData`
  Boyer-Moore per line; now `memchr` + `memcmp`. The probe itself is unchanged and still earns its keep.

**`String.contains(_:)` on a `String` argument is not a byte scan** — it resolves to
`range(of:options:range:locale:)`, locale-aware NSString searching. It sat in `ModelFamily.init`
(once per parsed line) and `PricingTable.effectivePrice` (once per entry, from three full-history
loops per recompute — order 384k calls every 30s), each preceded by a `lowercased()` allocation.
`String.asciiContains` replaces both. **Fold `A...Z` explicitly, not with `| 0x20`:** the bit trick is
the obvious way to write it and it also maps `@`→`` ` `` and `[`→`{`, so `"A@B"` matched `` "a`b" ``.
Harmless for today's needles and exactly the "sound for current inputs" reasoning that stops being
true when someone adds an override with an underscore.

Measured end to end, matched back-to-back runs on the same 2.29 GB corpus:

| | before | after |
|---|---|---|
| cold scan, wall clock | 12.4–13.0 s | **2.25–3.78 s** |
| cold scan, user CPU | 11.7–12.3 s | **1.79–1.80 s** |
| live steady-state CPU | 45–100% | **6.3–26.5%, mostly ~6.5%** |
| `UsageScanner.scan` samples | 3103 | **52** |
| `JSONLParser` samples | ~2941 | **0** |
| max RSS | 794 MB | 785 MB (unchanged — this was never a memory fix) |

Equivalence was checked on real data, not just fixtures: 27,561 lines and 14,666 timestamps A/B'd
against the old implementations with **0 mismatches** (and 0 falling back to the formatter), and the
old and new binaries rendered **pixel-identical dashboards** apart from the burn-rate figure, whose
denominator is elapsed wall clock.

### CPU, second round — the steady state under heavy use

The round above fixed the *parse*. The installed v0.14.0, 3.7 days up on a 5.8 GB corpus, still
measured **101–107% of a core**: `sample` put it all in `refresh()` — every FSEvents burst started
its own overlapping scan, each walked + stat'd every transcript, re-sorted and re-deduplicated all
~130k entries (`merge`), then ran the full-history `recompute()` on the main actor, where
`PricingTable.effectivePrice` re-parsed a date string through `Calendar` per entry. What replaced it,
and the traps in each:

- **`requestRefresh` / `refresh(changes:)`**: one scan at a time, chained in order, ≥2 s apart, a
  burst coalesced into one. Order is now a correctness requirement, not a nicety — each delta is
  relative to the result before it.
- **`FileWatcher` passes paths; `scanChanges` stats only those.** FSEvents reports *resolved* paths
  (`/private/var/…`), so `inRoot` maps both spellings and the cache is keyed by standardized path,
  never `URL` — a miss makes an existing file look new and counts it twice. Directory create/move/
  remove and dropped-event flags force a full walk; `tick()` walks every 5 min as the watchdog.
- **`ScanDelta.appended` is merged in place** by `UsageScanner.mergeAppended`. That only works because
  `lastEntries` is `@ObservationIgnored` (observed properties mutate through accessors that leave the
  buffer shared → a silent 15 MB COW copy per scan) and the actor never retains the array it hands
  out. Anything that removes or replaces a delivered entry — re-parse from zero, a dropped
  `tailCount`, a deletion, a mode flip, a repeat *earlier* than the kept copy — must return `.full`.
  `DeltaScanTests` churns randomly against cold scans; each of those guards was mutation-checked.
- **`tick()` skips the recompute** unless `recomputeIsDue`: new entries, a side file's mtime, or
  `nextRecomputeDeadline` (next hour, session end/expiry, week/cycle end, server resets, statusline
  staleness). **A new clock-driven figure must add its boundary to `computeNextDeadline`**, or it
  updates up to an hour late — the hourly floor bounds the damage, it doesn't remove it.
- **`PriceResolver`: build one per loop.** `PricingTable.cost(for:)` still exists but builds a fresh
  resolver per call — fine once, the old hot spot again inside a history loop.

Cold scan is ~10 s now (`/usr/bin/time` on the snapshot path, 5.8 GB) — the corpus grew 2.5×, not the code.

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

**Codex counts cache the opposite way round, and its row sits directly under the Claude gauges.**
Codex's `input_tokens` is **gross** — `cached_input_tokens` is a *subset* of it — where Anthropic's
excludes cache and reports `cache_read_input_tokens` separately. So the rollouts' `total_tokens` is
exactly `input_tokens + output_tokens` (295 of 295 records over a real week, no exceptions) and is
**cache-inclusive**: measured, 93.6% of it was cache reads, 28.2M against a work-equivalent 2.0M.
Shipped as-is the row read **7× the Claude weekly figure while actually being under half of it**.
`~/.claude/codex-week-tokens.py` therefore differences a derived cumulative,
`input_tokens - cached_input_tokens + output_tokens`, and the fifth TSV field means work tokens. Two
consequences: the app must **not** route that field through `TokenBasis` (it is already and always
cache-excluded), and `CodexLimitBar` spells "work" out literally rather than using
`tokenBasisLabel`, so that under `.total` the Claude row above names a different unit instead of
inviting a comparison it can't support. The statusline and the app are coupled through that field's
meaning — change one and the other mislabels silently.

**The app now computes that figure itself too.** `CodexRolloutReader` ports both `codex_usage` and
`codex-week-tokens.py` and reads `~/.codex/sessions` directly, because the cache lives in `/tmp` —
emptied on every restart — and only a terminal statusline rewrites it (the desktop app's Code tab
never renders one), so after a reboot the Codex row stayed blank for as long as no terminal was open.
Rollouts win when they yield a reading; the TSV is the fallback and what `CLAUDEPET_CODEX` fakes. The
two implementations must keep agreeing: they matched to the token at six window starts over the whole
331 MB corpus, and a change to either algorithm needs that comparison re-run
(`python3 ~/.claude/codex-week-tokens.py <start>` against `CodexRolloutReader.tokensUsed(since:)`).
`MetricsStore` maps a window whose `resetsAt` has passed through `CodexLimit.asReset()` (0%, no token
count, `hasReset`) — it read 4% for a window that had ended 68 hours earlier. Don't drop it instead:
that was tried, and the session row vanishing read as a missing feature.

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

**`calendarWeek`/`calendarWeekDaily` are a second, deliberately independent pair** — a fixed
Sunday-00:00-to-Sunday-00:00 calendar week, read only by `WeeklyBarChart` and `SubagentShareChart`.
They exist because viewing the fold-back window described above on its own reset weekday, before the
reset instant, shows *last* week's Tue–Fri under labels that read as "future days already have
usage" — real data, correctly counted, but confusing. A midnight-aligned boundary can't split a day,
so there's nothing to fold: unlike `weekDaily`, `calendarWeekDaily` needs no `% 7` and no "no window"
fallback branch (`now`/`calendar` are always enough). `isCurrentDayBucket` still works unmodified
here, not by luck — a Sun–Sat calendar week's 7 buckets are, by construction, 7 *distinct* weekdays,
so weekday-matching and date-matching coincide.

**Built from `calendar.date(byAdding: .day:)`, never from `WeeklyWindowEngine`.** That engine steps a
fixed 7×24h in raw *seconds* from an epoch anchor (its own doc comment admits it "may drift ±1h
across a DST change"), which is tolerated for the rate-limit window — an approximation recalibrated
against the server anyway — but would silently exclude up to an hour of entries near the Sunday
boundary from every bucket here, for roughly half of every year in a DST zone. Calendar-day
arithmetic absorbs DST by construction; don't "simplify" this back to a `WeeklyWindowEngine` call.

The weekly gauge, its countdown, and the "Week" footer figure stay on the rate-limit window,
untouched. Two independent aggregates, same as `week` vs `cycle`.

**The pace bars split down the middle, and it matters which half moved.** `dailyTodayValue`/
`subagentTodayValue` — today's own reading, e.g. the "Today: 2M" line in `DailyPaceView` — read
`calendarWeekDaily`, same reason as the two charts: on the reset weekday, before the reset instant,
`weekDaily`'s folded bucket combined last week's post-reset evening with today's own usage. Measured
live on a real Monday: 1,612,803 (last Monday's tail) + 432,336 (this Monday, actual) read as
"2,045,139 today." See `Tests/ClaudePetCoreTests/CalendarWeekTests.swift`'s
`todayValueDoesNotFoldLastWeeksPostResetTailIntoTodaysFigure` for the reproduction.

`dailyAverage`/`subagentDailyAverage` — the "N/day avg" baseline — then moved **separately and for a
different reason**, to `allTimeDaily` windowed to the last `MetricsStore.dailyBaselineDays` (30)
active days. On `weekDaily` a weekly reset emptied every prior bucket, so for the rest of reset day
there were no priors at all and the bar read "building daily average…" beside a perfectly correct
figure — reported live an hour after a Monday 15:00 reset, and recurring weekly. Rolling rather than
all-time so the baseline follows current habits: all-time read 3.11M against the window's 3.53M, and
that gap only widens as history accumulates. **Three series, three reasons; none is a substitute for
another, and what keeps them consistent is that all are whole calendar days, not that they share an
array.** `weekDaily` now has no reader outside `Aggregator`.

Two traps here, both silent, both pinned by `DailyBaselineTests`:

- **Exclude today by DATE, never with `isCurrentDayBucket`.** That helper matches on *weekday*, which
  is right for a 7-slot week (7 slots are 7 distinct weekdays) and wrong over a long series, where it
  drops every same-weekday day instead of one. On the real corpus it discarded 4 extra days and moved
  the mean +4.8% — and since the number of same-weekday days shifts with the calendar, the error
  wandered −6.6%…+3.5% by nothing but which day you looked at.
- **Filter `> 0` before `.suffix`, not after.** The window is "the last 30 days that had usage", not
  "the last 30 slots, some empty". It also means the two baselines legitimately span different dates —
  measured live, 07-01…08-01 for work against 06-28…07-31 for subagents — because a day that ran turns
  and delegated none must not consume a subagent slot.

`allTimeDaily` itself is the one series here with **no pre-built grid** (its span isn't known until the
entries are read) and **active days only** (a day you didn't work is not evidence about a usual day).
It is built oldest-first, and that ordering is a contract, not incidental — `.suffix` depends on it.

**The loop that fills it made `Aggregator.compute` cheaper, not dearer** — it caches one `startOfDay`
per day instead of per entry, and that cached key also replaced the per-entry
`calendar.isDate(_:inSameDayAs:)` the "today" branch used to call. Measured end to end, 21 runs on
127k real entries, p50: **275.5 ms before the series existed, 345.3 ms with it added naively, 233.9 ms
as shipped.** `recompute()` is on the main actor on a 30s timer, so the naive +70 ms was not payable.

**Benchmark the whole function, not the Calendar calls in isolation.** A microbenchmark of
`isDate(_:inSameDayAs:)` over 126k synthetic dates said 79 ms, which suggested the substitution alone
would nearly pay for the feature; against the real loop the true saving was ~42 ms net. The isolated
figure was not wrong, it was measuring something else — and quoting it as the end-to-end result
overstated the win by an order of magnitude before an A/B on the real corpus caught it. Also: a
`git stash` of one file here reverts *all* its uncommitted work, which silently produced a
"before" binary identical to the "after" one; verify the build actually changed before trusting a
comparison.

The cache assumes ascending input for *speed* only — `LogScanner`
sorts, which makes the sort load-bearing for performance as well as dedup determinism — but an
out-of-order entry just misses and recomputes, so results are identical for any ordering
(`dayKeyCacheIsCorrectForUnsortedEntries`). Step it with `calendar.date(byAdding: .day:)`, never
`+86_400`; same DST rule as the calendar week.

### Pricing

`PricingTable` is user-editable and persisted. `defaultOverrides` handles version-specific rates
(Opus 4.1 $15/$75; Opus 5.5 $4/$20 with cache reads 0.05×; Fable/Mythos 5.1 cache reads 0.025×;
Sonnet 5/5.5 $2/$10) and is **first-match-wins**, so a specific id goes before any id it contains.
Cache-read multipliers matter more than headline rates — cache reads are ~97% of tokens.
`mergingMissingDefaults()` adds new families *and* new overrides to a saved table, and swaps a saved
override only if it equals an entry in `retiredDefaultOverrides` (our stale default, not a user edit).
`throughDate` is read on a **Gregorian** calendar — on `Calendar.current` (Buddhist here) every dated
override had lapsed in 1483, and the test helper shared the bug, so it passed. Costs are *notional* API-equivalent — the user is
likely on a subscription.

### Mascot & weather

**The mascot block carries two numbers, on three layers.** The pet and its sky are the **5h session**;
the ground under its feet is the **week**:

- `MetricsStore.mascotEmotion` reads `blockFraction` **alone**, and `WeatherCondition.from(emotion)`
  derives the sky from it — so face and weather can never disagree, and the whole scene means one
  thing. It used to read `max(5h, weekly)`, which meant a stormy pet could be caused by either limit
  with no way to tell which. Don't fold weekly back in; that makes the ground redundant and the face
  ambiguous again (`MascotEmotionTests` pins both directions).
- `GroundCondition` is the weekly fraction as terrain, drawn from `GroundArt` into its own matrix.
  Terrain suits the slower clock: a session resets several times a day, a week once.

Ground and mascot share the **same 16×16 lattice in the same `pet × pet` frame**, so their rows line up
exactly — that is what lets them be separate matrices. The pet's art ends at **row 11** (feet), so
ground owns rows 11 and below and the two can never overlap, and neither has to know about the other.
Row 12 is the surface the feet land on and must never be empty; an empty cell there is a hole, and the
pet reads as levitating over a floating slab. Weather is **not** on that lattice — it is 16×22 in a
taller `pet × sky` frame, deliberately, so the sky sits above the pet; its cell size can therefore
differ from the mascot's. `GroundView` has no `TimelineView`: ground doesn't move.

Adding a mood or a ground state is cheap — the art is parametric (`Eyes × Arms × Accent`) — and that
is exactly the trap. Two states can easily compose to the *same drawing*: the enum then has nine cases,
every test passes, and the user sees seven. `ArtDistinctnessTests` enforces a measured floor of 6
differing pixels; it caught seven collisions the first time it ran, three of them newly introduced.
Render `CLAUDEPET_MASCOT` and look, too — it lays every mood, sky and ground out in rows, with the pet
composited over the ground so a stray pixel in the feet is obvious.

One-shot moments (`WeatherEvent.confetti`, `.lightningStrike`) are edge-detected in
`detectWeatherEdges()` at the end of each `recompute()`, queued, and drained once by `ContentView`;
nothing fires on the first pass after launch.

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

### Claude Code's /stats figures

**`MetricsStore.stats` is what `/stats` would print right now: the cache plus a live fold-in.**
`~/.claude/stats-cache.json` is written **only when the `/stats` dialog is opened** — nothing else
refreshes it (confirmed in Claude Code's bundle: `Stats cache saved successfully` is logged from the
dialog's load path). It sat at 17 Sep through 34 days of daily use. Claude Code never shows that stale
file itself: on open it folds every day after `lastComputedDate` in from the transcripts, then adds
today. `StatsReplica` does the same, and `StatsSnapshot.merge` joins the two the way Claude Code's own
merge (`Yd`) does.

**It is an exact port, not an estimate — and an earlier version of this file said it couldn't be done.**
"Don't try to recompute it; every rule lands 3–7% off" was true of every rule tried then. The two that
were missing: **a transcript over 100 MiB is read from its last 100 MiB only** (dropping the first
partial line), and **days are UTC** (`toISOString()`), not local. With those, validated by opening
`/stats` against a backed-up 17 Sep cache: **30 of 30 days matched exactly** on messages, sessions and
per-model tokens, and the whole span to the unit — 479 sessions, 110,720 messages, 54,093,080 tokens.
Leaving out the tail rule alone made the delta **12.7% high**. The full rule list is on `StatsReplica`;
each one is pinned by `StatsReplicaTests`, and the tail and sidechain rules were mutation-checked.

**Re-validate after a Claude Code update that touches `/stats`.** The port follows v2.1.303. Copy the
cache, open `/stats` in a terminal, and compare the difference between the two copies against
`CLAUDEPET_STATSDELTA=<first day after the old copy's lastComputedDate>` — it must match except for
today, which the new cache doesn't hold yet. Find the rules in the bundle with
`strings $(which claude)` around `stats-cache.json` (`Fo` is the aggregation, `tSt` the tail reader).

Note what this means for ClaudePet's own accounting: `/stats` does **no dedup** (every repeated log line
counts) and never counts `subagents/workflows/` agents. The panel follows `/stats`; every other figure on
the dashboard is ClaudePet's own. Don't "fix" either toward the other.

**Claude Code prints two different figures under "Total tokens", ~200× apart.** Its terminal `/stats`
shows `in + out + cache read + cache write` (87.6b on 21 Oct, of which cache reads were 85.0b); its
desktop app shows `in + out` (287.4M). ClaudePet follows the app. "ClaudePet says 287M, /stats says 87.6b"
is two definitions, not a discrepancy.

Cost, measured: the cold fold-in over a 34-day-stale cache read 5.2 s / **136 MB peak**; today alone is
0.8 s / 50 MB. Refreshes are incremental (an append parses only the new lines) and at most one per
`MetricsStore.statsRefreshInterval` (60 s), except that a file **over** 100 MiB is re-read whole — its
window slides as it grows. That interval is the CPU dial. Don't read the per-file chunks in a `while`
condition: `readData` autoreleases, and outside the pool all 2,223 chunks stayed live — a 3.8 GB peak.

**The desktop app's Code tab `/stats` is a different figure — don't chase it.** It runs Claude Code's
"storageV5" mode (its own bundled CLI, e.g. 2.1.304 under `~/Library/Application Support/Claude/claude-code/`),
which keeps its stats cache in the app's state store, **not** `~/.claude/stats-cache.json`, and lists
transcripts through that store. Measured 21 Oct: 507 sessions, 93/136 days, 2.4M in / 51.9M out, against
the terminal's 1,249 / 146/167 / 288M. Its session count and span match `/stats`' rules applied to
**only the transcripts still on disk** (510 sessions, first day 8 Jun, peak hour 16:00), so it has lost
everything Claude Code already cleaned up; its token totals matched no file-based rule tried (closest
2.4M / 45.2M, no tail cap + dedup), so it also reads different content. The aggregation code itself is
identical in both builds. ClaudePet mirrors the terminal `/stats` — the one with full history.

**The one thing ClaudePet can't fix is a cache older than `cleanupPeriodDays` (30 by default).** Claude
Code deletes old transcripts, so days it hasn't folded in by then drop out of `/stats` for good — and out
of this panel, which mirrors it. When the 17 Sep cache was refreshed on 21 Oct, 18–20 Sep were already
partly gone. Past 21 days the panel's `/stats` tag turns into an amber "open /stats · Nd".

Traps:

- **`costUSD` is present and always 0.** `PricingTable` remains the source for every `$`.
- **`lastComputedDate` is a bare `"2026-10-20"` — a UTC date.** Convert with `StatsDay` (pure
  arithmetic), never `Calendar.current`: under the Thai Buddhist calendar today's `year` is **2569**,
  and a comparison against it once silently stopped the live figures from ever updating.
- **A delta is only valid against the watermark it was computed for** (`StatsDelta.fromDay`). When
  `/stats` is opened, the cache absorbs the delta's days; `merge` drops the old delta rather than count
  them twice, and the panel is briefly the bare cache until the next fold-in lands.
- **"Longest session" is by wall-clock duration** (28d 22h here), as `/stats` picks it, not by messages.

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

`allTimeByProject` is the lifetime twin of `cycleByProject` and is accumulated **outside** the in-cycle
predicate, in its own dictionary, rather than by relaxing that predicate — 24 assertions pin what
`cycleByProject` means, including that it sums exactly to `cycle`. Two series, two invariants: each
sums to its own total. `ProjectBreakdownView` reads the lifetime one; its header and its empty state
both have to say so, or the card silently reports the wrong span.

`DayTotal` carries `sidechainWorkTokens`/`sidechainTotalTokens` as well, accumulated in **both** bucket
loops, so the subagent slice is available per day and not just per window. Same rule as everything else
here: Σ over the weekly window's buckets equals `week.sidechainWorkTokens` exactly.

**Two charts of the same buckets must not be the same mark.** `WeeklyBarChart` and the subagent slice
were briefly one view with a `Series` enum, drawn side by side. Each instance normalises to its own
`maxV`, so the subagent bar stood exactly as tall as the total bar while being ~6× smaller — the
comparison the eye makes is the one identical marks invite. `SubagentShareChart` draws a *share* on a
fixed 0…100% axis instead, which has no free maximum to misread. Note what it does **not** use: the
gauge ramp, because every ramped bar in this app means "close to a limit" and a heavy-delegation day
is not a warning (same reasoning as `SubagentPaceView`). `daySidechainShare` is clamped where the other
`sidechainShare` overloads aren't — those feed a tooltip, this one is a bar height.

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

Two traps in the shared UI layer, both measured, both easy to reintroduce:

- **Never `.opacity(…)` a `Theme` text colour — it compounds.** `Theme.textSecondary` is already white
  at 0.70, so `.opacity(0.6)` on it is 0.42 absolute, not 0.6. In code that reads as "slightly
  dimmer"; on screen it is 4.0:1 against the near-black card, under the 4.5:1 AA floor. Seventeen call
  sites had drifted this way, five of them to 2.3:1. Use `textPrimary` / `textSecondary` /
  `textTertiary` / `textFaint`, which carry their measured ratios in comments. Check contrast by
  sampling the **rendered pixels** — source review is what let this through in the first place.
- **A calendar can't fill an arbitrary rectangle.** Its aspect ratio is fixed by its shape, so square
cells are capped by whichever axis is scarcer — always height here. Two attempts failed before the
right one: square cells in a fixed-fraction column left 84px dead a side, and letting cells go wide
(a 2.6:1 cap) filled the card but stopped reading as a calendar. The cells are square and the **column
is sized from the row height** instead (see `CycleCalendarView.naturalWidth`, capped at 40% of the row
so a short top row can't let the calendar starve its neighbours — at 40% that cap is a backstop that
binds at **no** tested size, measured 339 against 350 at the 900×800 minimum and 270 against 785 at
1990×820; it earns its place only because `naturalWidth` did once ask for 51%. Tune it at 900×800, the
one size where it ever bound, and confirm the others are byte-identical), which is also why the
lower row is wrapped in its own `GeometryReader` — the column split can't be computed until that row's
height is known. Its header stacks onto two lines for the same reason: on one line it needed ~420pt and
*it*, not the grid, set the card's minimum width.

`refHeight` must be **≥ the height the layout needs at scale 1**, and getting it wrong doesn't degrade
gracefully — it breaks at every size. When height binds, scale is `height/refHeight`, so required
height is `need × height/refHeight`, which exceeds the window at *any* height once `refHeight < need`.
Since height binds at every realistic window size, `refHeight` is also the **type-size dial**: text
can only grow if the layout needs less room. That's the whole reason the dashboard's mascot is 122pt
of sky rather than the widget's proportions — and if the text still needs to be bigger, the next
lever is `ProjectBreakdownView.maxRows`, not the scale clamp.

Two traps in the lower-left 2×2 of cards, both of which render happily and are wrong:

- **A width gate must name the view, not the position.** `chartW >= 350 * scale` used to hide "the
  second panel in the HStack". When Subagents/day and This week swapped places, a literal port hid the
  *primary* chart at the minimum window size and kept the subagent one — nothing errors, the layout
  still fills, and only looking at a 900×800 render catches it.
- **`.frame(width:)` does not clip.** The two weekday cards are pinned to an exact half because both
  asking for `maxWidth: .infinity` still lets SwiftUI weigh their *ideal* widths — three `fixedSize`
  runs in one header against two in the other split a column 354/229. But pinning then made the
  oversized header centre and draw the title clean off the left edge of the **window**. Any header
  built from `fixedSize` text in a pinned card needs `ViewThatFits` (see `SubagentShareChart.header`,
  and `CycleCalendarView.legend` before it), dropping a whole element rather than clipping one.

Two more from the `/stats` card's tile ledger, both of which rendered without error:

- **A `fixedSize` child raises its container's minimum width, and the dashboard honours minimums by
  running off the window.** Pinning tiles to their natural width fixed a shrunken label and pushed the
  whole right card past the window edge at 900×800; `ViewThatFits` never fell back, because the width
  it measured against was not yet fixed. `StatsKPIGrid`'s `LedgerLayout` is the pattern that works:
  report the proposed width as your own, then size columns to content *inside* it.
- **`ViewThatFits` uses its LAST child when none fit — so the last child must always fit.** The
  billing card's date fell back to a fixed-size two-liner in a squeezed column and pushed the card into
  its neighbours (their dollar figures clipped at 1990×820). End with an empty option when dropping the
  content is acceptable. The two `fixedSize` traps here are one trap: a fixed size is a minimum width.
- **A "capped" `Spacer` between stack rows is not capped.** It brings a second stack gap with it, so
  `Spacer().frame(maxHeight: 6)` between rows grew them from 53px to 80px apart at 1990 wide.

**Nothing looks tight before it clips**, so "does it still fit?" cannot be answered by looking. Every
gauge and chart in the top row stretches, and the lower row absorbs whatever the top row takes until it
hits its own minimum — at which point the bottom card runs straight off the window edge with no warning
anywhere above it. Measure the bottom-most **card** pixel against the window edge, not the bottom-most
text, and do it at **1990×820**: that is the only tested size where the boosts run at full strength
(they key off width) while height is tight, and it clipped there while every other size still had 10px+
to spare. Adding a row to the *taller* top card is what triggers this, and which card is taller changes
— re-measure rather than trusting a comment that says one of them has slack.

Exactly one row stretches — the cycle chart, whose bars fill the height they're given. The others stay
snug around their content. Stretching every row instead just moved the slack inside the cards (~180pt
of dead air beside the mascot), which reads as unfinished; growing the one panel worth looking at
large is what actually uses a big display. Related: the top row is split ~46/54, not evenly, because
the left card's gauges are full-width bars that reflow into any width while the right card holds
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

**`ingestForTesting` bypasses the scanner, so it cannot cover the wiring.** Every `MetricsStore` test
used it, which left `refresh()`'s single `deduplicated:` argument unprotected: inverting it triples
every figure in the app and the whole suite stayed green. `MetricsStore(scannerRoot:)` exists purely so
`ScannerWiringTests` can drive the real on-disk path — and that test earns its place only because it
was checked by deliberately inverting the flag and watching it fail. **A test for a silent defect is
worth nothing until you have seen it fail**; the defect it guards produces figures that stay
internally consistent (the Auto budget anchors inflate alongside the usage they're fitted to) and are
simply all wrong together.

**Comments explain *why*, never *what*** — a non-obvious constraint, a workaround, an invariant a
future reader could break. `MetricsStore.swift` is representative. Group with `// MARK: -`.

**Prefer extending an existing pattern** over inventing a new one — a new window engine follows
`WeeklyWindowEngine`'s shape, a new display toggle follows `TokenBasis`'s.

## Version bumps

The version lives in three hand-maintained places and `release.sh` refuses to build if they disagree:
`Sources/ClaudePetCore/ClaudePetCore.swift`, `Sources/ClaudePet/Supporting/Info.plist`
(`CFBundleShortVersionString`), and the top dated heading in `CHANGELOG.md`. Ordinary changes just
go under `## [Unreleased]`. Shipping one is the user-only `/release` skill (`.claude/skills/release`):
it bumps all three plus `CFBundleVersion`, and publishes that version's CHANGELOG section as the notes.

## frontend/

A self-contained HTML mirror of the widget for claude.ai/design (`/design-sync` skill). Each file's
first line is a `<!-- @dsCard group="..." -->` marker; each inlines the same `:root` tokens so it
renders with zero external requests. It's generated output — the mascot SVGs come from the same
pixel logic as `MascotArt.swift`, so changing the mascot means regenerating rather than hand-editing.

## Agent skills

### Issue tracker

Issues live as GitHub issues in `jjnnaappaatt/ClaudePet`, driven through the `gh` CLI.
See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, unrenamed: `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `GLOSSARY.md` and `docs/adr/` at the repo root, created lazily rather than
scaffolded. See `docs/agents/domain.md`.

## Subagents in the feature loop
poteto-agent writes the code. Repo agents join at fixed points:
- review: after verify and before `gh pr create`, and in /jjstack:doublej. Sort what it finds by Ticket scope in Feature loop.
- spec: during /jjstack:jjflow, ask it the domain-fact questions the grill needs.
- verify: run it during verify, next to the verify skill.

| Agent | Role | Covers |
|---|---|---|
| claudepet-figures-reviewer | review, spec | `Sources/ClaudePetCore`: parse/scan/dedup/aggregate, gauge budgets and calibration, pricing, /stats replica, Codex reader, memory and CPU invariants |
| claudepet-ui-reviewer | review, spec | `Sources/ClaudePet`: SwiftUI widget and dashboard layout, Theme contrast, mascot art, AppKit panel and window behaviour |
| claudepet-verifier | verify | the `verify-claudepet` skill: isolated bundle, real-data renders, panel-fit and dashboard flows, `swift test` |

## Learning loop
After /jjstack:doublej, and whenever I correct an agent (a ticket session does not reflect: doublej sees what its review caught):
1. Read and follow pstack's `reflect` skill on this session's transcript.
2. Route a lesson about a repo agent's domain to that agent's memory in `.claude/agent-memory/<agent>/`.
   Edit the agent file itself only when its role or scope changes.
3. Prune as you add: read the whole file a lesson lands in and cut, in the same edit, lines it replaces
   or contradicts, repeats, and lines stale against the code. Show the Accepted additions and cuts together
   and wait for my approval before changing any file.
4. Ship approved edits through review as one small `chore(agents): <lesson>` PR cut from origin/main, never on a ticket branch:
   lessons on parallel ticket branches collide in the same `.claude/**` files. A lesson whose file an open PR also edits waits for that PR to merge.
A mistake made twice goes to /pstack:correct instead, which enforces it in the code.

## Feature loop
1. /jjstack:jjflow <idea>: grill, spec issue, tickets
2. Per ticket, new session: /pstack:poteto-mode implement #<ticket>
3. After the round's PRs are open: /jjstack:doublej #<spec>
4. Merge only what you pick in /jjstack:doublej
Ticket scope: one ticket, one PR. Fix in that PR only what fails today against the ticket's acceptance criteria or a repo invariant. Hardening, a risk from some later edit, and any other finding, from any reviewer, go into one `needs-triage` issue that links the ticket, listed in the PR body; they wait for the next /jjstack:jjflow. A new session or PR starts only when I ask for one. A bug outside the ticket that cannot wait comes to me as a question, with its issue already filed. Judge "cannot wait" by naming every live path the bug or finding breaks, and whether it bites before the next /jjstack:jjflow round or a fixed field date. A broken sign-in, claim or token link always cannot wait.
Lessons: see Learning loop. Repeated mistakes: /pstack:correct

Verification: `.claude/skills/verify-claudepet/` drives the app headlessly (see its SKILL.md). Never verify with
`./bundle.sh` — it deletes the `ClaudePet.app` the user is usually running. `.claude/hooks/guard.sh` asks before
`bundle.sh`/`release.sh` run while that app is up, and denies writes to the live `/tmp/claude` caches. No setup step is postponed.
