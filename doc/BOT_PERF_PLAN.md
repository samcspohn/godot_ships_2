# Bot per-tick cost: plan and progress

Goal: per-bot calculation ≤ ~5 ms worst case, no spikes. Base: current fight_search / cover_search / gun matrix / edge trees.

## Steps

| # | Step | State |
|---|------|-------|
| 0 | Per-bot timers by phase and native call, p50/p99/max; per-frame bot total | baseline done; drilling into priorities/stance |
| S | Stance: native rows store + one-pass rows/raw | done, no spike gain; next: spread reprices, cache pack |
| 1 | Hard caps: per-search evaluation budget (anytime, resumable) + per-frame time budget for full intent updates | on hold: fight_search p99 2.4 ms is not the spike source; frame budget trades decision latency |
| 2 | Best-first branch-and-bound over current fight_search candidates; parity mode vs exhaustive | todo |
| 3 | Block reach bits: gun matrix any/all per (1.2 km block, cell), edge-tree coarse span summaries | todo |
| 4 | Incremental route Dijkstra (frontier as lower bound) for fight and cover | todo |
| 5 | Optional: search all window cells instead of ring points (behaviour change, user call) | todo |
| 6 | `_march_opts` into Rust or cached per (our hull, enemy hull) | todo |
| — | Optional: fight/cover search on a worker from a snapshot | later |

## Bounds (step 2)

- value UB: enemies any cell of the block reaches × max of `out` over the block's distance interval.
- harm LB: enemies whose fire reaches every cell × min of `inn` over the interval; focus/crossfire factor 1.
- penalty LB: euclid × min route weight, or the Dijkstra frontier once running.
- Distance intervals widened by each enemy's forecast motion over the window.

## Baseline (step 0)

Measure: `--bot-timing` (or any `--metrics` botmatch) → `bot_timing` in the metrics JSON and a table at match end.

12v12 t10 seed 3, release, 16 fps, µs:

| key | n | p50 | p99 | p999 | max | total s |
|---|---|---|---|---|---|---|
| intent (one bot's full update) | 20.5k | 4726 | 17894 | 29018 | 72636 | 115 |
| priorities (`update_priorities`) | 20.7k | 1486 | 6536 | 11286 | 22314 | 37 |
| skill_Fight | 20.3k | 682 | 6100 | 16886 | 30611 | 24 |
| finish (stance etc.) | 20.7k | 157 | 11601 | 18435 | 55036 | 23 |
| rings | 20.7k | 303 | 2835 | 4836 | 11089 | 11 |
| situation | 20.7k | 419 | 1475 | 2023 | 6908 | 10 |
| march_opts | 12.5k | 371 | 1164 | 1212 | 2301 | 6 |
| fight_search (native) | 11.1k | 184 | 2689 | 4380 | 6543 | 5 |
| cover_search (native) | 2.6k | 472 | 2458 | 2773 | 3038 | 2 |
| redodge | 2.0k | 1917 | 11030 | 16477 | 19495 | 5 |
| tick_behavior (every frame) | 247k | 132 | 1523 | 6747 | 26203 | 67 |
| set_state (every 2nd frame) | 123k | 24 | 1587 | 2365 | 3161 | 27 |
| frame_bots (all bots, one frame) | 14.5k | 15520 | 43157 | 55322 | 89919 | — |

Finding: native station search is ~5% of intent time. The median intent is already ~4.7 ms, dominated by
`update_priorities`; spikes come from stance (finish), skill_Fight's GDScript, priorities and redodge.
Step order revised: profile composition of priorities / stance / Fight GDScript before LOD work.

Second run (sub-timers, µs): stance p50 91 / p99 12414 / max 35899 (all of finish's spikes);
priorities split: score 442/3428, sail 227/1502, can_hit 188/773, rest ~700 p50 outside the enemy loop.
Means add up: intent 6.2 ms = priorities 2.0 + ladder 1.4 + finish 1.3 + rings 0.6 + situation 0.5 + trade 0.3.

GDScript profiler (symbol build, `--debug --gd-profile`), inclusive per call:
- `update_priorities` 2.3 ms: `can_hit_target` 312k calls, `priority_score`/`score_parts` 393k, `_sail_m` 194k (self 9 s).
- `SkillStance.apply` 1.4 ms mean: `_lie_on_axis` 1.65 ms (7k calls), `_priced` 0.65, `_dodge` 0.37, `_dodge_tail` 0.57,
  `_survey` 0.5; `_expected` 266k calls, `_fill_cells` 223k.
- Fight 1.5 ms: `_march` 1.15 (fight_search 0.48, `_march_opts` 0.59), `_keep_mode` 0.84, SkillCover.execute 0.8.
- Outside intent, every frame: `ProfiledShipNavigator.set_state` 25 s self, `_register_torpedo_obstacles` 20 s,
  `_engage_target` 49 s (aim, ammo, torpedo aim), secondaries 13 s.
- Team belief is already cached per frame (one build per team per frame).

## Stance (2026-11-09)

Per threatened update: survey; turn-vs-astern (1 s reprice, 3 hull sims to 300 s); route-vs-lie (1 s); duel
(per gun reload, ~4 options x 60 s); fire heading; dodge plan on new shells. Spikes > 5 ms = 1-4 of those
repricing on the same update.

Done: 1) native StanceRows store (per shooter, 250 m bucket, [rows, raw, hit] x 37 aspects, cell-level fill,
same values as the old _tables) read directly by track_price / track_incoming / DodgePlanner; 2) rows and raw
priced in one pass for turn and astern. Missing-cell rounds 2-9 -> always 1.

