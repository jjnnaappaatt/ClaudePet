---
name: measure-claudepet
description: Measure ClaudePet's memory footprint, cold-scan time and steady-state CPU the way CLAUDE.md prescribes (vmmap peak footprint, heap live set, sample split by thread), with the binary hash, build config, uptime, corpus size and machine load recorded so two runs can actually be compared. Use before and after any change that claims a memory or CPU win, or when the widget seems heavy.
---

# Measure ClaudePet

CLAUDE.md's "Data pipeline" and "CPU" sections record every number this app has been tuned against.
They also record five ways those numbers were misread. This skill turns the method into one script,
so that a "before" and an "after" are measured the same way.

```bash
V=.claude/skills/verify-claudepet/scripts/verify.sh
M=.claude/skills/measure-claudepet/scripts/measure.py
```

## Build what you measure

```bash
VERIFY_CONFIG=release $V build && $V doctor     # doctor must print config: release
```

A debug build scans roughly 2× slower than release. On 28 Oct 2026 the cold scan of a 4.3 GB corpus
took 16.6–18.0 s wall and 12.4–13.7 s user CPU in debug, against 7.6–9.9 s wall and 6.5–6.6 s user
in release. Peak footprint was 128–139 MB in debug and 161 MB in release. **Never compare across configs.** `summary.json` records
`config`. The user's own `./ClaudePet.app` reads `config: unknown`, because `bundle.sh` defaults to
debug.

For an A/B, build each side and check that the `sha256_16` values differ before trusting the delta.
A `git stash` of one file once reverted all the uncommitted work and produced an identical "before"
binary.

## Modes

| Command | Measures | Time |
|---|---|---|
| `python3 -I $M cold --runs 3` | Cold scan of real data via the snapshot path under `/usr/bin/time -l`: wall clock, user CPU, **peak memory footprint**, as a range | ~10–18 s per run |
| `python3 -I $M launch --duration 300 --interval 30 [--heap] [--sample 5]` | Runs the verify bundle as the normal app. Records footprint and peak per interval with uptime, then optionally the live set and a per-thread CPU split. Kills only its own pid. | `--duration` |
| `python3 -I $M attach live\|<pid> [--samples 5 --interval 10] [--heap] [--sample 5]` | Read-only sampling of a process that is already running (`live` = the user's widget) | samples × interval |

`launch` puts a second widget on screen for the whole duration, so don't touch it. `attach live` is
read-only, but `heap` and `sample` briefly suspend the target. That's fine for the user's widget,
but don't loop it.

Output goes to `.verify-artifacts/measure-<VERIFY_RUN_ID>-<mode>/`: `summary.json` plus the raw
`vmmap-*.txt`, `heap.txt` and `sample.txt`, kept for re-reading. Set `VERIFY_RUN_ID` to name a run
(`before`, `after`).

## Reading the numbers (CLAUDE.md's traps, enforced or flagged)

- **Peak, not RSS.** RSS counts clean resident pages and once read 709 MB against a 181 MB
  footprint. `cold` reports both only so the gap is visible. Quote `peak_footprint_mb`.
- **Ranges, not single samples.** Footprint swings 123–527 MB at the same uptime, depending on where
  the scan cycle is, and FSEvents re-peaks on every transcript write. Every figure here is a
  `[min, max]`. A delta smaller than the overlap of the two ranges is noise.
- **Same age or no comparison.** An idle process sheds hundreds of MB, so a 17-minute "before"
  against a 1-minute "after" measures the clock. Each sample carries `uptime_s`. Compare rows of
  matching uptime.
- **Live set settles leak arguments.** If `heap.live_mb` is far below the footprint, the difference
  is malloc keeping freed `(empty)` arenas, not a leak. That signature means a chunked read outside
  its `autoreleasepool` (CLAUDE.md, "The cold scan's peak").
- **Split CPU by thread before naming a hot spot.** `cpu.threads` gives `on_cpu` versus `blocked`
  (leaf in `mach_msg2_trap`, `__workq_kernreturn` and similar) per thread. A main thread that is
  mostly blocked means the cost is elsewhere, usually the scanner's cooperative queue. That is how
  the mascot was wrongly blamed once. `top_of_stack` is `sample`'s own leaf summary.
- **Corpus and load go with every number.** `corpus_mb` (the size of `~/.claude/projects`) grows
  daily: the cold scan went from ~3 s to ~10 s because the corpus grew 2.5×, not because the code
  got slower. `load_1m` above 70% of cores adds a `warning`, and timings with that warning are
  not comparable.

## Cleanup

`launch` stops its own process even when it fails. If a run is interrupted, `$V cleanup` kills
any pid these helpers recorded. Artifacts are never deleted.
