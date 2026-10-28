#!/usr/bin/env python3
"""The three hand-maintained version places, kept in step.

  version.py check               print each place's version; exit 1 if they disagree
  version.py bump X.Y.Z          set all three, CFBundleVersion += 1, date the Unreleased section
  version.py notes X.Y.Z         print that version's CHANGELOG section (the GitHub release notes)
  version.py suggest             next version from what [Unreleased] holds (Added/Changed -> minor, Fixed only -> patch)

--root DIR points at a copy of the repo (used to test against scratch files).
"""
import argparse, datetime, os, plistlib, re, sys

CORE = "Sources/ClaudePetCore/ClaudePetCore.swift"
PLIST = "Sources/ClaudePet/Supporting/Info.plist"
LOG = "CHANGELOG.md"
SEMVER = re.compile(r"\d+\.\d+\.\d+")


def read(root, rel):
    return open(os.path.join(root, rel), encoding="utf-8").read()


def write(root, rel, text):
    open(os.path.join(root, rel), "w", encoding="utf-8").write(text)


def current(root):
    core = re.search(r'public static let version = "(\d+\.\d+\.\d+)"', read(root, CORE)).group(1)
    pl = plistlib.loads(read(root, PLIST).encode())
    log = re.search(r"^## \[(\d+\.\d+\.\d+)\]", read(root, LOG), re.M).group(1)
    return {"core": core, "plist": pl["CFBundleShortVersionString"], "build": pl["CFBundleVersion"], "changelog": log}


def unreleased(root):
    m = re.search(r"^## \[Unreleased\]\n(.*?)(?=^## \[)", read(root, LOG), re.M | re.S)
    return m.group(1).strip() if m else ""


def cmd_check(root, _):
    v = current(root)
    print(f"core {v['core']}  Info.plist {v['plist']} (build {v['build']})  CHANGELOG {v['changelog']}")
    ok = v["core"] == v["plist"] == v["changelog"]
    print("in sync" if ok else "MISMATCH: release.sh will refuse to build")
    return 0 if ok else 1


def cmd_suggest(root, _):
    body = unreleased(root)
    if not body:
        print("[Unreleased] is empty: nothing to release"); return 1
    major, minor, patch = map(int, current(root)["core"].split("."))
    minor_bump = re.search(r"^### (Added|Changed|Removed)", body, re.M)
    print(f"{major}.{minor + 1}.0" if minor_bump else f"{major}.{minor}.{patch + 1}")
    return 0


def cmd_bump(root, a):
    new = a.version
    if not SEMVER.fullmatch(new):
        sys.exit(f"not X.Y.Z: {new}")
    v = current(root)
    if tuple(map(int, new.split("."))) <= tuple(map(int, v["core"].split("."))):
        sys.exit(f"{new} is not above the current {v['core']}")
    if not unreleased(root):
        sys.exit("[Unreleased] is empty: nothing to release")

    core = read(root, CORE)
    write(root, CORE, core.replace(f'public static let version = "{v["core"]}"', f'public static let version = "{new}"', 1))

    # Edit the plist text in place rather than plistlib.dump, which would reformat the whole file.
    pl = read(root, PLIST)
    pl = re.sub(r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{new}\g<2>", pl, count=1)
    pl = re.sub(r"(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{int(v['build']) + 1}\g<2>", pl, count=1)
    write(root, PLIST, pl)

    # Gregorian ISO date, never Calendar.current: this machine's calendar is Buddhist (year 2569).
    today = datetime.date.today().isoformat()
    log = read(root, LOG)
    log = log.replace("## [Unreleased]\n", f"## [Unreleased]\n\n## [{new}] — {today}\n", 1)
    write(root, LOG, log)
    return cmd_check(root, a)


def cmd_notes(root, a):
    m = re.search(rf"^## \[{re.escape(a.version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", read(root, LOG), re.M | re.S)
    if not m:
        sys.exit(f"no CHANGELOG section for {a.version}")
    print(m.group(1).strip())
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../..")))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check"); sub.add_parser("suggest")
    for n in ("bump", "notes"):
        sub.add_parser(n).add_argument("version")
    a = ap.parse_args()
    sys.exit({"check": cmd_check, "suggest": cmd_suggest, "bump": cmd_bump, "notes": cmd_notes}[a.cmd](a.root, a))


if __name__ == "__main__":
    main()
