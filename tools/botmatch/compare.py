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
              "reasons": defaultdict(int), "margin": [], "nav": [], "stations": [], "disengage": [], "fight": [], "calibration": [], "manoeuvres": [], "vetoes": []}
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
        if "calibration" in m:
            health["calibration"].append(m["calibration"])
        if "manoeuvres" in m:
            health["manoeuvres"].append(m["manoeuvres"])
        if "vetoes" in m:
            health["vetoes"].append(m["vetoes"])
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
    print("\n== fight stations (brawl: share of searches as a brawler; chkpts: checkpoints adopted per match; busy: share of lit enemies counted as shooting a friend; depth/ahead: station/ship m past the local enemy centre, p50 of match p50s; past: share > 0; dist: ship to station)")
    print(f'{"build":>12} {"class":>20} {"searches":>13} {"brawl":>6} {"chkpts":>11} {"busy":>7} {"depth_p50":>15} {"depth_p90":>15} {"past":>7} {"ahead_p50":>15} {"dist_p50":>13} {"dist_p90":>13}')
    for label, (h, _) in data.items():
        for c in sorted({k for d in h["fight"] for k in d}):
            ms = [d[c] for d in h["fight"] if c in d]
            q = lambda f, k: "%7.0f±%-6.0f" % ci([m[f][k] for m in ms if m[f]["n"] > 0])
            busy = sum(m["busy"] for m in ms) / max(sum(m["enemies"] for m in ms), 1)
            past = sum(m["depth"].get("past", 0) for m in ms) / max(sum(m["depth"]["n"] for m in ms), 1)
            brawl = sum(m.get("brawler", 0) for m in ms) / max(sum(m["searches"] for m in ms), 1)
            print(f'{label:>12} {c:>20} {"%7.0f±%-5.0f" % ci([m["searches"] for m in ms]):>13} {100 * brawl:>5.1f}% {"%5.1f±%-4.1f" % ci([m.get("checkpoints", 0) for m in ms]):>11} {100 * busy:>6.1f}% {q("depth", "p50"):>15} {q("depth", "p90"):>15} '
                  f'{100 * past:>6.1f}% {q("ahead", "p50"):>15} {q("dist", "p50"):>13} {q("dist", "p90"):>13}')

def calib_table(label, cals, group, group_hull=None):
    agg = defaultdict(lambda: defaultdict(float))
    for c in cals:
        for key, v in c.items():
            shooter, tcls, band, *hull = key.split("|")
            for k, x in v.items():
                agg[group(shooter, tcls, int(band))][k] += x
                if hull and group_hull is not None:
                    agg[group_hull(shooter, hull[0], int(band))][k] += x
    for g in sorted(k for k in agg if k is not None):
        a = agg[g]
        if a["pred"] <= 0 and a["real"] <= 0:
            continue
        print(f'{label:>12} {g:>34} {a["salvos"]:>8.0f} {a["pred"] / max(a["salvos"], 1):>10.0f} {a["real"] / max(a["salvos"], 1):>10.0f} '
              f'{a["real"] / max(a["pred"], 1):>7.2f} {100 * a["pred_cit"] / max(a["pred"], 1):>7.1f}% {100 * a["real_cit"] / max(a["real"], 1):>7.1f}%')

if any(h["calibration"] for h, _ in data.values()):
    print("\n== main-battery calibration (per salvo: model expectation at fire on the target nearest the aim vs damage that landed; cit = citadel share)")
    hdr = f'{"build":>12} {"group":>34} {"salvos":>8} {"pred/salvo":>10} {"real/salvo":>10} {"real/pr":>7} {"pr_cit":>8} {"real_cit":>8}'
    print(hdr)
    for label, (h, _) in data.items():
        calib_table(label, h["calibration"], lambda s, t, b: f"{s} -> {t}")
    print(hdr)
    for label, (h, _) in data.items():
        calib_table(label, h["calibration"], lambda s, t, b: f"all -> {t} {b * 5}-{b * 5 + 5}km")
    print(hdr)
    for label, (h, _) in data.items():
        calib_table(label, h["calibration"], lambda s, t, b: None, lambda s, t, b: f"all -> {t}")

