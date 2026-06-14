# ClaudePet — frontend (Claude Design import)

A self-contained HTML/CSS component library that mirrors the ClaudePet macOS widget,
ready to import into a **claude.ai/design** design-system project via the `/design-sync`
skill (which drives the `DesignSync` tool).

Every file is a standalone preview. Its **first line** is a card marker:

```html
<!-- @dsCard group="Gauges" -->
```

claude.ai/design reads that marker to place the file as a card in the Design System pane
(it compiles the markers into `_ds_manifest.json` on upload — no manual registration needed).

## Structure

| Path | Card group | What it shows |
|------|-----------|---------------|
| `foundations/colors.html` | Foundations | The coral palette, surfaces, text, state, mascot & model-dot colors |
| `foundations/typography.html` | Foundations | Rounded tabular numerals + the SF Pro Text label scale |
| `components/mascot.html` | Mascot | All 6 usage-driven moods (SVG pixel art, generated from `MascotArt.build`) |
| `components/badges.html` | Components | Plan badge + `live` indicators |
| `components/stats-header.html` | Components | "Today" + estimated cost + work/cache tokens |
| `components/budget-gauge.html` | Gauges | 5-hour session gauge |
| `components/weekly-bar.html` | Gauges | Weekly (all-models) limit bar |
| `components/model-row.html` | Components | Per-model breakdown rows |
| `components/weekly-chart.html` | Components | Work-per-day bar chart |
| `components/footer.html` | Components | Week / cycle totals + settings |
| `components/billing.html` | Components | Paid vs API-value + credits |
| `widgets/vertical.html` | Widget | Full tall card (300px) |
| `widgets/landscape.html` | Widget | Full wide two-column card (520px) |

`tokens.css` holds the canonical design tokens for reference. Each preview **inlines** the
same `:root` token block so it renders standalone (no external CSS/JS/font/image requests).

## Design tokens

Sourced from the app's `Theme.swift` and `Pal.swift`:

- **Coral** `#D97757` (single accent) · **highlight** `#F2A485` · **dark outline** `#793923`
- Card gradient `#2B2B30 → #1A1A1C`, stroke `white/8%`, text `white` / `white 62%` / `white 40%`
- Gauge states: coral → orange `#FF9500` (≥90%) → red `#FF3B30`; track `white/12%`
- Numerals use `SF Pro Rounded` (tabular); labels use `SF Pro Text` — matching the native widget
- Mascot palette: body `#D97757`, belly `#F4AA8D`, outline `#5A2618`, pupil `#1B1B1E`,
  glint `#fff`, sweat `#66B8F2`, alarm `#ED4D45`

## Importing into Claude Design

1. Run the `/design-sync` skill in this repo.
2. Pick (or create) a **design-system** project on claude.ai/design.
3. Approve the plan; it uploads these previews and they appear as cards.

(`/design-sync` syncs incrementally, one component at a time — never a wholesale replace.)

## Regenerating

The previews are produced by a generator so the standalone cards and the assembled widgets
share byte-identical markup. The mascot SVGs are emitted directly from the same pixel logic as
`Sources/ClaudePetCore/MascotArt.swift`, so the web mascot always matches the app.
