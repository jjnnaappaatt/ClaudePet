# Changelog

All notable changes to ClaudePet are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com); versions are dated on release.

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
