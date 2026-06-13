# Mascot art drop-in

ClaudePet draws its mascot from built-in pixel art by default. To use higher-fidelity art
(e.g. a licensed illustration pack), drop **PNG** files here named by mood:

```
mascot-sleeping.png
mascot-celebrating.png
mascot-happy.png
mascot-neutral.png
mascot-worried.png
mascot-alarmed.png
```

Each filename matches a `MascotEmotion` raw value. Square images work best (they're scaled to
fit, nearest-neighbour, so pixel art stays crisp). A mood with no PNG falls back to the
built-in pixel art, so you can add them one at a time.

After adding files, rebuild (`./bundle.sh release`) and relaunch.

## Mood → usage mapping

| Mood | When |
|------|------|
| `sleeping` | no active session (you're away) |
| `celebrating` | fresh window, <5% used |
| `happy` | <50% of the closer limit |
| `neutral` | 50–80% |
| `worried` | 80–95% |
| `alarmed` | ≥95% |

## Licensing

ClaudePet ships **no** third-party art. If you use a pack (e.g. the getillustrations.com
"Claude mascot pack"), **you** obtain it and accept its license — including whether bundling
it into a repository you publish is permitted. These files are git-ignored-by-intent: add them
locally per the license you hold. The getillustrations pack is third-party art, not official
Anthropic.

Suggested pack → mood mapping: thinking→neutral, sad/confused→worried, dizzy/angry→alarmed,
happy→happy, celebrating→celebrating, sleeping→sleeping.
