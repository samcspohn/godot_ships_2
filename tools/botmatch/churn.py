#!/usr/bin/env python3
"""Destination jumps per bot-minute by class and cause, summed over a run's match_*.json."""
import glob, json, sys
from collections import defaultdict

out = sys.argv[1]
s = defaultdict(float)
ticks = defaultdict(int)
multi = defaultdict(int)
counts = defaultdict(lambda: defaultdict(int))
for f in sorted(glob.glob(f"{out}/match_*.json")):
    for cls, c in json.load(open(f)).get("churn", {}).items():
        s[cls] += c["s"]
        ticks[cls] += c["ticks"]
        multi[cls] += c["multi_fight"]
        for g in ("goal", "layer"):
            for k, n in c[g].items():
                counts[cls][(g, k)] += n
for cls in sorted(s):
    mins = s[cls] / 60
    print(f"\n{cls}: {mins:.0f} bot-min, {ticks[cls]} ticks, multi-Fight ticks {multi[cls] / max(ticks[cls], 1):.0%}")
    for (g, k), n in sorted(counts[cls].items(), key=lambda kv: -kv[1]):
        print(f"  {g:5} {k:34} {n:6}  {n / mins:6.2f}/min")
