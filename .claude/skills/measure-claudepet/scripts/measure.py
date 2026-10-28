#!/usr/bin/env python3
"""Measure ClaudePet's memory and CPU the way CLAUDE.md says to, so two runs are comparable.

  measure.py cold   [--runs 3]                         cold scan of real data: wall/user CPU/peak footprint
  measure.py launch [--duration 300 --interval 30] [--heap] [--sample 5]
                                                       run the verify bundle as a normal app and sample it
  measure.py attach <pid|live> [--samples 5 --interval 10] [--heap] [--sample 5]
                                                       read-only sampling of a running process

Everything lands in .verify-artifacts/measure-<run>/ (summary.json + raw vmmap/heap/sample output).
Every summary records the binary's sha256, the git rev, the process uptime and the corpus size,
because a delta without those is not a measurement (CLAUDE.md, "Three measurement traps").
"""
import argparse, hashlib, json, os, re, signal, subprocess, sys, time
from datetime import datetime

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
VERIFY_BIN = os.path.join(ROOT, ".build/verify/ClaudePet.app/Contents/MacOS/ClaudePet")
LIVE_BIN = os.path.join(ROOT, "ClaudePet.app/Contents/MacOS/ClaudePet")
PIDS = os.path.join(ROOT, ".verify-artifacts/pids")   # shared with verify.sh cleanup
BLOCKING = ("mach_msg2_trap", "__workq_kernreturn", "__psynch_cvwait", "__semwait_signal",
            "kevent", "__ulock_wait", "__select", "__psynch_mutexwait")
UNITS = {"B": 1 / 1024 / 1024, "K": 1 / 1024, "M": 1, "G": 1024}


def sh(*cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def mb(tok):
    m = re.fullmatch(r"([\d.]+)([BKMG]?)", tok)
    return round(float(m.group(1)) * UNITS[m.group(2) or "B"], 1)


def binary_info(path):
    h = hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]
    rev = sh("git", "-C", ROOT, "rev-parse", "--short", "HEAD").stdout.strip()
    dirty = bool(sh("git", "-C", ROOT, "status", "--porcelain", "--", "Sources").stdout.strip())
    # Debug scans ~2x slower than release: never compare across configs. verify.sh records it;
    # the user's ./ClaudePet.app has no record (bundle.sh defaults to debug).
    cfg = os.path.join(os.path.dirname(path), "../Resources/verify-config")
    config = open(cfg).read().strip() if os.path.exists(cfg) else "unknown"
    return {"binary": path, "config": config, "sha256_16": h, "rev": rev + ("+dirty" if dirty else "")}


def corpus_mb():
    out = sh("du", "-sk", os.path.expanduser("~/.claude/projects")).stdout.split()
    return round(int(out[0]) / 1024) if out else None


def uptime_s(pid):
    et = sh("ps", "-o", "etime=", "-p", str(pid)).stdout.strip()   # [[dd-]hh:]mm:ss
    if not et:
        return None
    days, _, rest = et.rpartition("-")
    parts = [int(p) for p in rest.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return (int(days) if days else 0) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]


def vmmap(pid, out_dir, tag):
    # Parsed in Python on purpose: hand-rolled awk mis-read these columns twice.
    txt = sh("vmmap", "-summary", str(pid)).stdout
    open(os.path.join(out_dir, f"vmmap-{tag}.txt"), "w").write(txt)
    r = {}
    for key, pat in (("footprint_mb", r"^Physical footprint:\s+(\S+)"),
                     ("peak_mb", r"^Physical footprint \(peak\):\s+(\S+)")):
        m = re.search(pat, txt, re.M)
        r[key] = mb(m.group(1)) if m else None
    return r


def heap(pid, out_dir):
    txt = sh("heap", str(pid)).stdout
    open(os.path.join(out_dir, "heap.txt"), "w").write(txt)
    m = re.search(r"^All zones: (\d+) nodes \((\d+) bytes\)", txt, re.M)
    return {"live_nodes": int(m.group(1)), "live_mb": round(int(m.group(2)) / 1048576, 1)} if m else None


def sample(pid, secs, out_dir):
    """Per-thread on-CPU vs blocked. Blocked = samples whose leaf is a blocking syscall; those are
    leaves, so their counts sum without double counting. A UI review once blamed the mascot for
    CPU that was all on the scanner's queue: split by thread before believing any hot spot."""
    path = os.path.join(out_dir, "sample.txt")
    sh("sample", str(pid), str(secs), "-file", path)
    lines = open(path).read().splitlines()
    threads, cur = [], None
    for ln in lines:
        m = re.match(r"^\s{4}(\d+) (Thread_\d+.*)$", ln)
        if m:
            cur = {"thread": m.group(2).strip(), "samples": int(m.group(1)), "blocked": 0}
            threads.append(cur)
            continue
        if ln.startswith("Total number in stack") or ln.startswith("Sort by top of stack"):
            cur = None
        if cur:
            m = re.match(r"^[\s+!:|]*(\d+) (\S+)", ln)
            if m and m.group(2) in BLOCKING:
                cur["blocked"] += int(m.group(1))
    for t in threads:
        t["on_cpu"] = t["samples"] - t["blocked"]
    top = []
    if "Sort by top of stack, same collapsed (when >= 5):" in lines:
        i = lines.index("Sort by top of stack, same collapsed (when >= 5):") + 1
        while i < len(lines) and lines[i].strip():
            m = re.match(r"^\s+(.*\S)\s+(\d+)$", lines[i])
            if m:
                top.append({"frame": m.group(1), "count": int(m.group(2))})
            i += 1
    threads.sort(key=lambda t: -t["on_cpu"])
    return {"threads": threads[:8], "top_of_stack": top[:10]}


