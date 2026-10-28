# Settings

The Settings window, opened from the widget's gear, holds the budget source, plan, token basis,
layout and scale, the window options, pricing, and "Count repeated log lines".

## Sub-features

- `settings-render`: every section renders, readable and unclipped.
- `settings-open`: the gear opens a key window that takes focus, even though the app is a dockless accessory.

## How to get to it (user POV)

- Click the gear icon in the widget's footer.

## Driving it with verify.sh

Preconditions: `$S doctor` prints OK.

- **Render.** Run `$S run settings-render CLAUDEPET_SETTINGS=@ART@/s.png`. The PNG shows every section with its controls.
- **Open flow.** Run `VERIFY_TIMEOUT=8 $S run settings-open CLAUDEPET_OPENSETTINGS=1`. The log has `diag: active=true … isKey=true` and a non-nil `firstResponder`. This path doesn't exit by itself, so it ends `# TIMEOUT` and exit 124: that is expected. Run `$S cleanup` afterwards.

## Gotchas

- `OPENSETTINGS` never terminates by itself. Always give it a short `VERIFY_TIMEOUT`.
- `budgetBasisDescription` text belongs to the Settings view, but the only machine-readable way to read it against real data is `CLAUDEPET_HEARTBEAT` (see CLAUDE.md).
