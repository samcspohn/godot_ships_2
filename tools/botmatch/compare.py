#!/usr/bin/env python3
"""usage: compare.py label=dir [label=dir ...]

Per build: match health from match_*.log / match_*.json, then per ship class
the mean and 95% interval of each metric. Self-play: both teams run the same
build, so this shows how behaviour changed, not which build is stronger.
"""
import glob, json, math, os, re, sys
from collections import defaultdict

FIELDS = ["total_damage", "damage_taken", "spotting_damage", "potential_damage",
          "frags", "survival_time", "hp_frac", "torpedo_hits_taken", "torpedo_taken"]
BLOCK = re.compile(r"main blocked ([\d.]+) ms")


def ci(xs):
    n = len(xs)
    if n == 0:
        return float("nan"), float("nan")
    m = sum(xs) / n
    if n < 2:
        return m, float("nan")
    sd = math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1))
    return m, 1.96 * sd / math.sqrt(n)


def load(d):
    logs = sorted(glob.glob(os.path.join(d, "match_*.log")))
    health = {"matches": len(logs), "metrics": 0, "errors": 0, "matches_with_errors": 0,
              "draws": 0, "duration": [], "blocked_ms": [], "error_kinds": defaultdict(int)}
    rows = []
    for log in logs:
        text = open(log, errors="replace").read()
        errs = [l for l in text.splitlines() if l.startswith("SCRIPT ERROR")]
        health["errors"] += len(errs)
        health["matches_with_errors"] += bool(errs)
        for e in errs:
            health["error_kinds"][e[:110]] += 1
        health["blocked_ms"] += [float(x) for x in BLOCK.findall(text)]
        js = log[:-4] + ".json"
        if not os.path.exists(js):
            continue
        m = json.load(open(js))
        health["metrics"] += 1
        health["draws"] += bool(m.get("time_limit"))
        health["duration"].append(m["duration"])
        for s in m["ships"]:
            rows.append(s)
    return health, rows


builds = [a.split("=", 1) for a in sys.argv[1:]]
data = {label: load(d) for label, d in builds}

print("== match health")
print(f'{"build":>12} {"matches":>8} {"metrics":>8} {"errors":>7} {"err_m":>6} {"draws":>6} {"dur_s":>13} {"blocked_ms/5s":>14}')
for label, (h, _) in data.items():
    dm, dc = ci(h["duration"])
    bm, _ = ci(h["blocked_ms"])
    print(f'{label:>12} {h["matches"]:>8} {h["metrics"]:>8} {h["errors"]:>7} {h["matches_with_errors"]:>6} '
          f'{h["draws"]:>6} {dm:>7.0f}±{dc:<5.0f} {bm:>14.1f}')
for label, (h, _) in data.items():
    for k, n in sorted(h["error_kinds"].items(), key=lambda kv: -kv[1])[:5]:
        print(f"  {label}: {n}x {k}")

classes = sorted({r["ship_class"] for _, (_, rows) in data.items() for r in rows})
for field in FIELDS:
    print(f"\n== {field}")
    print(f'{"class":>6} ' + " ".join(f"{label:>20}" for label, _ in builds))
    for c in classes:
        cells = []
        for label, _ in builds:
            xs = [float(r.get(field, 0.0)) for r in data[label][1] if r["ship_class"] == c]
            m, h = ci(xs)
            cells.append(f"{m:>11.2f}±{h:<8.2f}")
        print(f"{c:>6} " + " ".join(cells))