Side-by-side 12v12 (same load), stance µs:

| run | p50 | p99 | p999 | max |
|---|---|---|---|---|
| base seed 3 | 89 | 11961 | 21324 | 48892 |
| new seed 3 | 101 | 11642 | 20812 | 46728 |
| base seed 5 | 98 | 12656 | 22183 | 38822 |
| new seed 5 | 109 | 12688 | 20727 | 50352 |

No measurable gain: the dictionary plumbing was not the cost (the debug profiler overstated it). What remains is
real work. One match's stance total 21.4 s: survey 8.0 (cold buckets), point-table fills 4.7, `stance_cell_pack`
2.6 (rebuilt per shooter per update), duel reprice p50 3.4 ms (score ~0.9 ms/option), turn/astern 2.3 ms,
dodge plan 1.6 ms, route/lie 1.0 ms. Whole-row fill (tried): median -30% but p99 x2 (cold buckets).

## Point tables: 6 roles per bucket (2026-11-09)

Per (shell, target hull) bucket (range x aspect), on insert (worker or file put): the best point at full pools on
each role (superstructure fore and aft of its middle, casemate, citadel, bow, stern), each priced under all 16
saturation masks (casemate, bow, stern, superstructure drained or not; citadel never saturates). Lookup: target's
mask (section pool spent) -> blend each role's value over the 4 corners -> max of 6, fire chance per role point as
before. Replaces the per-query walk over ~69 points with continuous live pool weights.

Also: StanceRows holds each shooter's parsed stance_cell_pack until its _row_sig changes (pack builds 43k -> 7k
per match); stance's _target_sig uses BotGunnery.point_sig (mask + burning fires) instead of the 8-step pool sig.

Side-by-side 12v12 vs baseline (stance µs): seed 3 p99 13315 -> 9455, p999 22925 -> 16272, mean 1276 -> 876;
seed 5 p99 12489 -> 9614, p999 21797 -> 16582, mean 1402 -> 936. Per filled cell ~16 -> 7 µs. Survey p99 3.2 -> 2.2 ms.
Main-battery damage per match in the same range as baseline. Left: duel reprice p50 3.7 / p99 13 ms, dodge plan
p99 ~9-10 ms, turn/astern p50 2.4 ms.

## Stance round 3 (2026-11-10)

- Dodge: shells bucketed by landing step (checks = hits tested); native search 1.7 -> 1.1 ms.
- Native helm+cut (land check) and native duel secondaries (SecCache, same cells as _secondary_dps).
- Missing damage cells filled inside the native pricers and DodgePlanner (StanceRows.ensure_cell; calibration from
  the pack's CALIBRATION row + learned affine per range band): searches per dodge plan 1.8 -> 1.05, GDScript rounds 0.
- Turn/astern, route/lie and lie tracks: 60 s horizon (was 300 s); the turn now carries the same shortfall charge as
  backing when the horizon ends it short of ESCAPE_M.

| (12v12, --bot-timing) | before | after |
|---|---|---|
| stance mean / p99 | 0.75-0.78 / 8.0-8.1 ms | 0.61-0.62 / 5.7-6.0 ms |
| dodge plan p50 / p99 | 1.5-1.8 / 10.6-11.4 ms | 1.3-1.5 / 4.8-5.2 ms |
| turn/astern p50 / p99 | 1.7-1.8 / 5.9-6.0 ms | 0.67-0.71 / 1.2-1.4 ms |
| route/lie p50 / p99 | 0.78-0.85 / 3.6-3.9 ms | 0.39-0.44 / 0.8-0.9 ms |
| duel reprice p50 / p99 | 3.0-3.1 / 9.7-11.6 ms | 2.4-2.7 / 8.6-9.0 ms |

## Log

- 2026-11-09: plan written. Existing stagger: `BotControllerV4.MAX_FULL_UPDATES_PER_FRAME = 2` (count only, no time budget).
- FTIME print in `FightStation._pick` was committed in a8ff7cf6; replaced by BotTiming.
