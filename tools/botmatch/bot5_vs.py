#!/usr/bin/env python3
# usage: bot5_vs.py <dir> [counter...]: v4-vs-v5 match table from t<v5 team>_s<seed>.json metrics
import json, glob, sys, collections as C
rows = []; per = C.defaultdict(lambda: C.defaultdict(float)); keys = sys.argv[2:]
for f in sorted(glob.glob(sys.argv[1] + '/*.json')):
    d = json.load(open(f)); v5 = int(f.split('/')[-1][1])
    dmg = C.Counter(); alive = C.Counter()
    for s in d['ships']:
        t = s['team_id']; dmg[t] += s.get('damage_dealt', s['main_damage'] + s.get('torpedo_damage', 0) + s.get('fire_damage', 0) + s.get('flood_damage', 0) + s.get('sec_damage', 0)); alive[t] += s['alive']
        k = ('v5' if t == v5 else 'v4', s['ship_name']); p = per[k]
        p['n'] += 1; p['dmg'] += s['main_damage'] + s.get('torpedo_damage', 0); p['taken'] += s['damage_taken']; p['alive'] += s['alive']; p['surv'] += s['survival_time']
    w = d.get('winning_team'); res = 'v5' if w == v5 else ('v4' if w in (0, 1) else 'draw')
    rows.append((f.split('/')[-1], res, d['win_reason'], round(d['duration']), alive[v5], alive[1 - v5], round(dmg[v5] / 1e3), round(dmg[1 - v5] / 1e3)))
    if keys:
        b = d.get('bot5', {}); c = {**b.get('counters', {}), **b.get('releases', {})}
        print(f.split('/')[-1], {k: c.get(k, 0) for k in keys})
print("%-12s %5s %-12s %5s %6s %6s %7s %7s" % ("match", "win", "reason", "dur", "v5alive", "v4alive", "v5dmg_k", "v4dmg_k"))
for r in rows: print("%-12s %5s %-12s %5d %6d %6d %7d %7d" % r)
print(dict(C.Counter(r[1] for r in rows)), "dmg v5/v4 = %.2f" % (sum(r[6] for r in rows) / max(1, sum(r[7] for r in rows))))
print("%-4s %-16s %6s %8s %8s %6s %6s" % ("side", "ship", "n", "dmg_k", "taken_k", "alive%", "surv"))
for k in sorted(per, key=lambda k: (k[1], k[0])):
    p = per[k]; n = p['n']; print("%-4s %-16s %6d %8.0f %8.0f %5.0f%% %6.0f" % (k[0], k[1], n, p['dmg'] / n / 1e3, p['taken'] / n / 1e3, 100 * p['alive'] / n, p['surv'] / n))
