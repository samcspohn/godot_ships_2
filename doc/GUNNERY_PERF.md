# Bot gunnery: performance and accuracy by version

One row per change. Box: 256 threads (2 NUMA nodes, SMT). Production target: ~4 threads.

## Generic db (offline bake, `make bake`)

| version | date | H44 sweep, 16 threads | fleet bake, 256 threads | armour walk | db | notes |
|---|---|---|---|---|---|---|
| v18 | 2026-11-01 | 58.9 s (17.6M walks) | ~50 s | ~40 us/walk (~50 with EV) | 56.3 MB | bounce classes; profile: `raycast_local` 71%, EV `u_pass` 18%, `part_at` 2% |
| v18 + raycast opt | 2026-11-04 | 39.0 s | 39.6 s (sweep 35.3) | ~22 us/walk | 56.3 MB | near-first BVH traversal, `part_at` bounds + any-hit, first hit reused across the sweep. Output byte-identical except 2/756 H45 buckets (an exact edge tie now resolved by the stated lowest-face rule). Profile: `raycast_local` 44%, `u_pass` 27%, `part_at` 17% |
| v20 disk kernel | 2026-11-07 | H44 alone, 32 threads: 41.0 s (1-term kernel, same code: 18.9 s) | 99.6 s (sweep) | - | 84.4 MB | DispersionCalculator now truncates to the unit disk; EV kernel = 4 separable terms (disjoint x bands x cumulative y). u_pass takes masked p + non-zero column runs. Profile: `split_rows` 33%, `row_dot` 18%, `ev::score` 16% |
| v21 box kernel | 2026-11-11 | - | 40.7 s (sweep) | - | - | Sampler back to per-axis strata with corner-free h/v pairing; product-of-marginals kernel fits it better than v20's disk (mean rect error 0.0030 vs 0.0045), 1 term. Keeps v20's masked p + column runs |

Raycast counters before the optimisation (H44): plate raycasts 3.1/walk, ~100 BVH nodes and ~40 tris per part ray; `part_at` 1/walk, 8.3 part rays per call, ~89 nodes each.

## Point table prototype (`PointTable`, `aim_probe --points`)

Per (shell, target hull): 27 aspects x range buckets to the gun's range, ship-local aim points, values split into
a fixed part plus 16 saturable (section, pen result) components and landed share. Built single-threaded at
runtime with the real shell (`_ProjectileManager.point_bucket`).

Validation: 600 simulated shells per aim through `DispersionCalculator` (citadel guarantee, one lead-error draw
per 3-shell salvo), walked live with `survey_walk`. Grid 1.5/3/6/10/14 km x 10/20/30/45/60/90 deg, fresh pools.
"pick vs solver" = summed live value (damage + fire term) of the table's shell+aim against the current solver's.

| variant | date | points | AP build / shell-pair | walk | score | size u8 / shell-pair | query | within 15% of live (table / solver) | pick vs solver |
|---|---|---|---|---|---|---|---|---|---|
| p1 kernel, feature points | 2026-11-04 | 36 | 1.9-3.4 s | 1.3-7.8 us/walk | 4-4.7 ms/bucket | 153-222 KB | ~220 us | DM->H44 AP 19/24 vs 17/24; Yam->DM AP 3/30 vs 2/30 | -3.7%, -1.4%, +0.3% |
| p2 mc, feature points | 2026-11-04 | 36 | 2.2-3.7 s | same | 4.5-5.2 ms | 153-222 KB | ~240 us | DM->H44 AP 23/24; Yam->DM AP 17/30; SP1->DM AP 20/24 | -3.9%, -1.4%, +4.2% |
| p3 kernel, face grid | 2026-11-04 | 69 | 2.2-3.7 s | same | 5-5.4 ms | 294-425 KB | ~390 us | Yam->DM AP 5/30 | -1.9%, +5.7%, +17.3% |
| p4 mc, face grid | 2026-11-04 | 69 | 3.4-5.0 s | same | 8.3-10.2 ms | 294-425 KB | ~370 us | DM->H44 AP 23/24, HE 21/24; Yam->DM AP 20/30 (solver 2/30), HE 24/30 (10/30); SP1->DM AP 19/24 (9/24) | **-2.4%, +5.7%, +18.5%** |
| p5 mc, face grid, 700-cell map | 2026-11-04 | 69 | 3.6-6.0 s | 1.1-6.3 us/walk, 1300-1540 rays/bucket | 8.7-9.7 ms | 294-425 KB | sorted ~150-175 us | as p4; DM->H44 HE 1.5 km rows now within 2-17% (p4: up to 2.3x) | **+0.2%, +5.5%, +18.5%** |
| p6 = p5 + binned scoring, O(1) cell lookup | 2026-11-04 | 69 | 2.1-4.1 s (HE 1.5-2.7 s) | 1.1-6.5 us/walk | 1.7-2.2 ms (p5: 8.7-9.7) | 294-425 KB | sorted ~150-175 us | identical rows to p5 | +0.2%, +5.5%, +18.5% |
| p7 = p6 + bias, pruning, sparse sqrt-u8 file (VERSION 3) | 2026-11-05 | 45-69 kept of 69 | same as p6 | same | same | file 48-153 KB / shell-pair (v2: ~335 KB); 98 lineup tables 8.1 MB | sorted ~185-220 us | picks within 0.3% of unpruned p7 | -0.1%, +5.3%, +20.6% |