def rng(xs):
    xs = [x for x in xs if x is not None]
    return [min(xs), max(xs)] if xs else None


def out_dir_for(kind):
    run = os.environ.get("VERIFY_RUN_ID") or datetime.now().strftime("%Y%m%d-%H%M%S")
    d = os.path.join(ROOT, ".verify-artifacts", f"measure-{run}-{kind}")
    os.makedirs(d, exist_ok=True)
    return d


def poll(pid, samples, interval, d, args, first_delay=False):
    rows = []
    for i in range(samples):
        if i or first_delay:   # a just-launched app reads ~15 MB before its first scan: not a data point
            time.sleep(interval)
        if sh("kill", "-0", str(pid)).returncode:
            break
        rows.append({"uptime_s": uptime_s(pid), **vmmap(pid, d, i)})
        print(f"  t={rows[-1]['uptime_s']}s footprint={rows[-1]['footprint_mb']}M peak={rows[-1]['peak_mb']}M", flush=True)
    res = {"samples": rows,
           "footprint_range_mb": rng([r["footprint_mb"] for r in rows]),
           "peak_mb": max([r["peak_mb"] for r in rows if r["peak_mb"]], default=None)}
    if args.heap:
        res["heap"] = heap(pid, d)
    if args.sample:
        res["cpu"] = sample(pid, args.sample, d)
    return res


def finish(d, summary):
    # Wall clock and CPU figures taken on a loaded machine don't compare with anything.
    load, cores = os.getloadavg()[0], os.cpu_count()
    summary["load_1m"], summary["cores"] = round(load, 1), cores
    if load > cores * 0.7:
        summary["warning"] = f"load {load:.1f} on {cores} cores: timings are not comparable, re-run when idle"
    json.dump(summary, open(os.path.join(d, "summary.json"), "w"), indent=2)
    print(json.dumps({k: v for k, v in summary.items() if k not in ("samples", "runs")}, indent=2))
    print(f"artifacts: {d}")


def need_verify_bin():
    if not os.access(VERIFY_BIN, os.X_OK):
        sys.exit("no verify bundle: run .claude/skills/verify-claudepet/scripts/verify.sh build")


def cmd_cold(args):
    need_verify_bin()
    d = out_dir_for("cold")
    runs = []
    for i in range(args.runs):
        env = dict(os.environ, CLAUDEPET_SNAPSHOT=os.path.join(d, f"cold-{i}.png"), CLAUDEPET_REAL="1")
        p = sh("/usr/bin/time", "-l", VERIFY_BIN, env=env)
        e = p.stderr
        g = lambda pat: (m := re.search(pat, e, re.M)) and m.group(1)
        runs.append({"wall_s": float(g(r"([\d.]+) real")), "user_s": float(g(r"([\d.]+) user")),
                     "max_rss_mb": round(int(g(r"(\d+)\s+maximum resident set size")) / 1048576),
                     "peak_footprint_mb": round(int(g(r"(\d+)\s+peak memory footprint")) / 1048576)})
        print(f"  run {i + 1}: {runs[-1]}", flush=True)
    finish(d, {"kind": "cold", **binary_info(VERIFY_BIN), "corpus_mb": corpus_mb(), "runs": runs,
               "wall_s": rng([r["wall_s"] for r in runs]), "user_s": rng([r["user_s"] for r in runs]),
               "peak_footprint_mb": rng([r["peak_footprint_mb"] for r in runs]),
               "note": "peak footprint, not RSS: RSS counts clean pages and reads several times higher"})


def cmd_launch(args):
    need_verify_bin()
    d = out_dir_for("launch")
    log = open(os.path.join(d, "app.log"), "w")
    p = subprocess.Popen([VERIFY_BIN], stdout=log, stderr=log)
    os.makedirs(os.path.dirname(PIDS), exist_ok=True)
    open(PIDS, "a").write(f"{p.pid}\n")
    print(f"launched verify bundle pid {p.pid}; sampling every {args.interval}s for {args.duration}s")
    try:
        res = poll(p.pid, max(1, args.duration // args.interval), args.interval, d, args, first_delay=True)
    finally:
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=10)
    finish(d, {"kind": "launch", **binary_info(VERIFY_BIN), "corpus_mb": corpus_mb(), "pid": p.pid, **res})


def cmd_attach(args):
    if args.pid == "live":
        out = sh("pgrep", "-f", LIVE_BIN).stdout.split()
        if not out:
            sys.exit("the user's ClaudePet.app is not running")
        pid, binp = int(out[0]), LIVE_BIN
    else:
        pid = int(args.pid)
        binp = sh("ps", "-o", "comm=", "-p", str(pid)).stdout.strip()
    d = out_dir_for("attach")
    res = poll(pid, args.samples, args.interval, d, args)
    finish(d, {"kind": "attach", **(binary_info(binp) if os.path.exists(binp) else {"binary": binp}),
               "corpus_mb": corpus_mb(), "pid": pid, **res})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("cold"); c.add_argument("--runs", type=int, default=3)
    for name in ("launch", "attach"):
        s = sub.add_parser(name)
        if name == "attach":
            s.add_argument("pid")
            s.add_argument("--samples", type=int, default=5)
        else:
            s.add_argument("--duration", type=int, default=300)
        s.add_argument("--interval", type=int, default=10 if name == "attach" else 30)
        s.add_argument("--heap", action="store_true", help="live set via heap(1): proves '(empty)' arenas are free, not leaked")
        s.add_argument("--sample", type=int, default=0, metavar="SECS", help="sample(1) for SECS, split by thread")
    a = ap.parse_args()
    {"cold": cmd_cold, "launch": cmd_launch, "attach": cmd_attach}[a.cmd](a)


if __name__ == "__main__":
    main()
