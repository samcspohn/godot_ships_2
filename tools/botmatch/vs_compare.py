#!/usr/bin/env python3
# usage: vs_compare.py label=dir ...  v5 side of each make-vs run: wins, damage share, per-class taken (main/torp), citadels dealt
import json, glob, sys, statistics as S, collections as C

def load(d):
    share, wins, n = [], 0, 0
    per = C.defaultdict(lambda: C.defaultdict(float))
    for f in sorted(glob.glob(d + '/t*_s*.json')):
        m = json.load(open(f)); v5 = int(f.split('/')[-1][1]); dm = C.Counter()
        for s in m['ships']:
            dm[s['team_id']] += s['main_damage'] + s.get('torpedo_damage', 0)
            if s['team_id'] == v5:
                p = per[s['ship_name']]; p['n'] += 1
                for k in ('damage_taken', 'torpedo_taken', 'torpedo_hits_taken', 'citadel_count', 'main_damage', 'survival_time'):
                    p[k] += s.get(k, 0)
        share.append(dm[v5] / max(1, dm[0] + dm[1])); wins += m.get('winning_team') == v5; n += 1
    return share, wins, n, per

runs = [(a.split('=', 1)[0], load(a.split('=', 1)[1])) for a in sys.argv[1:]]
for lab, (sh, w, n, _) in runs:
    print("%-10s n=%3d wins=%3d share=%.3f +- %.3f" % (lab, n, w, S.mean(sh), S.stdev(sh) / len(sh) ** .5))
print("%-16s" % "v5 ship" + "".join("%28s" % lab for lab, _ in runs))
print("%-16s" % "" + "".join("%28s" % "taken_k torp_k citD dealt_k" for _ in runs))
for ship in sorted(runs[0][1][3]):
    row = "%-16s" % ship
    for _, (_, _, _, per) in runs:
        p = per[ship]; k = max(1, p['n'])
        row += "%28s" % ("%5.0f %6.1f %4.1f %6.0f" % (p['damage_taken'] / k / 1e3, p['torpedo_taken'] / k / 1e3, p['citadel_count'] / k, p['main_damage'] / k / 1e3))
    print(row)
