#!/usr/bin/env python3
"""usage: compare.py label=dir [label=dir ...]

Per build: match health from match_*.log / match_*.json, then per ship class
the mean and 95% interval of each metric, split by hull where a class has
several (a gunboat and a torpedo boat average into nonsense). Self-play: both teams run the same
build, so this shows how behaviour changed, not which build is stronger.
"""
import glob, json, math, os, re, sys
from collections import defaultdict

FIELDS = ["xp", "total_damage", "main_damage", "torpedo_damage", "damage_taken", "spotting_damage", "potential_damage",
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
              "draws": 0, "duration": [], "blocked_ms": [], "error_kinds": defaultdict(int),
              "reasons": defaultdict(int), "margin": [], "nav": [], "stations": [], "disengage": [], "fight": []}
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
        health["reasons"][m.get("win_reason", "?")] += 1
        if "nav" in m:
            health["nav"].append(m["nav"])
        if "stations" in m:
            health["stations"].append(m["stations"])
        if "disengage" in m:
            health["disengage"].append(m["disengage"])
        if "fight" in m:
            health["fight"].append(m["fight"])
        if "points" in m:
            health["margin"].append(abs(m["points"][0] - m["points"][1]))
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
    pm, pc = ci(h["margin"])
    reasons = " ".join(f"{k}={v}" for k, v in sorted(h["reasons"].items()))
    print(f"  {label}: win reasons {reasons}; points margin {pm:.1f}±{pc:.1f}")
for label, (h, _) in data.items():
    for k, n in sorted(h["error_kinds"].items(), key=lambda kv: -kv[1])[:5]:
        print(f"  {label}: {n}x {k}")

if any(h["nav"] for h, _ in data.values()):
    print("\n== navigator (navigate_to per match; counts per 1000 calls)")
    print(f'{"build":>12} {"calls":>7} {"mean_ms":>13} {"p50":>6} {"p99":>13} {"p99.9":>13} {"max":>7} '
          f'{">=3ms":>8} {"relaxed":>8} {"invalid":>8}')
    for label, (h, _) in data.items():
        nv = h["nav"]
        if not nv:
            continue
        calls = sum(n["calls"] for n in nv)
        per_k = lambda k: 1000.0 * sum(n[k] for n in nv) / max(calls, 1)
        mm, mc = ci([n["mean_ms"] for n in nv])
        pm, pc = ci([n["p99_ms"] for n in nv])
        qm, qc = ci([n["p999_ms"] for n in nv])
        p50, _ = ci([n["p50_ms"] for n in nv])
        print(f'{label:>12} {calls / len(nv):>7.0f} {mm:>7.3f}±{mc:<5.3f} {p50:>6.2f} {pm:>7.2f}±{pc:<5.2f} '
              f'{qm:>7.2f}±{qc:<5.2f} {max(n["max_ms"] for n in nv):>7.2f} {per_k("over_3ms"):>8.2f} '
              f'{per_k("relaxed"):>8.2f} {per_k("invalid"):>8.2f}')

if any(h["stations"] for h, _ in data.values()):
    print("\n== station moves (metres from each newly adopted station to the one before; per match)")
    print(f'{"build":>12} {"mode":>8} {"moves":>13} {"mean_m":>13} {"p50_m":>13} {"p90_m":>13} {">1km":>11} {">3km":>11}')
    for label, (h, _) in data.items():
        for mode in sorted({k for st in h["stations"] for k in st}):
            ms = [st.get(mode, {"n": 0, "over_1km": 0, "over_3km": 0}) for st in h["stations"]]
            cell = lambda k: "%7.0f±%-5.0f" % ci([x[k] for x in ms if x["n"] > 0 or k in ("n", "over_1km", "over_3km")])
            print(f'{label:>12} {mode:>8} {cell("n"):>13} {cell("mean_m"):>13} {cell("p50_m"):>13} {cell("p90_m"):>13} '
                  f'{"%5.1f±%-4.1f" % ci([x["over_1km"] for x in ms]):>11} {"%5.1f±%-4.1f" % ci([x["over_3km"] for x in ms]):>11}')

