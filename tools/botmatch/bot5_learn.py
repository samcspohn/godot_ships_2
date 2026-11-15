#!/usr/bin/env python3
# usage: bot5_learn.py <metrics.json>... -> assets/bot5_calib.json (real / raw predicted main-battery damage per class key)
import json, sys, collections

MIN_PRED = 20000.0  # damage predicted before a key's ratio is trusted
PRIOR = 10000.0     # pulls thin keys toward 1

tot = collections.defaultdict(lambda: [0.0, 0.0, 0.0])
for path in sys.argv[1:]:
    for k, v in json.load(open(path)).get("bot5", {}).get("calib", {}).items():
        for i in range(3):
            tot[k][i] += v[i]

out = {"in": {}, "out": {}}
for k, (pred, real, mins) in sorted(tot.items()):
    side, key = k.split("|", 1)
    ratio = (real + PRIOR) / (pred + PRIOR)
    print("%-12s %-8s pred %9.0f real %9.0f min %7.1f  k %.3f%s" % (k, side, pred, real, mins, ratio, "" if pred >= MIN_PRED else "  (thin, skipped)"))
    if pred >= MIN_PRED:
        out[side][key] = round(ratio, 4)
json.dump(out, open("assets/bot5_calib.json", "w"), indent=1, sort_keys=True)
print("wrote assets/bot5_calib.json")