if any(h["manoeuvres"] for h, _ in data.values()):
    print("\n== stance manoeuvres (chosen turn/astern run, per run: priced vs taken main-battery damage. on/by: priced (before the "
          "manoeuvre factor) and taken from shooters on us / bystanders; other: taken from ships not priced; early: first 30 s; band: run length)")
    print(f'{"build":>6} {"class/kind/band":>18} {"n":>6} {"priced":>7} {"taken":>7} {"t/p":>5} {"on p":>7} {"on t":>7} {"by p":>7} '
          f'{"by t":>7} {"other t":>7} {"early p":>7} {"early t":>7} {"learn":>7} {"t/l":>5} {">hp":>6} {"died":>6} {"d|>hp":>6}')
    bands = ["<30s", "30-60s", "60-120s", ">120s"]
    for label, (h, _) in data.items():
        agg = defaultdict(lambda: defaultdict(float))
        for mm in h["manoeuvres"]:
            for k, v in mm.items():
                parts = k.split("|")
                if len(parts) < 3:
                    continue
                keys = [f"{parts[0]}/{parts[1]}/all", f"{parts[0]}/{parts[1]}/{bands[int(parts[2])]}"]
                if len(parts) > 3:
                    keys.append(f"{parts[3]}/{parts[1]}")
                for key in keys:
                    for f, x in v.items():
                        agg[key][f] += x
        for k in sorted(agg):
            a = agg[k]
            n = max(a["n"], 1)
            per = lambda f: f'{a[f] / n:>7.0f}'
            print(f'{label:>6} {k:>18} {a["n"]:>6.0f} {per("pred")} {per("real")} {a["real"] / max(a["pred"], 1):>5.2f} {per("pred_on")} {per("real_on")} '
                  f'{per("pred_by")} {per("real_by")} {per("real_other")} {per("pred_early")} {per("real_early")} {per("learn")} {a["real"] / max(a["learn"], 1):>5.2f} '
                  f'{100 * a["over_hp"] / n:>5.1f}% {100 * a["died"] / n:>5.1f}% {100 * a["died_over"] / max(a["over_hp"], 1):>5.1f}%')

if any(h["vetoes"] for h, _ in data.values()):
    print("\n== turn veto (fresh prices where turning beat backing, and the share the swing-vs-HP veto blocked)")
    for label, (h, _) in data.items():
        agg = defaultdict(lambda: [0, 0])
        for v in h["vetoes"]:
            for c, x in v.items():
                agg[c][0] += x["cheaper"]
                agg[c][1] += x["vetoed"]
        for c in sorted(agg):
            print(f'{label:>12} {c:>4} {agg[c][0] / max(len(h["vetoes"]), 1):>8.1f}/match cheaper  {100 * agg[c][1] / max(agg[c][0], 1):>5.1f}% vetoed')

if any(h["calibration"] for h, _ in data.values()):
    print("\n== salvo split (real side: hit rate and damage per hit by target and range; pred/shell is the model's expectation per shell fired)")
    print(f'{"build":>6} {"target":>6} {"range km":>9} {"shells":>8} {"hit %":>7} {"model %":>8} {"real/hit":>9} {"pred/shell":>11} {"real/shell":>11} {"real/pred":>10}')
    for label, (h, _) in data.items():
        agg = defaultdict(lambda: defaultdict(float))
        for c in h["calibration"]:
            for key, v in c.items():
                _, tcls, band, *_ = key.split("|")
                for k, x in v.items():
                    agg[(tcls, int(band))][k] += x
        for tcls, band in sorted(agg):
            a = agg[(tcls, band)]
            if a["shells"] < 100:
                continue
            print(f'{label:>6} {tcls:>6} {band * 5:>4}-{band * 5 + 5:<4} {a["shells"]:>8.0f} {100 * a["hits"] / a["shells"]:>6.1f}% {100 * a["pred_hits"] / a["shells"]:>7.1f}% '
                  f'{a["real"] / max(a["hits"], 1):>9.0f} {a["pred"] / a["shells"]:>11.0f} {a["real"] / a["shells"]:>11.0f} '
                  f'{a["real"] / max(a["pred"], 1):>10.2f}')

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
