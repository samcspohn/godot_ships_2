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

## Stance round 4 (2026-11-10)

- Duel: our gun damage per firing step in one native call (stance_cell_pack us -> target, aspect-band salvo_affine);
  secondaries from secondary point tables (worker-built per sub-battery shell x enemy hull, behind main jobs; SecCache
  pack per pair, cells keyed by saturation mask). Duel reprice p99 8.6-9.0 -> 4.7-5.4 ms.
- Survey: StanceRows.ensure (validate + create with native calibration + fill) in one call; packs survive row resets,
  set_live updates saturation/fires/read; our HP left out of the row key once the shooter's tables are built.
  Survey p99 2.0-2.3 -> 1.07-1.10 ms.
- Dodge: hull at 4 Hz to the first whole second past the horizon, then 1 Hz through the 20 s price window.
  Native search 1.0 -> 0.45 ms; dodge plan p99 4.5-4.9 -> 1.5 ms.
- Warm (2.4 s here): damage models 678 ms, native grids 671, dps curves 602, point jobs 362, shells 38.
- A/B 66 vs 29 dodge candidates, wotan_dm_open 100 v 100: 29 lets Wotan land 19% more per salvo, DM dies ~57 s
  sooner and deals 12% less; CPU per sim second identical. Kept 66.

## Priorities (2026-11-10)

update_priorities mean 1.86 ms = per-enemy score 0.46, team belief 0.43, spawn references 0.33, routes 0.30,
can_hit 0.20, sort 0.10. Spikes: SearchedWater.update (2.4 ms once a second per team, paid by whichever bot reads
belief first), cold same-team curves for spawn-reference proxies, provisional dps_curve rebuilds every 2 s while
tables build (~90 s).