Pairs in "pick vs solver" order: Des Moines -> Wotan (H44), Yamato -> Des Moines, SP1 -> Des Moines.
Median predicted/live, p4 vs solver: DM->H44 AP 0.98 / 1.01, Yam->DM AP 1.09 / 1.50, SP1->DM AP 0.94 / 1.14.
Useful points (within 3% of a bucket's best somewhere, p4): DM->H44 AP 39, HE 22; Yam->DM AP 62, HE 65; SP1->DM AP 41, HE 32 of 69.

Sorted query (p5): points visited by full-pool value, stop once the next full value cannot beat the best
saturated one; fresh pools visit 1.0-1.1 points, same pick as the full scan 155/156.
p6 scoring: samples are binned by cell code byte (payout depends only on it), then 17 components per occupied
bin; cell lookup uses a v-row table on a uniform grid corrected against the true edges. Walking is now ~80% of
native build time; GDScript lattice geometry and ray setup add ~0.8 s per Des Moines AP table.

Known gaps (p4, fixed in p5 by the finer map): at 1.5 km dispersion is smaller than a lattice cell, so map lookups mispredict slivers
(DM->H44 HE 1.5 km/10 deg: 811 predicted, 346 live). DM->H44's deficit is the HE fire term: its picks land less.

## Bot A/B: point tables in the solver

2026-11-04, `ab.sh` 50 vs 50 12v12 (lineup_12v12_t10), same snapshot, B with SHIPS_POINT_TABLE=1 (main-battery aim + shell
from p6 tables; `expected()` and secondaries unchanged). 98 tables prebuilt by `aim_probe --build-points`, <= 5.6 s each.
Results: /home/sspohn/Documents/ships_sim/ab_pointtable_20261104_211341/compare.txt

| metric | a (solver) | b (tables) |
|---|---|---|
| main damage BB / CA / DD | 77.1k / 70.1k / 41.2k | 76.7k / 71.2k / 44.4k (SP1 70.4k -> 77.1k) |
| real damage per shell vs BB 0-5 / 5-10 / 10-15 km | 523 / 353 / 271 | 598 / 323 / 273 |
| real damage per shell vs CA 0-5 / 5-10 / 10-15 km | 601 / 329 / 178 | 615 / 305 / 173 |
| aim lands on hull, vs CA 5-10 km / DD 5-10 km | 44% / 22% | 33% / 15% |
| aim along (half-lengths from centre) / height vs BB | 0.06 / 5 m | 0.34 / 9-12 m |
| real citadel share vs CA 5-10 km | 32.9% | 25.3% |
| survival BB / CA / DD | 844 / 632 / 767 s | 867 / 646 / 811 s |

Mirror self-play: behaviour change, not strength. Tables aim at the ends and higher; per-shell damage is up point blank
but 7-9% down at 5-10 km, where in-match aim error (0.5-1.7 half-dispersions, along-track bias -5 to -27 m) is far
larger than the static, nominal-lead validation assumed.

### Run 2: query at the impact pose (2026-11-04)

Tables queried with the target drifted by velocity x flight time (game seconds, / shell_time_multiplier) and turned by
yaw rate faded over 10 s; answer cache keyed on yaw rate. Results: /home/sspohn/Documents/ships_sim/ab_pointtable_impact_20261104_220752/compare.txt

| metric | a (solver) | b (tables) | run 1 b vs a |
|---|---|---|---|
| main damage BB / CA / DD | 79.8k / 67.4k / 42.1k | 75.0k / 70.9k / 45.5k | 77.1/70.1/41.2 -> 76.7/71.2/44.4 |
| real damage per shell vs BB 0-5 / 5-10 / 10-15 km | 543 / 352 / 288 | 568 / 365 / 278 | 5-10 km was -8.5% |
| real damage per shell vs CA 0-5 / 5-10 / 10-15 km | 581 / 322 / 180 | 614 / 323 / 168 | 5-10 km was -7% |
| real damage per salvo vs BB / CA, 5-10 km | 941 / 897 | 1001 / 894 | 984/902 -> 902/845 |
| aim on hull vs CA 5-10 km | 43% | 33% | 44% -> 33% |

Arm a moved 77.1k -> 79.8k BB main damage between runs: class means carry ~±4k of run-to-run noise.

### Run 3: + along-track aim bias in the tables (VERSION 2), salvo-hold flight time fixed in both arms (2026-11-04)

Results: /home/sspohn/Documents/ships_sim/ab_pointtable_bias_20261104_222510/compare.txt

| real damage per shell | a (solver) | b (tables) | run 2 b vs a |
|---|---|---|---|
| vs BB 0-5 / 5-10 / 10-15 / 15-20 km | 576 / 340 / 287 / 416 | 643 / 350 / 286 / 410 | +5% / +4% / -3% / -2% |
| vs CA 0-5 / 5-10 / 10-15 km | 589 / 314 / 194 | 676 / 307 / 189 | +6% / 0% / -7% |
| vs DD 5-10 / 10-15 km | 144 / 40 | 149 / 41 | -2% / -10% |
| main damage BB / CA / DD | 79.4k / 67.9k / 42.0k | 81.8k / 67.9k / 45.8k | -6% / +5% / +8% |

SP1 main damage across the three runs: +9.5%, +9.9%, +11.0% (the one consistent class-level effect).
Real citadel share vs CA 5-10 km stays lower with tables (30.6% -> 25.9%).

p7 pruning keeps a point if it is within 3% of its bucket's best under any of 10 pool states (fresh, each saturable
section drained, all but each drained, all drained), with and without HE fire. Lineup totals: 5115 of 6258 points kept.
File: per point landed + (component, value) pairs for non-zero components, sqrt-coded u8, zstd. Loaded tables decode to
floats (~0.85-1.7 MB each in memory).