if any(h["disengage"] for h, _ in data.values()):
    print("\n== disengage legs (ticks per match, share of the class's disengage ticks, entries per match)")
    print(f'{"build":>12} {"leg":>10} {"ticks":>15} {"share":>7} {"entries":>13}')
    for label, (h, _) in data.items():
        keys = sorted({k for d in h["disengage"] for k in d})
        for k in keys:
            cls = k.split("/")[0]
            tot = sum(v["ticks"] for d in h["disengage"] for kk, v in d.items() if kk.split("/")[0] == cls)
            t = [d.get(k, {"ticks": 0})["ticks"] for d in h["disengage"]]
            e = [d.get(k, {"entries": 0})["entries"] for d in h["disengage"]]
            print(f'{label:>12} {k:>10} {"%7.0f±%-6.0f" % ci(t):>15} {100.0 * sum(t) / max(tot, 1):>6.1f}% {"%5.1f±%-5.1f" % ci(e):>13}')

if any(h["fight"] for h, _ in data.values()):
    print("\n== fight stations (busy: share of lit enemies counted as shooting a friend; depth/ahead: station/ship m past the local enemy centre, p50 of match p50s; past: share > 0; dist: ship to station)")
    print(f'{"build":>12} {"class":>6} {"searches":>13} {"busy":>7} {"depth_p50":>15} {"depth_p90":>15} {"past":>7} {"ahead_p50":>15} {"dist_p50":>13} {"dist_p90":>13}')
    for label, (h, _) in data.items():
        for c in sorted({k for d in h["fight"] for k in d}):
            ms = [d[c] for d in h["fight"] if c in d]
            q = lambda f, k: "%7.0f±%-6.0f" % ci([m[f][k] for m in ms if m[f]["n"] > 0])
            busy = sum(m["busy"] for m in ms) / max(sum(m["enemies"] for m in ms), 1)
            past = sum(m["depth"].get("past", 0) for m in ms) / max(sum(m["depth"]["n"] for m in ms), 1)
            print(f'{label:>12} {c:>6} {"%7.0f±%-5.0f" % ci([m["searches"] for m in ms]):>13} {100 * busy:>6.1f}% {q("depth", "p50"):>15} {q("depth", "p90"):>15} '
                  f'{100 * past:>6.1f}% {q("ahead", "p50"):>15} {q("dist", "p50"):>13} {q("dist", "p90"):>13}')

classes = sorted({r["ship_class"] for _, (_, rows) in data.items() for r in rows})
groups = []
for c in classes:
    groups.append((c, lambda r, c=c: r["ship_class"] == c))
    hulls = sorted({r["ship_name"] for _, (_, rows) in data.items() for r in rows if r["ship_class"] == c})
    if len(hulls) > 1:
        for hull in hulls:
            groups.append((f"{c}/{hull}", lambda r, c=c, hull=hull: r["ship_class"] == c and r["ship_name"] == hull))
if not groups:
    sys.exit("no metrics")
width = max(6, max(len(g) for g, _ in groups))
for field in FIELDS:
    print(f"\n== {field}")
    print(f'{"group":>{width}} ' + " ".join(f"{label:>20}" for label, _ in builds))
    for name, keep in groups:
        cells = []
        for label, _ in builds:
            xs = [float(r.get(field, 0.0)) for r in data[label][1] if keep(r)]
            m, h = ci(xs)
            cells.append(f"{m:>11.2f}±{h:<8.2f}")
        print(f"{name:>{width}} " + " ".join(cells))

SPAWN_FIELDS = ["xp", "total_damage", "damage_taken", "survival_time", "won"]


def region(r):
    n, s = int(r.get("team_size", 0)), int(r.get("spawn_position", -1))
    if n < 2 or s < 0:
        return None
    off = abs(2.0 * s / (n - 1) - 1.0)
    return "centre" if off < 1 / 3 else "mid" if off < 2 / 3 else "edge"


if any(region(r) for _, (_, rows) in data.items() for r in rows):
    for field in SPAWN_FIELDS:
        print(f"\n== {field} by spawn")
        print(f'{"group":>{width}} ' + " ".join(f"{label:>20}" for label, _ in builds))
        for c in classes:
            for reg in ["edge", "mid", "centre"]:
                cells = []
                for label, _ in builds:
                    xs = [float(r.get(field, 0.0)) for r in data[label][1] if r["ship_class"] == c and region(r) == reg]
                    m, h = ci(xs)
                    cells.append(f"{m:>11.2f}±{h:<8.2f}")
                print(f"{c + '/' + reg:>{width}} " + " ".join(cells))
