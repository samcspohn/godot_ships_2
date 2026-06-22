#!/usr/bin/env python3
"""
Generate a seamless *looping animated* ocean foam texture (Texture2DArray).

Outputs N_FRAMES RGBA PNGs to ocean_foam_frames/foam_NN.png.

Looping guarantee: every noise field is sampled at a small circular offset
that is a function of (frame / N_FRAMES). At frame 0 and frame N_FRAMES the
offset is identical, so the last frame morphs seamlessly back to the first.

Feature complexity is doubled vs. the original (periods * 2) so there are
more, finer bubble streams per tile.
"""

import os

import numpy as np
from PIL import Image

# ---------------------------------------------------------------------------
RES = 1024
N_FRAMES = 16
# Circular drift radius in [0,1) normalised coords.  Controls how much the
# foam pattern changes across one loop.
DRIFT = 0.15
# ---------------------------------------------------------------------------


def quintic(t):
    return t * t * t * (t * (t * 6 - 15) + 10)


def make_grid(period, seed):
    return np.random.default_rng(seed).random((period, period))


def value_noise_at(x, y, period, grid):
    """Periodic value noise at arbitrary (wrapped) coordinates."""
    xi = np.floor(x).astype(int)
    yi = np.floor(y).astype(int)
    xf = x - xi
    yf = y - yi
    u = quintic(xf)
    v = quintic(yf)
    x0 = xi % period
    x1 = (xi + 1) % period
    y0 = yi % period
    y1 = (yi + 1) % period
    g00 = grid[y0, x0]
    g10 = grid[y0, x1]
    g01 = grid[y1, x0]
    g11 = grid[y1, x1]
    nx0 = g00 * (1 - u) + g10 * u
    nx1 = g01 * (1 - u) + g11 * u
    return nx0 * (1 - v) + nx1 * v


def fbm_at(x, y, periods, seed):
    """fbm over [0,1) domain; each octave period keeps the tile periodic."""
    out = np.zeros_like(x)
    amp = 1.0
    norm = 0.0
    for k, p in enumerate(periods):
        g = make_grid(p, seed + k)
        out += amp * value_noise_at(x * p, y * p, p, g)
        norm += amp
        amp *= 0.5
    return out / norm


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def warped_ridge(X, Y, periods, warp_amt, warp_periods, seed, tx=0.0, ty=0.0):
    """Domain-warped ridged noise.  tx/ty are the per-frame circular offset."""
    wx = fbm_at(X + 0.13 + tx, Y + ty, warp_periods, seed + 11) - 0.5
    wy = fbm_at(X + tx, Y + 0.27 + ty, warp_periods, seed + 23) - 0.5
    qx = X + warp_amt * wx
    qy = Y + warp_amt * wy
    n = fbm_at(qx + tx * 0.4, qy + ty * 0.4, periods, seed + 37)
    return 1.0 - np.abs(2.0 * n - 1.0)


os.makedirs("ocean_foam_frames", exist_ok=True)

lin = np.linspace(0.0, 1.0, RES, endpoint=False)
X, Y = np.meshgrid(lin, lin)

for fi in range(N_FRAMES):
    t = fi / N_FRAMES
    angle = 2.0 * np.pi * t

    # Per-field circular offsets.  Different phase shifts so fields don't
    # move in lockstep — produces more organic-looking animation.
    def off(phase=0.0):
        a = angle + phase
        return DRIFT * np.cos(a), DRIFT * np.sin(a)

    # --- Sinewy streamer network — doubled periods for finer complexity ---
    tx, ty = off(0.0)
    r_coarse = warped_ridge(
        X, Y, [4, 8, 16], warp_amt=0.38, warp_periods=[2, 4], seed=100, tx=tx, ty=ty
    )
    tx, ty = off(np.pi * 0.4)
    r_mid = warped_ridge(
        X, Y, [8, 16, 32], warp_amt=0.30, warp_periods=[3, 6], seed=400, tx=tx, ty=ty
    )
    tx, ty = off(np.pi * 0.8)
    r_fine = warped_ridge(
        X, Y, [16, 32, 64], warp_amt=0.20, warp_periods=[4, 8], seed=600, tx=tx, ty=ty
    )

    veins = np.maximum.reduce(
        [
            smoothstep(0.84, 1.0, r_coarse),
            smoothstep(0.86, 1.0, r_mid) * 0.9,
            smoothstep(0.90, 1.0, r_fine) * 0.7,
        ]
    )

    # --- Bubble grain ---
    tx, ty = off(np.pi * 1.1)
    grain = fbm_at(X + tx, Y + ty, [48, 96, 128], seed=1700)
    grain_mask = smoothstep(0.46, 0.82, grain)
    speck = smoothstep(0.58, 0.86, grain)

    coverage = veins * (0.45 + 0.7 * grain_mask)

    # --- Erode to cut stringy gaps ---
    tx, ty = off(np.pi * 1.5)
    erode = fbm_at(X + 4.1 + tx, Y + 2.3 + ty, [16, 32, 64], seed=1300)
    coverage *= smoothstep(0.05, 0.40, coverage + (erode - 0.5) * 0.55)
    coverage = np.clip(coverage, 0.0, 1.0)

    # --- Colour: white foam, slightly cool-grey in thin/shadowed areas ---
    thickness = smoothstep(0.2, 0.8, coverage)
    cool = np.array([0.80, 0.84, 0.90])
    white = np.array([1.0, 1.0, 1.0])
    rgb = (
        cool[None, None, :] * (1.0 - thickness[..., None])
        + white[None, None, :] * thickness[..., None]
    )
    rgb = np.clip(rgb + (speck * 0.10)[..., None], 0.0, 1.0)

    # --- Alpha: opaque where foam exists, hard edge with thin feather ---
    alpha = coverage * (0.72 + 0.28 * speck)
    alpha = np.clip(alpha / 0.15, 0.0, 1.0)

    rgba = np.zeros((RES, RES, 4), dtype=np.uint8)
    rgba[..., :3] = (rgb * 255).astype(np.uint8)
    rgba[..., 3] = (alpha * 255).astype(np.uint8)

    path = f"ocean_foam_frames/foam_{fi:02d}.png"
    Image.fromarray(rgba, mode="RGBA").save(path)
    print(f"  [{fi + 1:2d}/{N_FRAMES}] {path}")

print("Done.")
