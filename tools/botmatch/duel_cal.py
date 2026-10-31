#!/usr/bin/env python3
"""Fit the stance duel's real/predicted damage factors from metrics duel_cal probes; writes assets/duel_calibration.json.
usage: duel_cal.py <run dir> [<run dir> ...]"""
import glob, json, sys
from collections import defaultdict

rows = defaultdict(lambda: [0.0, 0.0, 0.0, 0.0, 0])
for d in sys.argv[1:]:
    for f in glob.glob(f"{d}/**/match_*.json", recursive=True) + glob.glob(f"{d}/*.json"):
        try:
            cal = json.load(open(f)).get("duel_cal", {})
        except Exception:
            continue
        for k, r in cal.items():
            for i in range(5):
                rows[k][i] += r[i]
tot = [sum(r[i] for r in rows.values()) for i in range(5)]
ratio = lambda real, pred: real / pred if pred > 0 else 1.0
out = {"all": {"out": ratio(tot[1], tot[0]), "in": ratio(tot[3], tot[2]), "n": tot[4]}, "pairs": {}}
print(f"{'pair':8} {'n':>6} {'pred dealt':>11} {'real':>10} {'out':>5} | {'pred taken':>11} {'real':>10} {'in':>5}")
for k in sorted(rows):
    r = rows[k]
    out["pairs"][k] = {"out": ratio(r[1], r[0]), "in": ratio(r[3], r[2]), "n": r[4]}
    print(f"{k:8} {r[4]:6d} {r[0]:11.0f} {r[1]:10.0f} {ratio(r[1], r[0]):5.2f} | {r[2]:11.0f} {r[3]:10.0f} {ratio(r[3], r[2]):5.2f}")
print(f"{'all':8} {tot[4]:6d} out {out['all']['out']:.2f} in {out['all']['in']:.2f}")
json.dump(out, open("assets/duel_calibration.json", "w"), indent=1)
print("wrote assets/duel_calibration.json")
