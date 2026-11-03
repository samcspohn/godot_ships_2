#!/usr/bin/env python3
"""CPU per simulated second per arm, from the <metrics>.time files ab.sh's godot wrapper writes.
usage: cpu_report.py name=dir [name=dir ...]"""
import glob
import json
import os
import statistics
import sys

print("\nCPU time (user+sys) per simulated second")
print("%-6s %5s %9s %9s %9s %9s" % ("arm", "n", "total", "mean", "p50", "p90"))
for arg in sys.argv[1:]:
    name, d = arg.split("=", 1)
    per, cpu_sum, sim_sum = [], 0.0, 0.0
    for t in glob.glob(os.path.join(d, "*.json.time")):
        try:
            wall, user, sys_s = map(float, open(t).read().split()[-3:])
            sim = float(json.load(open(t[:-5]))["duration"])
        except (OSError, ValueError, KeyError):
            continue
        if sim <= 0:
            continue
        per.append((user + sys_s) / sim)
        cpu_sum += user + sys_s
        sim_sum += sim
    if not per:
        print("%-6s no timings" % name)
        continue
    per.sort()
    print("%-6s %5d %9.3f %9.3f %9.3f %9.3f" % (name, len(per), cpu_sum / sim_sum, statistics.mean(per),
        per[len(per) // 2], per[int(len(per) * 0.9)]))
