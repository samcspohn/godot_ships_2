#!/usr/bin/env python3
"""Per torpedo in a scenario log (TORP lines) against a traced target's SCN track: closest approach, and where
the target was at that moment along its own heading relative to the torpedo (+ ahead: we under-led)."""
import json, math, re, sys

log, target = sys.argv[1], sys.argv[2]
lines = open(log, errors="replace").read().splitlines()
start = next(float(re.search(r"clock ([\d.]+)", l).group(1)) for l in lines if l.startswith("SCN start"))
track = []
for l in lines:
    m = re.match(rf"SCN t=\s*([\d.]+) {re.escape(target)} hp=\d+ at=\(([-\d]+),([-\d]+)\) hdg=([-\d]+)", l)
    if m:
        track.append((start + float(m.group(1)), float(m.group(2)), float(m.group(3)), math.radians(float(m.group(4)))))

def at(t):
    for a, b in zip(track, track[1:]):
        if a[0] <= t <= b[0]:
            f = (t - a[0]) / (b[0] - a[0])
            return (a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, b[3])
    return None

for l in lines:
    if not l.startswith("TORP "):
        continue
    d = json.loads(l[5:])
    t0, (px, pz), v = d["t"], d["pos"], d["speed"]
    for i, (dx, dz) in enumerate(d["dirs"]):
        n = math.hypot(dx, dz)
        dx, dz = dx / n, dz / n
        best = None
        t = t0
        while t < track[-1][0]:
            s = at(t)
            if s:
                tx, tz = px + dx * v * (t - t0), pz + dz * v * (t - t0)
                dist = math.hypot(s[0] - tx, s[1] - tz)
                if best is None or dist < best[0]:
                    ahead = (s[0] - tx) * math.sin(s[2]) + (s[1] - tz) * math.cos(s[2])
                    best = (dist, t - t0, ahead)
            t += 0.1
        if best:
            print(f"launch t+{t0 - start:5.1f}s tube {i}: closest {best[0]:6.0f} m at {best[1]:5.1f}s run, target {best[2]:+6.0f} m along its heading")
