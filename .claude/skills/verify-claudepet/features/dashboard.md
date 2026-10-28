# Dashboard

The dashboard is the expanded, resizable, full-screen-capable window opened from the widget's expand
button. It holds the gauges, the cycle chart and calendar, the weekly and subagent charts, the
per-project breakdown, the `/stats` card, and billing.

## Sub-features

- `dash-min`: at its minimum size of 900×800 nothing clips, the "+N more" project line fits, and the billing footer shows.
- `dash-wide`: at 1990×820 (width boosts at full strength while height is tight), the bottom card stays inside the window.
- `dash-flow`: the expand button opens a titled, resizable window. It can go full screen, ⌃⌘F is wired, and the widget hides while it's full screen and comes back afterwards.

## How to get to it (user POV)

- Click the expand (↗) icon in the widget's footer.
- Press ⌃⌘F inside the dashboard to toggle full screen.

## Driving it with verify.sh

Preconditions: `$S doctor` prints OK. Real data exists under `~/.claude/projects`.

- **Minimum size.** Run `$S run dash-min CLAUDEPET_DASHBOARD=@ART@/min.png CLAUDEPET_DASHSIZE=900x800 CLAUDEPET_REAL=1`. In the PNG every card is inside the frame, the project list ends with "+N more", and the billing footer is visible.
- **Wide, tight height.** Run `$S run dash-wide CLAUDEPET_DASHBOARD=@ART@/wide.png CLAUDEPET_DASHSIZE=1990x820 CLAUDEPET_REAL=1`. The bottom-most card's edge sits above the image's bottom edge.
- **Open flow.** Run `$S run dash-flow CLAUDEPET_OPENDASHBOARD=1`. The `diag:` lines report `titled=true resizable=true fullScreenPrimary=true`, the `contentMinSize` matches the minimum, `fullScreenMenuItem` isn't `MISSING`, `entered fullScreen=true … widgetHidden=true`, `exited widgetRestored=true`, and `afterClose policy=1`.

## Gotchas

- Sample data's short project list hides overflow, so always prove layout with `CLAUDEPET_REAL=1`.
- Measure the bottom-most **card** pixel, not the last line of text. Nothing looks tight before it clips.
- Keep the default `CLAUDEPET_DASHSCALE` of 1 when measuring, so px equals pt. Use 2 only for documentation images.
- `dash-flow` goes full screen on the user's display for a couple of seconds and leaves on its own, with a 15 s timeout.
