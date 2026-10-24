#!/usr/bin/env python3
"""Trade curves from build/engage_curves.csv as SVG: one panel per enemy.
tools/engage_plot.py <us>[:them,...] [csv] [out.svg]"""
import csv
import math
import sys

US, _, ONLY = sys.argv[1].partition(":")
SRC = sys.argv[2] if len(sys.argv) > 2 else "build/engage_curves.csv"
OUT = sys.argv[3] if len(sys.argv) > 3 else f"build/engage_{sys.argv[1].replace(':', '_vs_').replace(',', '_')}.svg"
T_MIN, T_MAX = 10.0, 3000.0
PW, PH, PAD, COLS = 420, 260, 50, 3


def secs(s):
    return T_MAX if s == "inf" else min(max(float(s), T_MIN), T_MAX)


rows = [r for r in csv.DictReader(open(SRC)) if r["us"] == US]
enemies = [e for e in dict.fromkeys(r["them"] for r in rows) if not ONLY or e in ONLY.split(",")]
x_max = max(float(r["range_m"]) for r in rows) / 1000.0

def panel(them, ox, oy):
    pts = [r for r in rows if r["them"] == them]
    gx = lambda km: ox + PAD + km / x_max * (PW - PAD - 10)
    gy = lambda t: oy + 20 + (1 - (math.log10(t) - math.log10(T_MIN)) / (math.log10(T_MAX) - math.log10(T_MIN))) * (PH - PAD - 20)
    out = [f'<text x="{ox + PW / 2}" y="{oy + 14}" text-anchor="middle" font-weight="bold">{US} vs {them}</text>']
    for r in pts:
        km, a, b = float(r["range_m"]) / 1000, secs(r["our_ttk_s"]), secs(r["their_ttk_s"])
        if a < b:
            out.append(f'<rect x="{gx(km)}" y="{oy + 20}" width="{(PW - PAD - 10) * 0.25 / x_max + 0.5}" height="{PH - PAD - 20}" fill="#d8f5d8"/>')
    for t in (10, 30, 100, 300, 1000, 3000):
        out.append(f'<line x1="{gx(0)}" x2="{gx(x_max)}" y1="{gy(t)}" y2="{gy(t)}" stroke="#ddd"/>')
        out.append(f'<text x="{gx(0) - 4}" y="{gy(t) + 4}" text-anchor="end" font-size="10">{t}</text>')
    for km in range(0, int(x_max) + 1, 2):
        out.append(f'<text x="{gx(km)}" y="{oy + PH - PAD + 14}" text-anchor="middle" font-size="10">{km}</text>')
    for key, colour in (("our_gun_m", "#1f5fbf"), ("their_gun_m", "#c0392b")):
        km = float(pts[0][key]) / 1000
        out.append(f'<line x1="{gx(km)}" x2="{gx(km)}" y1="{oy + 20}" y2="{oy + PH - PAD}" stroke="{colour}" stroke-dasharray="4,3"/>')
    for key, colour in (("our_ttk_s", "#1f5fbf"), ("their_ttk_s", "#c0392b")):
        line = " ".join(f"{gx(float(r['range_m']) / 1000):.1f},{gy(secs(r[key])):.1f}" for r in pts)
        out.append(f'<polyline points="{line}" fill="none" stroke="{colour}" stroke-width="2"/>')
    out.append(f'<rect x="{gx(0)}" y="{oy + 20}" width="{PW - PAD - 10}" height="{PH - PAD - 20}" fill="none" stroke="#888"/>')
    return out


cols = min(COLS, len(enemies))
n_rows = math.ceil(len(enemies) / cols)
W, H = max(cols * PW, 640), n_rows * PH + 40
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="sans-serif" font-size="12">',
       f'<rect width="{W}" height="{H}" fill="white"/>',
       f'<text x="10" y="{H - 14}">blue: we kill them (s)   red: they kill us (s)   green: we win   dashed: gun ranges   x: km   y: s (log, 3000 = never)</text>']
for k, them in enumerate(enemies):
    svg += panel(them, (k % cols) * PW, (k // cols) * PH)
svg.append("</svg>")
open(OUT, "w").write("\n".join(svg))
print(OUT)
