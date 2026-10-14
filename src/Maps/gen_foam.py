#!/usr/bin/env python3
"""Tiling foam texture for ocean.gdshader -> ocean_foam.png.

R: reveal order, histogram-equalised so coverage c reveals fraction c of the tile.
G: bubble brightness detail.
B: churn reveal order for wakes and blasts, equalised like R.
"""

import os

import numpy as np
from PIL import Image

RES = 1024
SEED = 7


def worley(cells, rng):
    pts = rng.random((cells, cells, 2))
    y, x = np.mgrid[0:RES, 0:RES] / RES * cells
    cx, cy = np.floor(x).astype(int), np.floor(y).astype(int)
    f1 = np.full((RES, RES), 9.0)
    f2 = np.full((RES, RES), 9.0)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            nx, ny = cx + dx, cy + dy
            p = pts[ny % cells, nx % cells]
            d = np.hypot(nx + p[..., 0] - x, ny + p[..., 1] - y)
            f2 = np.where(d < f1, f1, np.minimum(f2, d))
            f1 = np.minimum(f1, d)
    return f1, f2


def value_fbm(base, octaves, rng):
    out = np.zeros((RES, RES))
    amp, total = 1.0, 0.0
    for o in range(octaves):
        n = base << o
        grid = rng.random((n, n))
        t = np.arange(RES) / RES * n
        i0 = np.floor(t).astype(int)
        f = t - i0
        f = f * f * (3 - 2 * f)
        i1 = (i0 + 1) % n
        rows = grid[i0][:, i0] * (1 - f)[None, :] + grid[i0][:, i1] * f[None, :]
        rows1 = grid[i1][:, i0] * (1 - f)[None, :] + grid[i1][:, i1] * f[None, :]
        out += amp * (rows * (1 - f)[:, None] + rows1 * f[:, None])
        total += amp
        amp *= 0.5
    return out / total


def equalise(a):
    flat = a.ravel()
    ranks = np.empty_like(flat)
    ranks[np.argsort(flat, kind="stable")] = np.arange(flat.size)
    return (ranks / (flat.size - 1)).reshape(a.shape)


def blur(a, r):
    n = int(np.ceil(3 * r))
    shifts = np.arange(-n, n + 1)
    k = np.exp(-0.5 * (shifts / r) ** 2)
    k /= k.sum()
    for axis in (0, 1):
        a = sum(w * np.roll(a, s, axis) for s, w in zip(shifts, k))
    return a


def sample_wrap(a, x, y):
    x = x % RES
    y = y % RES
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    fx, fy = x - x0, y - y0
    x1, y1 = (x0 + 1) % RES, (y0 + 1) % RES
    top = a[y0, x0] * (1 - fx) + a[y0, x1] * fx
    bot = a[y1, x0] * (1 - fx) + a[y1, x1] * fx
    return top * (1 - fy) + bot * fy


def churn(rng):
    billow = np.zeros((RES, RES))
    amp, total = 1.0, 0.0
    for o in range(5):
        billow += amp * np.abs(2.0 * value_fbm(12 << o, 1, rng) - 1.0)
        total += amp
        amp *= 0.6
    billow = 1.0 - billow / total
    y, x = np.mgrid[0:RES, 0:RES].astype(float)
    wx = value_fbm(6, 3, rng) - 0.5
    wy = value_fbm(6, 3, rng) - 0.5
    warped = sample_wrap(billow, x + wx * RES * 0.12, y + wy * RES * 0.12)
    return equalise(blur(0.8 * warped + 0.2 * value_fbm(4, 2, rng), 1.0))


def main():
    rng = np.random.default_rng(SEED)
    f1a, f2a = worley(10, rng)
    f1b, f2b = worley(26, rng)
    f1c, _ = worley(90, rng)
    lace_a = np.exp(-(f2a - f1a) / 0.10)
    lace_b = np.exp(-(f2b - f1b) / 0.12)
    blobs = value_fbm(4, 4, rng)
    order = 0.45 * lace_a + 0.25 * lace_b + 0.30 * blobs
    order = equalise(blur(order, 1.5))
    bubbles = 1.0 - np.clip(f1c / 0.7, 0, 1) ** 2
    detail = 0.55 + 0.45 * equalise(blur(bubbles + 0.3 * lace_b, 1.0))
    img = np.zeros((RES, RES, 4), np.uint8)
    img[..., 0] = np.round(order * 255)
    img[..., 1] = np.round(detail * 255)
    img[..., 2] = np.round(churn(rng) * 255)
    img[..., 3] = 255
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ocean_foam.png")
    Image.fromarray(img, "RGBA").save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
