#!/usr/bin/env python3
"""Disengage entries/exits and navigator health by disengage context, summed over a run's match_*.json."""
import glob, json, sys
from collections import defaultdict

E = defaultdict(lambda: defaultdict(int)); X = defaultdict(lambda: defaultdict(int)); D = defaultdict(lambda: defaultdict(float))
N = defaultdict(lambda: defaultdict(lambda: defaultdict(int))); R = defaultdict(lambda: defaultdict(int))
for f in glob.glob(f"{sys.argv[1]}/match_*.json"):
    d = json.load(open(f)).get("disengage_why", {})
    for cls, c in d.get("episodes", {}).items():
        for k, n in c["entries"].items(): E[cls][k] += n
        for k, n in c["exits"].items(): X[cls][k] += n
        for k, n in c["dur_s"].items(): D[cls][k] += n
    for cls, ctxs in d.get("nav", {}).items():
        for ctx, c in ctxs.items():
            for k, v in c.items():
                if isinstance(v, dict):
                    for r, n in v.items(): R[(cls, ctx)][f"{k}:{r}"] += n
                else:
                    N[cls][ctx][k] += v
for cls in sorted(E):
    print(f"\n== {cls} entries")
    for k, n in sorted(E[cls].items(), key=lambda kv: -kv[1]):
        if k.startswith("_total"): print(f"  {n:5} {k}")
    lo = sum(n for k, n in E[cls].items() if not k.startswith("_total") and "threat<" in k)
    print(f"  {lo:5} entries under threat 0.4")
    print(f"-- exits (n, mean s)")
    for k, n in sorted(X[cls].items(), key=lambda kv: -kv[1]): print(f"  {n:5} {D[cls][k]/n:6.1f}s {k}")
    print(f"-- navigator per 1000 ticks: ticks fail relaxed empty_path no_station stand")
    for ctx, c in sorted(N[cls].items()):
        t = max(c["ticks"], 1)
        print(f"  {ctx:22} {c['ticks']:6} " + " ".join(f"{1000*c[k]/t:7.1f}" for k in ("fail", "relaxed", "empty_path", "no_station", "stand"))
              + "  " + ", ".join(f"{r}:{n}" for r, n in R[(cls, ctx)].items()))
