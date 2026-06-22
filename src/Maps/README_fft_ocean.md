# FFT Ocean — wiring reference

Five compute shaders that fill `fft_displacement` and `fft_derivatives` for the
spatial shader. N = grid size (256 is a good default), C = cascade_count (≤ 4),
LOG2N = log2(N).

## Textures (all created on the RenderingDevice)

| name             | type             | format        | layers | size            | usage                          | persistence        |
|------------------|------------------|---------------|--------|-----------------|--------------------------------|--------------------|
| `h0_tex`         | image2DArray     | RGBA32F       | C      | N×N             | STORAGE + SAMPLING             | until sea state changes |
| `a0,a1,a2`       | image2DArray     | RG32F         | C      | N×N             | STORAGE                        | per frame (set A)  |
| `b0,b1,b2`       | image2DArray     | RG32F         | C      | N×N             | STORAGE                        | per frame (set B)  |
| `butterfly_tex`  | image2D          | RGBA32F       | -      | LOG2N × N       | STORAGE + SAMPLING             | once               |
| `displacement`   | image2DArray     | RGBA32F       | C      | N×N             | STORAGE + SAMPLING             | output (per frame) |
| `derivatives`    | image2DArray     | RGBA32F       | C      | N×N             | STORAGE + SAMPLING             | output (per frame) |

`displacement` and `derivatives` need SAMPLING so you can wrap them in
`Texture2DArrayRD` (set `texture_rd_rid`) and assign to the spatial material's
`fft_displacement` / `fft_derivatives` uniforms.

`a*` / `b*` are the ping-pong pair. `spectrum_update` writes set A; after
2·LOG2N butterfly stages the result is back in set A; `compose` reads A.

## OceanParams UBO (std140, 96 bytes) — bound where each shader declares binding 0

| offset | type   | field          |
|--------|--------|----------------|
| 0      | vec4   | patch_sizes    | L per cascade (m), large→fine, e.g. (1024,128,24,0) |
| 16     | vec4   | cutoff_low     | min \|k\| per cascade |
| 32     | vec4   | cutoff_high    | max \|k\| per cascade |
| 48     | vec2   | wind           | direction*speed (m/s) |
| 56     | float  | fetch          | m (e.g. 100000) |
| 60     | float  | gravity        | 9.81 |
| 64     | float  | depth          | m (e.g. 1000 for deep) |
| 68     | float  | amplitude      | global tuning (start ~1) |
| 72     | float  | suppress       | small-wave cutoff length m (e.g. 0.5) |
| 76     | float  | _pad0          | |
| 80     | uint   | seed           | |
| 84     | int    | n              | N |
| 88     | int    | cascade_count  | C |
| 92     | int    | _pad1          | |

Band limiting: set `cutoff_high[i]` = `cutoff_low[i+1]` so each wavelength is
owned by exactly one cascade. A simple split: boundary between cascade i and i+1
at k ≈ π / patch_sizes[i+1] (Nyquist of the finer patch). First low = 0, last
high = large.

## Per-shader bindings (all set 0)

**spectrum_initial** — `0` UBO, `1` h0_tex(w)
**spectrum_update**  — `0` UBO, `1` h0_tex(r), `2` a0(w), `3` a1(w), `4` a2(w);
                       push: `float time`
**butterfly_precompute** — `0` butterfly_tex(w); push: `int n, int log2n`
**fft_butterfly** — `0..2` a0,a1,a2, `3..5` b0,b1,b2, `6` butterfly_tex(r);
                    push: `int stage, int direction, int pingpong`
**compose** — `0..2` a0,a1,a2(r), `3` displacement(w), `4` derivatives(w);
              push: `float disp_scale, float slope_scale`

## Dispatch order

Once (ever):
    butterfly_precompute   dispatch( LOG2N, N/16, 1 )

On sea-state change (wind/fetch/direction):
    spectrum_initial       dispatch( N/16, N/16, C )

Per frame:
    spectrum_update(time)  dispatch( N/16, N/16, C )
    for g in 0 .. 2*LOG2N-1:
        direction = (g < LOG2N) ? 0 : 1
        stage     = (g < LOG2N) ? g : g - LOG2N
        pingpong  = g & 1
        fft_butterfly(stage, direction, pingpong)  dispatch( N/16, N/16, C )
    compose(disp_scale, slope_scale)               dispatch( N/16, N/16, C )

## Notes / tuning

- The butterfly does an unnormalized inverse DFT, which is what Tessendorf's
  formulation expects (no 1/N²). Tune visual size with `disp_scale` + `amplitude`.
- The `spectrum()` function is an approximate JONSWAP+cos² spread. It's isolated
  so you can drop in an empirical directional spectrum without touching the FFT.
- `choppiness` (horizontal displacement λ) lives in the spatial shader, so the
  compose pass stores raw Dx/Dz.
- `derivatives.ba` is reserved for the folding/Jacobian foam terms (the FOAM
  HOOK in the spatial shader). Adding it = two more packed fields + one more IFFT.