### Salvo-hold flight time alone (2026-11-05)

a = run-2 snapshot (hold predicts aspect at 2x flight time), b = run-3 snapshot (fixed); point tables off in both.
Results: /home/sspohn/Documents/ships_sim/ab_holdfix_20261105_104057/compare.txt

| real damage per shell | a | b |
|---|---|---|
| vs BB 0-5 / 5-10 / 10-15 / 15-20 km | 542 / 331 / 284 / 417 | 542 / 321 / 281 / 398 |
| vs CA 0-5 / 5-10 / 10-15 km | 578 / 320 / 167 | 524 / 334 / 196 |
| vs DD 0-5 / 5-10 / 10-15 km | 262 / 141 / 40 | 272 / 154 / 43 |
| main damage BB / CA / DD | 77.2k / 68.1k / 43.3k | 76.9k / 69.2k / 42.4k |

Class totals within noise; per shell CA 10-15 km +17%, DD 5-10 km +9%, BB 15-20 km -5%.

### Run 4: p7 tables (pruned, VERSION 3) + main-battery expected() from the tables (2026-11-05)

Both arms include the salvo-hold fix; b = SHIPS_POINT_TABLE=1. Results: /home/sspohn/Documents/ships_sim/ab_pointtable_v3exp_20261105_104716/compare.txt

| | a (solver) | b (tables) | run 3 b vs a |
|---|---|---|---|
| per shell vs BB 0-5 / 5-10 / 10-15 km | 627 / 333 / 282 | 638 / 337 / 291 | +12% / +3% / 0% |
| per shell vs CA 0-5 / 5-10 / 10-15 km | 636 / 330 / 179 | 596 / 318 / 167 | +15% / -2% / -3% |
| per shell vs DD 5-10 / 10-15 km | 148 / 44 | 137 / 39 | +3% / +3% |
| main damage BB / CA / DD | 76.5k / 66.8k / 44.2k | 72.8k / 70.8k / 46.9k | +3% / 0% / +9% |
| survival BB / CA / DD | 871 / 607 / 803 s | 853 / 661 / 783 s | |
| AP share SP1 / Smolensk (others within 3 pts) | 51% / 14% | 70% / 31% | 52/15 -> 55/16 |

expected() on the tables moved the AP/HE forecast: SP1 and Smolensk now fire much more AP, and per-shell damage vs
CA and DD fell 4-11%. Montana main damage 91.7k -> 75.8k (±8k). Des Moines survival +10%.

## Runtime table generation in a match (2026-11-05)

`SHIPS_POINT_TABLE=runtime`: at match start the server queues every (shooter main-battery shell, enemy hull) table on
the native worker (`point_worker.rs`, 4 rayon threads), longest range first; bots fall back to the solver for a bucket
not yet built. Port checked against PointTable.build (`aim_probe --rt-compare`): 0.00% value error, same best point
270/270 buckets. DM vs Yamato AP table: 0.71 s on 4 threads (GDScript 3.5 s single-thread).

One 12v12 (lineup_12v12_t10, seed 7) against a flag-off control, same seed, both alone on the box:

