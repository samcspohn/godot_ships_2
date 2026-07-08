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
# Final blur pass (pixels, at RES resolution): widens the transition zones
# between streamers/background and between different intensity levels,
# amplifying the graded (non-binary) alpha established by the intensity field.
BLUR_RADIUS = 3
BLUR_PASSES = 2
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


def tileable_blur(img, radius, passes=2):
    """Periodic (wrap-around) box blur via FFT convolution, repeated a few
    times to approximate a Gaussian. Stays exactly tileable since the FFT
    treats the image as one period."""
    res = img.shape[0]
    k = 2 * radius + 1
    kernel = np.zeros((res, res))
    kernel[:k, :k] = 1.0 / (k * k)
    kernel = np.roll(kernel, (-radius, -radius), axis=(0, 1))
    kernel_f = np.fft.fft2(kernel)
    out = img
    for _ in range(passes):
        out = np.real(np.fft.ifft2(np.fft.fft2(out) * kernel_f))
    return out


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

    # Wide smoothstep bands (not a near-binary threshold): this keeps the
    # ridged noise's natural, continuous falloff away from each ridge crest,
    # so alpha grades smoothly across a streamer's whole width instead of
    # plateauing at a flat value with only a thin transition at its edge.
    # fbm values cluster near the middle of their range (CLT), so a ridged
    # transform's "ridge" (near 1) covers much more area than its "valley"
    # (near 0) — widening this threshold explodes coverage to ~everything
    # rather than gently broadening it. Keep it narrow (for a sparse network
    # with real gaps) and add along-length variation separately below.
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

    # --- Broad intensity variation so different streamers/patches land at
    # genuinely different alpha levels instead of all clustering near the same
    # high value. Without this, the shader's alpha-cutoff has almost nothing
    # to work with (any reasonable threshold reveals either ~all or ~none of
    # the coverage), since the vein construction above makes every streamer's
    # *edge* crisp but gives them all roughly the same *peak* alpha. ---
    tx, ty = off(np.pi * 1.9)
    intensity = fbm_at(X + 5.3 + tx, Y + 8.1 + ty, [3, 5], seed=2200)
    intensity = (
        0.15 + 0.85 * intensity
    )  # keep a floor so weak streamers aren't fully killed

    # --- Mid-frequency variation *along* each streamer's own length (period
    # comparable to the vein scales themselves), so a single streamer rises
    # and falls through many alpha levels along its length instead of being a
    # flat plateau bounded only by a thin edge. ---
    tx, ty = off(np.pi * 2.3)
    midvar = fbm_at(X + 9.7 + tx, Y + 3.3 + ty, [10, 20], seed=2600)
    midvar = 0.25 + 0.75 * midvar

    # --- Alpha: smooth coverage gradient (used as an alpha-cutoff mask by the
    # shader, not a straight opacity multiply, so keep it continuous). ---
    alpha = np.clip(coverage * (0.72 + 0.28 * speck) * intensity * midvar, 0.0, 1.0)

    # --- Blur pass: widens transition zones and blends adjacent intensity
    # levels together, amplifying the graded alpha effect. ---
    alpha = np.clip(tileable_blur(alpha, BLUR_RADIUS, BLUR_PASSES), 0.0, 1.0)
    for c in range(3):
        rgb[..., c] = tileable_blur(rgb[..., c], BLUR_RADIUS, BLUR_PASSES)
    rgb = np.clip(rgb, 0.0, 1.0)

    rgba = np.zeros((RES, RES, 4), dtype=np.uint8)
    rgba[..., :3] = (rgb * 255).astype(np.uint8)
    rgba[..., 3] = (alpha * 255).astype(np.uint8)

    path = f"ocean_foam_frames/foam_{fi:02d}.png"
    Image.fromarray(rgba, mode="RGBA").save(path)
    print(f"  [{fi + 1:2d}/{N_FRAMES}] {path}")

print("Done.")