- SearchedWater.update stamping native (VisibilityGrid.stamp_search): 2.4 -> 0.16 ms; belief p99 3.6 -> 0.55 ms.
- Proxy curves (each class's proxy x every ship of its team) warmed with the cross-team ones (+0.25 s warm).
- Provisional rebuild skipped while none of the pair's main/secondary tables gained a bucket (BotGunnery.pair_progress).
- expected_points_pairs: one battery lookup instead of one per range: rebuild 1.5 -> 1.05 ms, warm curves -15%.

| (12v12 s3 / s5) | before | after |
|---|---|---|
| priorities mean / p99 / p999 | 1.86-2.09 / 6.5-7.1 / 12.3-13.7 ms | 1.71-1.84 / 4.6-5.0 / 6.7-6.9 ms |
| spawn refs p99 / p999 | 4.6-4.8 / 9.1-13.4 ms | 3.7 / 5.7-5.8 ms |

## Secondary aim (2026-11-10)

update_secondary_priority_target -> solve_secondary ran the legacy lattice `_score` (~16 ms a call, seen in the editor
profiler). Now `_score_sec_points`: per shell, the role (of the 6) with the highest combined dps over every sub-battery
in range (native `point_roles`), aimed at that role's point of the battery doing most there; superstructure while a
table cannot answer (never the legacy solver). Secondary aim 38 µs mean / 0.56 ms max. 12v12 s3: tick_behavior p999 9.2 -> 1.9 ms, all bots per frame mean
18.3 -> 13.6 ms, intent mean 5.7 -> 4.6 ms.

## Fight, rings, curve rebuild (2026-11-10)

- dps_curve rebuild = StanceSim.gun_dealt (stance_cell_pack, aspect-band salvo_affine) + SecCache.curve; GDScript only
  for secondary cells the cache cannot answer. Checked against the old path on every rebuild of two matches: 0 ppm
  except one cell where a worker bucket landed between the two reads. Rebuild 1.05 -> 0.6 ms.
- SkillFight's eased point routed by the HPA graph (was the fine-grid A*: p99 4-14 ms, p999 22-33 ms, max 35 ms):
  p999 0.5-0.6 ms. Fight p999 12-25 -> 7-7.6 ms.
- desired / _trade caches (5 s) expire at 0.5-1.5x per enemy (staggered_ttl). Not aggro_radius: its 1 s TTL is about
  one intent interval, so a shorter phase misses every time.
- Breakdown: Fight = STATION run (march: march_opts 1.2 + fight_search 2.4-3.8 p99) or COVER run (cover_search 2.5 p99);
  rings p99 = aggro_radius misses (~0.3 ms p99, 1.1 ms p999 each) landing together.

| (12v12 s3 / s5) | before | after |
|---|---|---|
| intent p99 / p999 | 13.2-14.3 / 17.8-29.3 ms | 12.2-12.4 / 15.3-17.3 ms |
| skill_Fight p99 / p999 | 5.7-6.9 / 10.2-24.7 ms | 5.3-6.1 / 7.1-7.6 ms |
| rings p99 | 4.3 ms | 3.2 ms |
| priorities p99 | 5.6-5.7 ms | 4.5-4.8 ms |

## Aggro radius native (2026-11-10)

StanceSim.aggro_take: priority_at's range loop and the take/release search in one call (curves fetched in GDScript).
Matched the GDScript loop on all 170k recomputes of two matches. The search is now ~15 µs; recompute p99 stays
~0.6 ms from the curve fetches (provisional dps_curve rebuilds while tables build) plus _team_view (0.22 ms p99,
first bot of a team per enemy per second). rg_aggro p99 0.28-0.31 -> 0.26-0.27 ms; rings p99 unchanged (3.2-3.5 ms).

## Duel scoring native (2026-11-10)

StanceSim.duel_scores (stance_duel.rs): every duel option's guns, torpedoes, secondaries both ways, incoming, kill/die
in one call; one Pricer and one config per reprice. Matched the GDScript _duel_score on ~2.9k options of two matches,
0 mismatches. Old _duel_score / _track_incoming / _add_torpedoes / _secondaries removed.

| (12v12 s3 / s5) | before | after |
|---|---|---|
| duel reprice mean / p99 | 2.7 / 5.1-5.3 ms | 1.6-1.7 / 3.1-3.3 ms |
| all options scored | ~2.0 ms (0.63 x ~3) | 0.92-1.02 ms |
| stance p99 / p999 | 5.0 / 7.2 ms | 3.5-3.7 / 4.8-5.5 ms |

## Station search counters (2026-11-10, temporary fx_/fxn_ keys)

fight_search p99 2.6-3.6 ms. Per call p99: route Dijkstra 1.3-1.5 ms (settles ~4k cells, ~2.8k route weights),
candidate cells 1.2-1.7 ms (~105 candidates, ~10-15 us each, 260-430 exposure evals), circle generation 0.58 ms,
checkpoint scan 0.3-1.5 ms, inputs 0.07 ms. Most calls are cheap (settled p50 3-13): the tail is the route field.

## Route search early stop (2026-11-10)

`route_field` stops once `held` is settled and no unsettled candidate can win at the cost reached (`route_stop`). Side by side with the full
search: 0 differences in 13.5k searches. 12v12 seeds 3, 5: settled mean 390-433 -> 207-213, route mean 163-175 -> 96-120 us. Route p99 unchanged
at 1.4-1.5 ms, settled p99 still ~4k: brawler checkpoint searches settled the whole window.

Checkpoints are now scored before the route, so the stop covers them: route p99 0.74-0.88 ms, settled p99 1.65-1.8k.

## Sail distance table (2026-11-10)

`nav/sail_table.rs`: u16 tenths of a 500 m cell between every pair of coarse cells, flooded on the 300 m water grid, no clearance. Built 424 ms,
loaded 74 ms, 12.6 MB cached. Replaces HPA paths in `_sail_m`. 12v12 seeds 3, 5: prio_sail mean 335 -> 11 us, p99 1.5 ms -> 25 us; intent mean
5.6-5.7 -> 4.7-4.85 ms, p99 12.4-12.5 -> 10.8-11.6 ms. Against HPA before GRID_STRETCH: median +3.9%, p1 -3.5%, p99 +11%.

## First-tick spike (2026-11-11)

The 120-140 ms max was `brawler()` building (self, self) point tables on a Kaiser Wilhelm's first intent, frame 2, before the server's
warm-up (2 frames after spawn) computed it. Bots now skip intents while queued for warm-up (`BotControllerV4._warming`). 12v12 seeds 3, 5:
intent max 137-140 -> 20-21 ms, frame_worst_bot max 30 / 24 ms. Next worst: DD `select` ladder 11-15 ms (Shimakaze).

## Destroyer ladder (2026-11-11)

Shimakaze `select` 11-15 ms: `smoothed_engagement_range` -> `optimal_engagement_range` priced `_threat_from` ~12 times per call (4.5-8.6 ms),
though a torpedo DD's `engagement_range` ignores threat. `threat_free_range` hook (NAN by default) skips it; result unchanged. Shimakaze worst
ladder now 8.5 ms (Fight push, ~5 ms fs_march). Next seen: Kaiser Wilhelm `select` 15-16 ms, brawl 1-1.4 ms (seed 5).

## Deferred checkpoint exposure (2026-11-11)

Kaiser Wilhelm 13-15 ms decisions: checkpoint scan priced exposure for every hidden cell (3.1 ms). Checkpoints now enter the route with
harm 0 and `route_field` prices exposure (`harm_of`) only when it settles one; cells left when route_stop ends the search cannot win.
Side by side: 0 different picks in ~650 checkpoint searches, exposure priced for 14-48% of checkpoints. 12v12 seeds 3, 5: fx_ckpt p99
0.3-1.7 ms -> 0.05-0.17 ms, max 2.0-5.3 -> 0.07-0.27 ms; worst ladder 17.6 -> 10.2-11.7 ms. One fx_route max 7.2 ms (lazy exposure inside).

## Per-frame tick (2026-11-11)

Sum over all bots per physics frame (`_tick_behavior`), 12v12 seed 3: mean 4.0 ms, p99 9.9-11.7, p999 12.7-15, max 33 ms.
A bot with no target rescans every tick (28% of ticks), and `pick_target` priced every candidate (`farm_value`, point tables)
before checking it could hit any. Now shootable first: 0 different picks in 32.7k, 10.7 s -> 1.35 s per match.
Left per match: DD `update_torpedo_aim` every frame 8.0 s (131 us), `aviation_engage` 9.2 s, gun `_cached_aim` 6.2 s (max 27 ms),
`_sync_salvo` 2.8 s.

Warm-up gap: `warm_dps_curves` now also builds `torpedo_danger`; the Kaiser Wilhelms' ~10 ms first team view is gone (worst early call 2.1 ms).

## Station-search inputs (`march_opts`, 2026-11-11)

Mean 0.51 ms, p99 1.2 ms, 4.6 s per match; no single hot part: per-enemy loop 1.86 s (aggro 0.37, front 0.35, busy 0.27, the
rest scaling and appending the trade curves in GDScript), `_torp_opts` 0.85 s (torpedo_rate per step, p99 0.7 ms on torpedo ships),
dictionary merges 0.5 s, `_walk_opts` 0.36 s.

## Log

- 2026-11-09: plan written. Existing stagger: `BotControllerV4.MAX_FULL_UPDATES_PER_FRAME = 2` (count only, no time budget).
- FTIME print in `FightStation._pick` was committed in a8ff7cf6; replaced by BotTiming.