| | runtime | off |
|---|---|---|
| tables | 98 jobs, 28,326 buckets, 36.1M walks | |
| all tables done | 37.9 s wall = 147 s sim after submit | |
| first main-battery query | 96 s sim (served: its long-range buckets were ready) | |
| queries served / fell back | 14,577 / 223 (1.5%) | |
| worker busy | 38.2 s wall x 4 threads | |
| main thread: submit / absorb | 0.35 s once / 2.3 s over the match | |
| process wall, user CPU | 317 s, 462 s | 273 s, 270 s |
| wall per sim second | 0.264 (1200 s match) | 0.255 (1070 s match) |

### Global range-first order (2026-11-05)

Worker queue is now one heap over every pair's buckets: range rank from the top, then submission order, fed to the
pool 16 buckets at a time. Same seed-7 12v12, 4 threads:

| | per-pair FIFO | global range-first |
|---|---|---|
| tables queried / first lookup served | n/a | 92 / 92 |
| lookups fell back to the solver | 223 of 14,800 (1.5%) | 0 of 26,818 (counted per shell table now) |
| first main-battery query | 96 s sim | 93 s sim |
| all tables done | 37.9 s wall / 147 s sim | 41.6 s wall / 160 s sim |
| process user CPU, wall per sim second | 462 s, 0.264 | 453 s, 0.274 (1115 s match) |

### Margin (2026-11-05, seed 7, 4 threads, ~3.8x real time)

| range row from the top | 1 | 2 | 3 | 4 | 5 | 6 | ... | 13 (last) |
|---|---|---|---|---|---|---|---|---|
| every table has it, sim s after start | 12.8 | 29.8 | 47.8 | 66.8 | 85.8 | 103.8 | ... | 155.8 |
| worker wall ms | 3,605 | 7,347 | 11,173 | 15,094 | 18,981 | 22,920 | ... | 41,354 |

Two longest rows ready (what a max-range lookup needs): median 21.8 s, latest 29.8 s sim. First lookup 93.4 s.
Per table, first lookup minus opening-ready: min 76.6 s, p10 86.8 s, median 118 s sim. 88/88 tables served on their
first lookup, 0 fallbacks in 27,462 lookups. In real time the same work is ~3.8x sooner in match time.

### Native table store and lookup (2026-11-05)

Buckets go from the worker straight into a native store (`point_store.rs`); `point_best` ports best_sorted (same point
1,078/1,080 against GDScript, identical values; 3.7 us vs ~165 us per lookup). Seed-7 12v12, with a flag-off control:

| | GDScript lookup + hand-off | native | off |
|---|---|---|---|
| main thread: hand-off / poll | 2.3 s / match | 0.04 s | |
| main thread: lookups | ~5 s est. (27k x ~200 us) | 1.34 s for 122,694 (now incl. expected()), ~11 us each | |
| wall per sim second | 0.274 (off: 0.255) | 0.253 | 0.248 |
| tables first-lookup served, fallbacks | 92/92, 0 | 92/92, 0 | |
| process user CPU | 453 s | 435 s | 295 s |

## Raycast SIMD (2026-11-05)

Per-part binary BVH collapsed into 4-wide nodes (f32 boxes padded 1 mm outward, so rounding only adds visits); box
test with SSE intrinsics (x86_64 baseline); leaf triangles stored lane by lane and tested 4 at a time in f64 with the
scalar arithmetic unchanged (AVX2 path picked at runtime). Bake output byte-identical across the fleet; runtime tables
identical to the GDScript build.

| | before | 4-wide nodes | + SSE boxes | + 4-wide leaves (final) |
|---|---|---|---|---|
| runtime table, DM vs Yamato AP, 1 thread | 2.73 s | 2.50 s | 2.14 s | 1.86-1.93 s (-31%) |
| same, HE | 1.39 s | 1.30 s | 1.19 s | 1.02-1.03 s (-26%) |
| H44 bake sweep, 16 threads | 39.0 s | 33.6 s | | 24.6 s (-37%) |
| fleet bake sweep, 256 threads | 35.3 s | 31.1 s | | 25.5 s |

Tried and reverted: 4-ray packets for each lattice ray's first hit. Neighbouring rays are ~5 m apart and cross the
whole hull, so they split near the root; testing every node against all four cost more than it saved (AP 1.91 ->
2.15 s).

## Modes (2026-11-05)

Normal play builds the tables in the match (default). Sims (`run.sh`) pass `--point-table-cache`: prebuilt
`user://point_tables` files are loaded and any pair without one is built and saved. `make point-tables` builds the
files from one lineup match with the bots' real loadouts and quits (98 tables, 10 s on 32 threads); `ab.sh` runs it per
arm. `SHIPS_POINT_TABLE=0` turns tables off. The table key hashes only shell ballistics and armour-walk inputs plus
per-range spread and grouping; shell damage is applied at lookup, so damage upgrades share tables.
