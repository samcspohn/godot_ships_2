#!/usr/bin/env python3
"""Priority by range from build/priority_curves.csv as SVG: one panel per hull of ours, a line per enemy.
tools/priority_plot.py [us,...] [csv] [out.svg]"""
import csv
import math
import sys

ONLY = sys.argv[1].split(",") if len(sys.argv) > 1 and sys.argv[1] else []
SRC = sys.argv[2] if len(sys.argv) > 2 else "build/priority_curves.csv"
OUT = sys.argv[3] if len(sys.argv) > 3 else "build/priority_curves.svg"
Y_MIN, Y_MAX = 0.01, 100.0
PW, PH, PAD, COLS = 460, 300, 50, 2
COLOURS = ["#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b", "#e377c2", "#17becf", "#7f7f7f", "#bcbd22"]

rows = list(csv.DictReader(open(SRC)))
us_all = [u for u in dict.fromkeys(r["us"] for r in rows) if not ONLY or u in ONLY]
them_all = list(dict.fromkeys(r["them"] for r in rows))
x_max = max(float(r["range_m"]) for r in rows) / 1000.0


def panel(us, ox, oy):
    pts = [r for r in rows if r["us"] == us]
    gx = lambda km: ox + PAD + km / x_max * (PW - PAD - 10)
    gy = lambda v: oy + 20 + (1 - (math.log10(min(max(v, Y_MIN), Y_MAX)) - math.log10(Y_MIN)) / (math.log10(Y_MAX) - math.log10(Y_MIN))) * (PH - PAD - 20)
    out = [f'<text x="{ox + PW / 2}" y="{oy + 14}" text-anchor="middle" font-weight="bold">{us}</text>']
    for v in (0.01, 0.1, 1, 10, 100):
        out.append(f'<line x1="{gx(0)}" x2="{gx(x_max)}" y1="{gy(v)}" y2="{gy(v)}" stroke="#ddd"/>')
        out.append(f'<text x="{gx(0) - 4}" y="{gy(v) + 4}" text-anchor="end" font-size="10">{v:g}</text>')
    for km in range(0, int(x_max) + 1, 2):
        out.append(f'<text x="{gx(km)}" y="{oy + PH - PAD + 14}" text-anchor="middle" font-size="10">{km}</text>')
    gun = float(pts[0]["our_gun_m"]) / 1000
    out.append(f'<line x1="{gx(gun)}" x2="{gx(gun)}" y1="{oy + 20}" y2="{oy + PH - PAD}" stroke="#444" stroke-dasharray="4,3"/>')
    for k, them in enumerate(them_all):
        line = " ".join(f"{gx(float(r['range_m']) / 1000):.1f},{gy(float(r['score'])):.1f}" for r in pts if r["them"] == them)
        out.append(f'<polyline points="{line}" fill="none" stroke="{COLOURS[k % len(COLOURS)]}" stroke-width="2"/>')
    out.append(f'<rect x="{gx(0)}" y="{oy + 20}" width="{PW - PAD - 10}" height="{PH - PAD - 20}" fill="none" stroke="#888"/>')
    return out


cols = min(COLS, len(us_all))
n_rows = math.ceil(len(us_all) / cols)
W, H = max(cols * PW, 640), n_rows * PH + 60
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="sans-serif" font-size="12">',
       f'<rect width="{W}" height="{H}" fill="white"/>',
       f'<text x="10" y="{H - 34}">priority (%HP/s)² by enemy range, log; x: km; dashed: our gun range (past it: reach-discounted)</text>']
for k, them in enumerate(them_all):
    svg.append(f'<text x="{10 + k * 110}" y="{H - 12}" fill="{COLOURS[k % len(COLOURS)]}" font-weight="bold">{them}</text>')
for k, us in enumerate(us_all):
    svg += panel(us, (k % cols) * PW, (k // cols) * PH)
svg.append("</svg>")
open(OUT, "w").write("\n".join(svg))
print(OUT)
