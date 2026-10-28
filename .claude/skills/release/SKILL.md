---
name: release
description: Ship a ClaudePet version — bump the three version places and the build number, date the CHANGELOG, open the "Release vX.Y.Z" PR, then after merge build the DMG and publish the GitHub release with that version's notes. Run only when the user types /release.
disable-model-invocation: true
argument-hint: "[X.Y.Z]"
---

# Release ClaudePet

This follows how v0.11–v0.14 shipped: one `Release vX.Y.Z — <headline>` PR that bumps the versions,
then a GitHub release created from the merge commit with the DMG attached and **that version's**
CHANGELOG section as its notes. `release.sh` only builds. It doesn't bump anything, and its closing
`gh` hint passes the *whole* CHANGELOG as notes, so don't copy that hint.

```bash
P=.claude/skills/release/scripts/version.py
```

## 1. Preflight (read-only)

- `git status` is clean, you're on `main`, and `git pull --ff-only` succeeds.
- `python3 -I $P check` prints `in sync`.
- `python3 -I $P suggest` prints the next version. `### Added`/`Changed`/`Removed` under
  `[Unreleased]` means a minor bump, `### Fixed` alone means a patch. Use `$ARGUMENTS` if the user
  gave a version. Otherwise propose the suggestion and wait for a yes.
- Read `[Unreleased]` and draft a one-line headline in the style of earlier releases
  (`git log --oneline --grep '^Release v'`). Show it to the user.

## 2. Bump on a branch

```bash
git switch -c release/vX.Y.Z
python3 -I $P bump X.Y.Z        # core version, CFBundleShortVersionString, CFBundleVersion+1, dated heading
swift test
```

`bump` refuses a version that isn't above the current one, and refuses an empty `[Unreleased]`. It
dates the heading with the Gregorian ISO date, never with the machine's Buddhist calendar. It leaves
a fresh empty `## [Unreleased]` above the new section. Review `git diff`: it should be exactly four
changed lines plus the new heading.

Commit as `Release vX.Y.Z — <headline>`, with a body that says what landed and why it ships now
(see `git show 5cb674a` for the house style). **Ask before pushing and opening the PR**, then
`gh pr create`. The user merges.

## 3. Build and publish, after the merge

```bash
git switch main && git pull --ff-only && python3 -I $P check
./release.sh                     # swift test + ./bundle.sh release + dist/ClaudePet-X.Y.Z.dmg
```

`release.sh` rebuilds `./ClaudePet.app`, which is the user's running widget. The project's guard
hook will ask before it runs. Say so, and let the user quit the widget or accept. Afterwards
their app is the release build, so relaunch it with `open ClaudePet.app`.

Then publish. **This is public, so get an explicit yes first, showing the title and the first lines
of the notes:**

```bash
python3 -I $P notes X.Y.Z > dist/notes-X.Y.Z.md
gh release create vX.Y.Z dist/ClaudePet-X.Y.Z.dmg --target main \
  --title "vX.Y.Z — <headline>" --notes-file dist/notes-X.Y.Z.md
```

Confirm with `gh release view vX.Y.Z` that the DMG is attached and the tag points at the merge
commit (`git rev-parse vX.Y.Z` after `git fetch --tags`).

## Don't

- Bump on `main` directly, or bump in a feature PR. Ordinary changes go under `[Unreleased]` only.
- Hand-edit the version in one place: `release.sh` refuses to build when they disagree.
- Run `release.sh` for verification. Use the `verify-claudepet` skill.
