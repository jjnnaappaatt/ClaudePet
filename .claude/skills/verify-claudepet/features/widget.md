# Widget

The floating, always-on-top panel shows today's tokens and cost, the 5h and weekly gauges, Codex
rows, the pace bars, the weekly chart, today by hour, and the mascot. The mascot's mood and sky show
the 5h session, and the ground under it shows the week.

## Sub-features

- `widget-layout`: the landscape (default) and vertical layouts render without clipping.
- `widget-scale`: the widget scale grows the text crisply (no blur).
- `widget-gauges`: the gauge %, colour, `live` badge and reset countdown follow the server utilization.
- `widget-mascot`: the mood and weather follow the 5h fraction, and the ground follows the weekly one.
- `widget-codex`: the Codex rows show live, stale or absent.
- `widget-panelfit`: the real panel resizes to its content after the first scan.

## How to get to it (user POV)

- Launch ClaudePet.app. The widget appears floating on the desktop.
- Settings → Layout / Scale changes its shape.

## Driving it with verify.sh

Preconditions: `$S doctor` prints OK.

- **Layout (sample).** Run `$S run widget-layout CLAUDEPET_SNAPSHOT=@ART@/w.png`. `snapshot: wrote …` appears, and the PNG shows the header, gauges, charts and footer, none of them clipped.
- **Vertical + scale.** Run `$S run widget-layout-vertical CLAUDEPET_SNAPSHOT=@ART@/v.png CLAUDEPET_LAYOUT=vertical CLAUDEPET_SCALE=1.5`. The PNG is a single column with larger, sharp text.
- **Real figures.** Run `$S run widget-real CLAUDEPET_SNAPSHOT=@ART@/r.png CLAUDEPET_REAL=1`. The figures match the user's live widget.
- **Gauge states.** Run `$S run widget-gauges CLAUDEPET_SNAPSHOT=@ART@/g.png CLAUDEPET_UTIL=96,40`. The sample figures stay (142k work), the 5h bar reads 96% in red with `live`, the weekly bar reads 40%, and the mascot is stormy.
- **Codex.** Run `$S run widget-codex CLAUDEPET_SNAPSHOT=@ART@/c.png CLAUDEPET_CODEX=47,90000` for a stale row, or `CLAUDEPET_CODEX=none` for no row.
- **All mascot frames.** Run `$S run widget-mascot CLAUDEPET_MASCOT=@ART@/m.png`. Every mood, sky and ground is laid out in rows, with no two frames identical.
- **Panel fit.** Run `$S run widget-panelfit CLAUDEPET_PANELFIT=1`. The log ends `diag: OK: panel follows its content` and `# exit: 0`, after about 10 s.

## Gotchas

- The snapshot path can't see the panel's size: a perfect PNG says nothing about clipping in the real panel. Use `widget-panelfit`.
- `PANELFIT` puts a second widget on screen for about 10 s. Don't interact with it.
- Renders vary between runs (clock, thermals, Codex), so compare figures and layout, not pixels.
