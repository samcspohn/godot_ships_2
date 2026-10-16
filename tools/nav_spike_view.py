#!/usr/bin/env python3
"""ASCII view of slow navigate_to calls logged by src/ship/nav_spike_log.gd.

usage: nav_spike_view.py [run_dir] [-n INDEX | --all] [--cols N] [--wide]
run_dir defaults to the newest run under the ships3 user dir. With no -n,
lists the spikes and renders the slowest.
"""
import argparse
import array
import json
import math
import os
import sys

USER_DIR = os.path.expanduser("~/.local/share/godot/app_userdata/ships3/nav_spikes")
MARKS = "0123456789abcdefghijklmnopqrstuvwxyz"


def latest_run():
    runs = sorted(os.path.join(USER_DIR, d) for d in os.listdir(USER_DIR))
    if not runs:
        sys.exit("no runs in " + USER_DIR)
    return runs[-1]


def load(run):
    meta = json.load(open(os.path.join(run, "map.json")))
    sdf = array.array("f")
    with open(os.path.join(run, "sdf.f32"), "rb") as f:
        sdf.frombytes(f.read())
    spikes = [json.loads(l) for l in open(os.path.join(run, "spikes.jsonl")) if l.strip()]
    return meta, sdf, spikes


def sdf_at(meta, sdf, x, z):
    gx = round((x - meta["min_x"]) / meta["cell"])
    gz = round((z - meta["min_z"]) / meta["cell"])
    if gx < 0 or gz < 0 or gx >= meta["w"] or gz >= meta["h"]:
        return None
    return sdf[gz * meta["w"] + gx]


def bbox(rec, wide):
    pts = [rec["pos"], rec["target"]] + rec["path"] + [c[:2] for c in rec["circles"]]
    if wide:
        for x, z, r in rec["circles"]:
            pts += [[x - r, z - r], [x + r, z + r]]
    xs, zs = [p[0] for p in pts], [p[1] for p in pts]
    pad = max(1500.0, 0.08 * max(max(xs) - min(xs), max(zs) - min(zs)))
    return min(xs) - pad, min(zs) - pad, max(xs) + pad, max(zs) + pad


def render(meta, sdf, rec, cols, wide):
    x0, z0, x1, z1 = bbox(rec, wide)
    cw = (x1 - x0) / cols
    rows = max(10, round((z1 - z0) / (cw * 2.0)))
    ch = (z1 - z0) / rows
    grid = [[" "] * cols for _ in range(rows)]
    cl = rec["clearance"]

    def cell_of(x, z):
        return int((x - x0) / cw), int((z - z0) / ch)

    def put(x, z, c):
        i, j = cell_of(x, z)
        if 0 <= i < cols and 0 <= j < rows:
            grid[j][i] = c

    def member(i, j):
        x, z = x0 + (i + 0.5) * cw, z0 + (j + 0.5) * ch
        return tuple(math.hypot(x - cx, z - cz) < r for cx, cz, r in rec["circles"])

    inside = [[member(i, j) for i in range(cols)] for j in range(rows)]
    for j in range(rows):
        for i in range(cols):
            d = sdf_at(meta, sdf, x0 + (i + 0.5) * cw, z0 + (j + 0.5) * ch)
            if d is None:
                grid[j][i] = "%"
                continue
            if d < 0:
                grid[j][i] = "#"
                continue
            m = inside[j][i]
            edge = any(m[k] and not inside[nj][ni][k] for k in range(len(m))
                       for ni, nj in ((i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1))
                       if 0 <= ni < cols and 0 <= nj < rows)
            grid[j][i] = "o" if edge else "+" if d < cl else "." if any(m) else " "

    pts = [rec["pos"]] + rec["path"]
    for (ax, az), (bx, bz) in zip(pts, pts[1:]):
        n = max(1, int(math.hypot(bx - ax, bz - az) / min(cw, ch)))
        for k in range(n + 1):
            put(ax + (bx - ax) * k / n, az + (bz - az) * k / n, "*")
    for k, (x, z) in enumerate(rec["path"]):
        put(x, z, MARKS[k % len(MARKS)])
    for cx, cz, _ in rec["circles"]:
        put(cx, cz, "E")
    put(*rec["target"], "T")
    put(*rec["pos"], "S")

    print("\n".join("".join(r) for r in grid))
    print(f"x {x0:.0f}..{x1:.0f}  z {z0:.0f}..{z1:.0f} (z down)  1 col = {cw:.0f} m, 1 row = {ch:.0f} m")
    print("S ship  T target  0-9a-z waypoints  * route  E enemy (circle centre)  o circle edge  . inside circle")
    print(f"# land  + under hull clearance ({cl:.0f} m)  % off map")


def header(rec):
    plan = rec.get("plan", {})
    flags = [f for f, on in [("SPOTTED", rec.get("spotted")), ("STEALTH", rec.get("stealth")),
                             ("CORNERED", rec.get("cornered"))] if on]
    print(f"{rec['ship']} ({rec['class']}, team {rec['team']})  t={rec['t']:.1f}s  {rec['ms']:.1f} ms  "
          f"hp {rec['hp'] * 100:.0f}%  {' '.join(flags)}")
    print(f"skill {rec.get('skill', '?')}  |  {rec.get('station') or 'no station'}  |  priority {rec.get('priority') or '-'}")
    it = rec.get("intent")
    if it:
        print("intent " + "  ".join(f"{k}={v}" for k, v in it.items()))
    print("plan " + "  ".join(f"{k}={round(v, 2) if isinstance(v, float) else v}" for k, v in plan.items()))
    sx, sz = rec["pos"]
    tx, tz = rec["target"]
    length = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip([rec["pos"]] + rec["path"], rec["path"]))
    print(f"pos ({sx:.0f}, {sz:.0f})  target ({tx:.0f}, {tz:.0f})  straight {math.hypot(tx - sx, tz - sz):.0f} m  "
          f"route {length:.0f} m over {len(rec['path'])} waypoints")
    for k, (cx, cz, r) in enumerate(rec["circles"]):
        inside = " SHIP INSIDE" if math.hypot(sx - cx, sz - cz) < r else ""
        goal = " TARGET INSIDE" if math.hypot(tx - cx, tz - cz) < r else ""
        print(f"  circle {k}: ({cx:.0f}, {cz:.0f}) r {r:.0f}{inside}{goal}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run", nargs="?")
    ap.add_argument("-n", type=int, help="spike index (see list)")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--cols", type=int, default=120)
    ap.add_argument("--wide", action="store_true", help="fit whole circles")
    a = ap.parse_args()
    run = a.run or latest_run()
    meta, sdf, spikes = load(run)
    print(run)
    for k, s in enumerate(spikes):
        print(f"  [{k}] {s['ms']:5.1f} ms  t={s['t']:7.1f}  {s['ship']:<10} {s.get('skill', '?'):<10} "
              f"{s.get('plan', {}).get('mode', '?')}")
    picks = range(len(spikes)) if a.all else [a.n] if a.n is not None else \
        [max(range(len(spikes)), key=lambda k: spikes[k]["ms"])] if spikes else []
    for k in picks:
        print(f"\n=== [{k}] " + "=" * 60)
        header(spikes[k])
        render(meta, sdf, spikes[k], a.cols, a.wide)


if __name__ == "__main__":
    main()
