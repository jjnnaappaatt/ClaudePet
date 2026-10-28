# ClaudePet verification map

This map is the maintained source for verifying what a ClaudePet user sees. Read this index before
you drive anything, then use the matching feature file as the recipe.

## Baseline preconditions

- `$S` is `.claude/skills/verify-claudepet/scripts/verify.sh`, and you run it from the repo root.
- `$S build` has run since the last source change, and `$S doctor` prints `doctor: OK`.
- Every drive sets a fresh `VERIFY_RUN_ID` so the artifacts don't mix.
- Never drive the user's own `./ClaudePet.app`. `doctor` prints its pid.

## Driving conventions

- Every drive is one `$S run <label> KEY=VALUE…` that exits on its own. Read its log, not the terminal.
- A state is forced with env vars, never by editing prefs or `/tmp/claude/*`.
- Use `CLAUDEPET_REAL=1` for any claim about figures. Sample data proves layout only.

## Proof and skip reporting

- Every artifact is named after its feature ID: `$S run widget-layout-vertical …`.
- UI proof is the PNG (which you `Read`) together with its log. Flow proof is the `diag:` lines together with `# exit: 0`.
- If an entry point can't be driven headlessly, say so. Don't report it as verified through a different path.

## Features

- [Widget](./widget.md) covers the floating panel: layouts, scale, gauges, mascot states, and panel sizing.
- [Dashboard](./dashboard.md) covers the expanded window: real-data layout at its edge sizes, and the full-screen flow.
- [Settings](./settings.md) covers the Settings view render and the gear-click activation flow.
- [/stats panel](./stats.md) covers the live `/stats` fold-in that the dashboard's `/stats` card shows.
