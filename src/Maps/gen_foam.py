#!/usr/bin/env python3
"""Tiling foam texture for ocean.gdshader -> ocean_foam.png.

R: reveal order, histogram-equalised so coverage c reveals fraction c of the tile.
G: whorl reveal order (churn advected through a curl field) for wakes, splashes and spray.
B: churn reveal order for wakes and blasts, equalised like R.
A: soft blotch noise (signed, 0.5 = 0) that breaks wake and splash coverage into patches.
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


def blur_fft(a, sigma):
    f = np.fft.fftfreq(RES)
    k = np.exp(-2.0 * (np.pi * sigma) ** 2 * (f[:, None] ** 2 + f[None, :] ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(a) * k))


def sample_wrap(a, x, y):
    x = x % RES
    y = y % RES
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    fx, fy = x - x0, y - y0
    x1, y1 = (x0 + 1) % RES, (y0 + 1) % RES
    top = a[y0, x0] * (1 - fx) + a[y0, x1] * fx
    bot = a[y1, x0] * (1 - fx) + a[y1, x1] * fx
    return top * (1 - fy) + bot * fy


def churn(rng, raw=False):
    billow = np.zeros((RES, RES))
    amp, total = 1.0, 0.0
    for o in range(5):
        billow += amp * np.abs(2.0 * value_fbm(12 << o, 1, rng) - 1.0)
        total += amp
        amp *= 0.6
    billow = billow / total
    y, x = np.mgrid[0:RES, 0:RES].astype(float)
    wx = value_fbm(6, 3, rng) - 0.5
    wy = value_fbm(6, 3, rng) - 0.5
    warped = sample_wrap(billow, x + wx * RES * 0.12, y + wy * RES * 0.12)
    mixed = 0.8 * warped + 0.2 * value_fbm(4, 2, rng)
    return mixed if raw else equalise(blur(mixed, 1.0))


def whorls(base, rng):
    psi = blur_fft(rng.standard_normal((RES, RES)), RES / 14) + 0.5 * blur_fft(rng.standard_normal((RES, RES)), RES / 40)
    psi /= psi.std()
    vx = (np.roll(psi, -1, 0) - np.roll(psi, 1, 0)) * 0.5
    vy = -(np.roll(psi, -1, 1) - np.roll(psi, 1, 1)) * 0.5
    step = 6.0 / np.abs(np.stack([vx, vy])).max()
    y, x = np.mgrid[0:RES, 0:RES].astype(float)
    for _ in range(24):
        u = sample_wrap(vx, x, y)
        v = sample_wrap(vy, x, y)
        x, y = x - u * step, y - v * step
    return equalise(blur(sample_wrap(base, x, y), 1.0))


def blotches(rng):
    # Blurred white noise is isotropic; lattice noise lines blotches up in rows.
    n = np.zeros((RES, RES))
    for sigma, amp in ((RES / 30, 1.0), (RES / 75, 0.5), (RES / 180, 0.3)):
        layer = blur_fft(rng.standard_normal((RES, RES)), sigma)
        n += amp * layer / layer.std()
    y, x = np.mgrid[0:RES, 0:RES].astype(float)
    wx = value_fbm(8, 3, rng) - 0.5
    wy = value_fbm(8, 3, rng) - 0.5
    n = sample_wrap(n, x + wx * RES * 0.06, y + wy * RES * 0.06)
    n = (n - n.mean()) / n.std() * 0.32
    return np.clip(0.5 + 0.5 * n, 1 / 255, 1.0)


def main():
    rng = np.random.default_rng(SEED)
    f1a, f2a = worley(10, rng)
    f1b, f2b = worley(26, rng)
    worley(90, rng)  # keeps the later channels on their original random streams
    lace_a = np.exp(-(f2a - f1a) / 0.10)
    lace_b = np.exp(-(f2b - f1b) / 0.12)
    blobs = value_fbm(4, 4, rng)
    order = 0.45 * lace_a + 0.25 * lace_b + 0.30 * blobs
    order = equalise(blur(order, 1.5))
    img = np.zeros((RES, RES, 4), np.uint8)
    img[..., 0] = np.round(order * 255)
    churn_raw = churn(rng, raw=True)
    img[..., 1] = np.round(whorls(churn_raw, np.random.default_rng(SEED + 1)) * 255)
    img[..., 2] = np.round(equalise(blur(churn_raw, 1.0)) * 255)
    img[..., 3] = np.round(blotches(rng) * 255)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ocean_foam.png")
    Image.fromarray(img, "RGBA").save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
