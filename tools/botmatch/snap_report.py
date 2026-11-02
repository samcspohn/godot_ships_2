#!/usr/bin/env python3
"""Runs of one replay-snapshot scenario against the recorded ending.
usage: snap_report.py <scenario.json> <run dir>"""
import glob
import json
import os
import sys

scn = json.load(open(sys.argv[1]))
src = scn["scenario"].get("source", {})
rec = src.get("final", {})
print("scenario %s (%s at %ds)" % (os.path.basename(sys.argv[1]), src.get("replay", "?"), src.get("at_s", 0)))
print("%-10s %6s %-11s %11s %7s %15s" % ("run", "winner", "reason", "points", "alive", "hp"))
if rec:
    print("%-10s %6s %-11s %11s %7s %15s" % ("recorded", src.get("winning_team"), "", "%d:%d" % tuple(rec["points"]),
        "%d:%d" % tuple(rec["alive"]), "%.0f:%.0f" % tuple(rec["hp"])))
wins = [0, 0, 0]
for f in sorted(glob.glob(os.path.join(sys.argv[2], "run_*.json"))):
    try:
        m = json.load(open(f))
    except (OSError, ValueError):
        print("%-10s no metrics" % os.path.basename(f))
        continue
    alive = [0, 0]
    hp = [0.0, 0.0]
    for s in (m["ships"].values() if isinstance(m["ships"], dict) else m["ships"]):
        if s.get("alive"):
            alive[int(s["team_id"])] += 1
            hp[int(s["team_id"])] += s["max_hp"] * s["hp_frac"]
    w = int(m.get("winning_team", -1))
    wins[w if w >= 0 else 2] += 1
    print("%-10s %6d %-11s %11s %7s %15s" % (os.path.basename(f)[:-5], w, m.get("win_reason", "?"),
        "%d:%d" % tuple(m["points"]), "%d:%d" % tuple(alive), "%.0f:%.0f" % tuple(hp)))
print("team 0 won %d, team 1 won %d, ties %d" % tuple(wins))
