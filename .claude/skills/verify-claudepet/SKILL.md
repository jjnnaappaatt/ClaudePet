---
name: verify-claudepet
description: Drive the ClaudePet macOS widget and dashboard the way a user sees them, headlessly — build an isolated bundle, render the widget/dashboard/settings to PNG, check panel sizing and the dashboard's full-screen flow, and dump live metrics. Use to prove a UI or data change works in the real app (not just `swift test`), before claiming a ClaudePet change is done.
---

# Verify ClaudePet

ClaudePet is a dockless SwiftUI/AppKit menu-bar widget plus a dashboard window. There is no
browser or CLI surface: an agent drives it through launch-time `CLAUDEPET_*` env vars that
`Sources/ClaudePet/App/AppDelegate.swift` reads, which render a view to PNG or run the real
window flow and print `diag:` lines, then exit. No screen-recording permission is needed.

All commands go through one helper. Run from the repo root:

```bash
S=.claude/skills/verify-claudepet/scripts/verify.sh
```

## Isolation — read first

- **Never run `./bundle.sh` to verify.** It `rm -rf`s `./ClaudePet.app`, which is usually the
  copy the user is running right now. The helper builds to `.build/verify/ClaudePet.app` instead.
- The verify bundle has the **same bundle id** (`com.napat.ClaudePet`), so it reads the user's real
  preferences. That is what makes `CLAUDEPET_REAL=1` renders faithful. The snapshot paths never save
  prefs; the window-flow paths (`PANELFIT`, `OPENDASHBOARD`, `OPENSETTINGS`) run the normal app and
  briefly put a second widget on screen. Don't drag or resize it.
- Never kill the user's widget, and never `pkill`/`killall`. `doctor` prints the user's pid so you
  can tell the two apart. The helper kills only pids it recorded.

## Launch

```bash
$S build      # swift build (debug) + assemble + ad-hoc sign; ~10 s warm
```

Ready means the build ends `built …/.build/verify/ClaudePet.app (<config>, <rev>)`. `VERIFY_CONFIG=release $S build`
gives a release bundle for performance numbers (see the `measure-claudepet` skill). `doctor` prints which config is built. Every drive is a short
process: `run` starts it, waits for it to exit (it exits on its own after rendering or reporting),
and kills it at `VERIFY_TIMEOUT` (200 s by default).

## Doctor

```bash
$S doctor
```

This check is read-only. It requires a bundle, the version, a rev that matches HEAD, and no
`Sources/**/*.swift` newer than the binary. A `FAIL stale` line means rebuild before trusting
anything. Run it first, and again whenever a render looks off.

## Drive

```bash
VERIFY_RUN_ID=<name> $S run <label> KEY=VALUE ...
```

`@ART@` in a value expands to the run's artifact dir. The log holds the exact command, the rev, the
stdout and stderr (`snapshot: wrote …`, `diag: …`) and `# exit: N`. The recipes per feature are in
[`features/README.md`](features/README.md). The handles:

| Env var | Effect |
|---|---|
| `CLAUDEPET_SNAPSHOT=@ART@/w.png` | widget PNG, sample data |
| `CLAUDEPET_DASHBOARD=@ART@/d.png` + `CLAUDEPET_DASHSIZE=WxH` | dashboard PNG at an explicit size |
| `CLAUDEPET_SETTINGS=@ART@/s.png` | Settings PNG |
| `CLAUDEPET_MASCOT=@ART@/m.png` | every mood, sky and ground frame |
| `CLAUDEPET_REAL=1` | real `~/.claude` data instead of sample (with SNAPSHOT/DASHBOARD) |
| `CLAUDEPET_LAYOUT`, `CLAUDEPET_SCALE`, `CLAUDEPET_BASIS`, `CLAUDEPET_UTIL`, `CLAUDEPET_CODEX`, `CLAUDEPET_DEVICE`, `CLAUDEPET_HANDLES`, `CLAUDEPET_NOLIVE` | force a state; see CLAUDE.md "Headless UI verification" |
| `CLAUDEPET_PANELFIT=1` | real widget flow; `OK` or `FAIL: panel is Npt off its content` |
| `CLAUDEPET_OPENDASHBOARD=1` | real expand-button flow; full screen, ⌃⌘F, min size, widget hide/restore |
| `CLAUDEPET_OPENSETTINGS=1` | real gear flow; activation, key window, first responder |
| `CLAUDEPET_HEARTBEAT=@ART@/hb.json` | normal app; metrics JSON per recompute (no auto-exit: use a short `VERIFY_TIMEOUT`) |
| `CLAUDEPET_STATSDELTA=YYYY-MM-DD` | prints the /stats fold-in JSON and exits |

To look at a PNG, `Read` it. Renders are not pixel-reproducible between runs (the clock, live
thermals, Codex), so compare layout and figures, not bytes.

## Evidence

The artifacts go to `.verify-artifacts/<VERIFY_RUN_ID>/`, which is gitignored and never deleted by
cleanup. A proof is:

- the `.log` (command, rev, `diag:` or `snapshot:` lines, exit code) plus the PNG you read, for UI;
- **real data** (`CLAUDEPET_REAL=1`) whenever the change touches figures. Sample data is hand-written,
  bypasses the pipeline, and proves layout only;
- the dashboard at its **minimum** `900x800` and at `1990x820` with `CLAUDEPET_REAL=1`, for any layout
  change (CLAUDE.md explains why these two sizes);
- `CLAUDEPET_PANELFIT=1` → `OK` after anything that changes the widget's height.

`swift test` is the proof for Core logic, and this skill doesn't replace it. This skill proves what
the user sees.

## Cleanup

```bash
$S cleanup    # kills only pids this helper started; artifacts stay
```

Run it after every failed or timed-out drive as well. The artifacts survive in `.verify-artifacts/`.
The `.build/verify` bundle is a cache: leave it.
