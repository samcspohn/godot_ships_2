#!/usr/bin/env python3
# usage: bot5_learn.py <metrics.json>... -> assets/bot5_calib.json (real / raw predicted main-battery damage per class key;
# stance probe factors per class|kind and damage part)
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
# Stance probes: per "class|turn|astern" key, one real/predicted factor per part (on-us guns, other guns, secondaries,
# torpedoes) by non-negative least squares over the probes, ridged toward the class "in" factor.
import itertools
import numpy as np

PARTS = ["on", "by", "sec", "torp"]
MIN_PROBES = 200
RIDGE = 0.01  # share of the mean diagonal pulling each factor to the prior

st = collections.defaultdict(lambda: np.zeros(27))
for path in sys.argv[1:]:
    for k, v in json.load(open(path)).get("bot5", {}).get("stance_calib", {}).items():
        st[k] += np.array(v)

out["stance"] = {}
for k, v in sorted(st.items()):
    n, sr, srr, sp, spr, spp = v[0], v[1], v[2], v[3:7], v[7:11], v[11:27].reshape(4, 4)
    x0 = np.full(4, out["in"].get(k.split("|")[0], 1.0))
    lam = RIDGE * max(np.mean(np.diag(spp)), 1.0)
    best = (np.inf, np.zeros(4))
    for m in itertools.product([0, 1], repeat=4):
        idx = [i for i in range(4) if m[i]]
        x = np.zeros(4)
        if idx:
            A = spp[np.ix_(idx, idx)] + lam * np.eye(len(idx))
            x[idx] = np.linalg.solve(A, spr[idx] + lam * x0[idx])
            if (x < 0).any():
                continue
        obj = x @ spp @ x - 2 * spr @ x + srr + lam * np.sum((x - x0) ** 2)
        if obj < best[0]:
            best = (obj, x)
    x = best[1]
    sse = lambda f: f @ spp @ f - 2 * spr @ f + srr
    print("stance %-10s n %6d real %9.0f pred raw %s  prior k %.3f -> pred %9.0f  fit %s -> pred %9.0f  rmse/probe %6.0f -> %6.0f%s" % (
        k, n, sr, "/".join("%.0f" % p for p in sp), x0[0], sp @ x0, "/".join("%.3f" % f for f in x), sp @ x,
        np.sqrt(max(sse(x0), 0) / n), np.sqrt(max(sse(x), 0) / n), "" if n >= MIN_PROBES else "  (thin, skipped)"))
    if n >= MIN_PROBES:
        out["stance"][k] = [round(float(f), 4) for f in x]
json.dump(out, open("assets/bot5_calib.json", "w"), indent=1, sort_keys=True)
print("wrote assets/bot5_calib.json")
