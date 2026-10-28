# /stats panel

The dashboard's `/stats` card shows what Claude Code's terminal `/stats` would print right now. That
is `~/.claude/stats-cache.json` plus a live fold-in of every day since its `lastComputedDate`.

## Sub-features

- `stats-delta`: the fold-in for the days after a given date matches what `/stats` adds.
- `stats-card`: the card renders the merged figures, and an amber "open /stats · Nd" tag appears once the cache is more than 21 days old.

## How to get to it (user POV)

- Open the dashboard. The `/stats` card is on the right.

## Driving it with verify.sh

Preconditions: `$S doctor` prints OK, and `~/.claude/stats-cache.json` exists.

- **Delta.** Run `$S run stats-delta CLAUDEPET_STATSDELTA=<day after lastComputedDate>`. Exit 0, and the log holds JSON with per-day messages, sessions and per-model tokens.
- **Card.** Run `$S run stats-card CLAUDEPET_DASHBOARD=@ART@/d.png CLAUDEPET_DASHSIZE=1400x900 CLAUDEPET_REAL=1`. The `/stats` card shows the totals and its freshness tag.

## Gotchas

- Days are **UTC**. Pass the date as `YYYY-MM-DD` in UTC, not in local time and never in the Buddhist calendar year.
- To validate against Claude Code itself, follow CLAUDE.md's "Re-validate after a Claude Code update": copy the cache, open `/stats`, and compare. That needs a terminal, so this map can't do it headlessly.
- `/stats` doesn't dedup, so its figures legitimately differ from the rest of the dashboard.
