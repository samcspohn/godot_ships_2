#!/usr/bin/env python3
"""usage: aggregate.py <dir with match_*.json> -> per_bot.csv, per_ship.csv"""
import csv, glob, json, os, sys
from collections import defaultdict

FIELDS = ["total_damage", "damage_taken", "spotting_damage", "potential_damage",
          "frags", "survival_time", "won", "hp_frac"]

out_dir = sys.argv[1]
rows = []
for path in sorted(glob.glob(os.path.join(out_dir, "match_*.json"))):
    m = json.load(open(path))
    for s in m["ships"]:
        s = dict(s, match=os.path.basename(path), duration=m["duration"])
        s["won"] = float(s["won"])
        rows.append(s)
if not rows:
    sys.exit(f"no match_*.json in {out_dir}")

def table(key_fn, name):
    groups = defaultdict(list)
    for r in rows:
        groups[key_fn(r)].append(r)
    path = os.path.join(out_dir, name)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["key", "n"] + FIELDS)
        for k in sorted(groups):
            g = groups[k]
            w.writerow([k, len(g)] + [round(sum(float(r[c]) for r in g) / len(g), 3) for c in FIELDS])
    return path, groups

matches = len({r["match"] for r in rows})
print(f"{matches} matches, {len(rows)} ship-rows")
for key_fn, name in [(lambda r: f'{r["player_name"]}:{r["ship_name"]}:{r["aptitude"]}', "per_bot.csv"),
                     (lambda r: r["ship_name"], "per_ship.csv")]:
    path, groups = table(key_fn, name)
    print(f"\n{name}")
    print(f'{"key":36} {"n":>3} ' + " ".join(f"{c[:9]:>9}" for c in FIELDS))
    for k in sorted(groups):
        g = groups[k]
        print(f"{k:36} {len(g):>3} " + " ".join(f"{sum(float(r[c]) for r in g) / len(g):>9.2f}" for c in FIELDS))
