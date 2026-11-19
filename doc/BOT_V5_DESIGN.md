# Bot Controller v5

Ground-up native Rust bot. Team-first. Correctness over features. No fallbacks.

## Decisions (2026-11-12)

- CV out of scope; later phase.
- Hive = central compute hub, not a chess commander. Team-level solve replaces per-bot decision loops for performance and teamwork.
- Bots are parameter sets: playstyle (gunboat, tank, dps, island hugger, brawler) + aptitude. The hub decides what each bot does and where it goes.
- Aptitude simulates discrepancy: low aptitude plays selfishly; high aptitude plays around low-aptitude allies (crossfire, tanking for them).
- Learned risk trains on bot and human matches.
- Hard cut per team: a team is all v4 or all v5. v4 vs v5 on opposite teams is the A/B gate.
- Point tables stay as the only aim model. BotGunnery db is not linked into v5. Point tables get fixed (whole-ship misses).

## v4 lessons

1. Churn (destination flip-flop, skill alternation, station resets) caused most visible stupidity. Commitment is a core type, not a hook.
2. Hard gates + geometric search + tiny objective beat weighted sums.
3. Fallback chains hide failures (gunnery db behind point tables, Station/FindCover behind Cover, matrix behind edge trees).
4. Inputs that react to our own state oscillate (rings from `active_shooters_at_me`).
5. GDScript↔Rust Dictionary traffic costs more than the math.
6. Fairness rules (aimers only while detected, noisy inferred spotters) were scattered checks.
7. Each bot iterated its team (~62 loops) to answer team questions.

## Rules

- Module `ships_core_rs/src/bot5/`. Depends only on core libs: nav/HPA, navigator, visibility, reach, edge trees, projectile, point tables, hull model.
- No calls into v4 GDScript. No `BotGunnery`.
- No fallbacks. Missing capability = bot does not do it + a counter. Missing point table = load error.
- Fairness in one place: the belief layer. Hive and planners see belief only, never true state.
- Deterministic given SimClock + seed. Planner inputs dumpable for single-decision replay.

## Architecture

One `BotWorld` (GodotClass) per match.

| Layer | Rate | Reads | Writes |
|---|---|---|---|
| Snapshot | every tick | Godot ships/shells/torps (packed SoA) | world state |
| Belief | every tick | snapshot + detection | per-team contacts, LKP, inferred |
| Hive | 1–2 Hz + events | belief, bot params, risk field | posture, station, route, commitment per bot |
| Route refine | 2–4 Hz staggered | plan, snapshot | navigator intent |
| Controller | every tick | plan, snapshot | rudder, throttle, aim point, ammo, fire, consumables |

Godot side: adapter writes snapshot, reads one command struct per bot.

### Commitment

Every plan carries: owner (hive task id), start time, minimum hold, explicit release conditions, switch margin. A replan inside the hold keeps the station unless a release condition fired. Release reason is logged.

## Hive

One solve per team per hive tick. Bots hold no decision logic; they hold parameters and a plan.

### Bot parameters

- Playstyle: preferred postures, range band, risk tolerance, island affinity, aggression, angling vs dodging. Archetypes are presets: gunboat, tank, dps, island hugger, brawler.
- Aptitude (extends BotAptitude tiers): team awareness, blackboard staleness, planning horizon, reaction latency, commitment quality, gunnery error.

### Shared computation (once per team)

- Belief, threat field, spot coverage, crossfire bearings, risk field.
- Candidate stations per enemy group, generated once and scored per bot by lookup.
- Per-bot cost is a cheap evaluation against shared fields, so team size scales near linearly.

### Resolution order = aptitude

1. Bots resolve in ascending aptitude.
2. Low aptitude: scored on its own playstyle and its own view only (stale, partial team picture). Its plan commits first and becomes a fixed fact.
3. Higher aptitude: scored with team terms against everything already committed. It fills gaps: spots for allies with no spotter, takes the crossfire bearing opposite a committed ally, tanks a lane in front of a weak ally, avoids stacking.
4. Same tier: order by a team value heuristic, ties by id.

Effect: high-aptitude bots work around low-aptitude ones without a joint optimisation. One pass, no iteration.

### Team terms (weighted by aptitude)

- Spot value: lights enemies that committed allies can shoot.
- Crossfire value: angle between our bearing and committed allies' bearings on the same enemy.
- Tank value: draws expected fire off weaker committed allies.
- Stacking penalty: shared exposure with committed allies.
- Retreat: a candidate like any other, scored with team context (needed as spotter? covered? escape risk from here).

### Commitment and events

- Hysteresis per bot: hold N s, switch only past a margin. Low aptitude: worse commitment (later release, or flip-flop margin smaller).
- Event triggers force a team pass: big HP drop, new contact, torps detected, ally sunk, detection change.
- Reflexes stay in the controller: shell dodge, torp dodge, collision, grounding.

## Risk field

Cell grid (reuse VisibilityGrid resolution). Per class.

1. Static (baked per map, cached):
   - Confinement: escape-cone width and turning room from the hull model.
   - Exits: count of separate escape paths in the path graph.
   - Exposure: distinct bearings from which reachable enemy water can shoot the cell.
2. Prior: static exposure weighted by learned enemy occupancy.
3. Learned outcomes per (class, cell): damage per minute of dwell, death rate, retreat success. Bayesian, seeded by static. Sources tagged bot/human; frozen snapshot for A/B.

Use: hard gate (risk cap per posture, task value can buy past it) + one cost term in station and route scoring. Hive uses it for crossfire and retreat decisions.

The learned route graph (FIGHT_V2 §5) can come later as a layer on top.

## Gunnery

- Point tables only. Live lookup native; no generic db, no `_expected_points` flag path.
- Fix whole-ship misses. Known: in-match aim error much larger than baked lead error; tables favour ends/high; fixed `LEAD_BIAS_ALONG`.
- Add per-salvo telemetry: predicted impact centre vs target hull at impact, split into along-track, cross-track, range error, table point offset. Classify every miss that lands entirely off the hull.
- Aim choice integrates over the predicted target-state distribution (maneuver), not one predicted pose.

## Phases

1. Skeleton: BotWorld, snapshot, command output, sail to point, point-table aim. v5 team vs v4 team runs. Salvo miss telemetry.
2. Belief layer (spotting, LKP, inference) + blackboard threat/spot coverage.
3. Hub solve: bot parameters, candidate stations, Engage / Hold / Retreat, commitment. Selfish scoring only (all bots low aptitude).
4. Torpedoes (native aim, launch gate, torp-run posture) + spotter planes (hive tasking).
5. Stance + dodge (port existing native pricing).
6. Static risk field.
7. Aptitude-ordered resolution + team terms: spot, crossfire, tank, stacking, retreat.
8. Learned risk from sim + live.
9. CV.

## Open

- Hive rate vs latency for retreat; which events trigger a pass.
- Does a hive pass re-solve all bots or only those released/triggered (committed bots stay fixed)?
- Human data weighting vs bot data; per-map store versioning.
- Whether the blackboard threat uses point tables or a cheaper DamageModel.

## Phase 1 status (2026-11-12)

Built:
- `ships_core_rs/src/bot5/`: `BotWorld` (API), `snapshot`, `belief` (spotted-only, per-team, history for aptitude view delay), `hive` (per-team pass 1 Hz + events, ascending-aptitude resolution, commitment with release reasons), `gunnery` (point store lookup in predicted impact frame, AP/HE hysteresis, motion lead, salvo sync), `telemetry` (per-shot lead error, off-hull classification), `params` (playstyle presets, aptitude).
- `src/ship/bot5/bot5_hub.gd`: one node per match; snapshot in, commands out (helm, aim, ammo, fire, repair, damage control, secondaries).
- Server: `bot_version` per lineup entry, or `--bot5-teams 1|0,1|all` / `SHIPS_BOT5_TEAMS`. Telemetry printed at match end and in metrics under `bot5`.

Behaviour now: Engage (approach to the playstyle band off the target or nearest belief contact; in band, orbit the anchor in the current direction of travel) and Retreat (hp below playstyle floor while threatened). Arc-blocked guns for 3 s release the plan and swing the station around the anchor. Team term: focus-fire bonus scaled by aptitude.

Run: server with `--bot5-teams 1` (or `SHIPS_BOT5_TEAMS=1`), or `"bot_version": 5` per lineup entry. `SHIPS_BOT5_TRACE=1` prints per-bot plan, gates and hub fire gates every 10 s.

Smoke (3v3 seed 1, v4 team 0 vs v5 team 1): v4 won; total damage v5 175k vs v4 236k; v5 Des Moines top of the map. Bot cost 1.48 s per match for 3 v5 bots (hub incl. GDScript) vs 9.93 s for 3 v4 bots. Lead telemetry: whole-hull misses are almost all on targets that changed speed or turn during flight (steady_off ~0); cross-track error (target frame) runs 2-3x along-track.

Not yet / known gaps:
- Point tables live in `src/ship/gunnery/` (`PointTables` registry/queue, `GunneryModel` shell/battery/lattice model, `PointTable`); v5 never touches `BotGunnery`, which now only holds the v4 solver and its db.
- Fire clearance is native (`Gunnery::clearance`): terrain via terrain-only `sim_can_shoot_over_terrain_impl`, then allies predicted along the arc against their hull box (`crosses`, unit-tested); 0.5 s / 50 m cache. Both count toward blocked_s.
- No torpedo/shell dodge, no hold fire, no stance (phase 5).
- Telemetry measures lead error of the aimed point only, not dispersion or real impacts. Keys count individual gun shots.

## Phase 4 status (2026-11-13)

Torpedoes (`bot5/torpedo.rs`):
- Per-ship smoothed course/speed/yaw track, from spotted ships only.
- Intercept along the predicted arc. The envelope covers a full-rudder turn once the target sees the torps, plus pre-sighting weave and throttle doubt. Spread is up to 5 points, centre first, with land cut off.
- A point is dropped when land is on the fan edges (raycast 1.25x past the intercept) or an ally is within 500 m of the lane.
- Gate: hit chance (fan cover over envelope, times ready launchers) must reach the aptitude threshold `TORP_MIN_CHANCE`.
- Candidates: the gun target first, then the nearest seen enemies (3 max). Solved every 8 frames.
- Hub fires one loaded launcher per point. A new point waits 2 frames for can_fire to refresh.
- Hive: `TorpRun` posture when torps are loaded, hp >= 50%, the target is seen, and the playstyle band centre lies beyond 0.8x torp range. The station is 0.7x torp range from the target, led toward its course. Firing reloads the tubes, which flips the posture back to Engage.
- Counters: `torp_fire`, `torp_low_chance`, `torp_land`, `torp_friendly`, `torp_no_intercept`, `torp_no_target`, `torp_launch`.

Spotter planes:
- Part of the hive pass, ascending aptitude. Candidates are contacts unseen for at most 45 s, plus the contact already tasked, within tether + 0.8x the target's air_radius.
- Value: in own gun range (+1), near own anchor (+1), allies in gun range (team weight x 0.5 each), already tasked (+1). Team-aware bots skip contacts an earlier spotter claimed.
- Launches only with a task. Tasked with `set_attack`, so it orbits at circle_range once it arrives. Clamped to the tether. Re-tasked after 300 m of movement, but never while `Squadron.station_lock` is running (30 s after taking a station; this applies to players too, and the button shows it in purple). Fuel runs out on its own.
- Counters: `spot_task`, `spot_launch`.

Smoke (3v3 seed 1, v5 team 1): v5 Shimakaze fired 15 torps (0 hits) vs v4 55 (3 hits). The v5 Yamato spotter launched once. TorpRun is untested in a match (Shimakaze's torps outrange its band; Bigensk/MLK would trigger it).

## Flanks (2026-11-13)

`bot5/flank.rs`. Replaces v4's priority-as-flank-keeper. The hive only decides which enemy group each bot answers for; stations stay per-bot.

- Belief (`belief.rs`): presumed contacts. One per enemy spawn slot, marching down the spawn-to-mid lane at EnemyPresumption's advance speed, stopping 6 km short of the middle or at land. The first sighting of an enemy retires the nearest. Water within 8 km of our ships pushes them out and stops their march.
- Groups: 1D k-means across the front (axis = own spawn → enemy spawn) over every live identified contact at its last known position (any age) plus presumed contacts. Starting k = 3 for 9+ enemies, 2 for 3+, else 1. Centres persist between passes, so flank ids are stable. A flank dies only when its ships sink.
- Merge and split, at most one per pass, 4 groups max:
  - neighbours whose centres are within 4 km across the front for 10 s merge; a dead group merges at once;
  - a group whose members leave a gap over 7 km across the front for 10 s, with at least one full-HP ship each side, splits at the gap.
  - Roles are renumbered: merging j and j+1 turns Seam(j) into Flank(j). A split flank's bots are dealt to the halves in lateral order by enemy share.
- Roles: `Flank(g)` or `Seam(j)` (between g=j and j+1). Seams exist when own count > 2x groups: one non-brawler nearest each gap. A live gap without one later takes the non-brawler nearest it from a neighbouring flank that keeps another ship (`seam_fill`). The rest are assigned in lateral order to quotas proportional to enemy strength (HP share; presumed = 1).
- Use: target score ×0.4 off-flank unless the enemy has us in range. Anchor = target if ours, else nearest flank contact in view, else nearest live covered group centre. Seam bots approach from a point at the seam lateral, halfway from their depth to the anchor's: crossfire from the side.
- Changes: collapse (flank dead → nearest live; seam with one side dead → the other) for all aptitudes. Pressure = enemy / own. Rebalance: the most pressed flank ≥ 1.5 and ≥ 2x the calmest; a level 2+ bot from the calmest moves, if that leaves its flank calmer than the target. A live flank nobody holds pulls from level 1+. One move per 30 s per team, 60 s role hold.
- Counters: `flank_assign`, `flank_merge`, `flank_split`, `seam_fill`, `flank_join`, `flank_collapse`, `seam_collapse`, `flank_rebalance`, `flank_abandoned`, `flank_imbalanced_pass` (max/min pressure > 2). Debug view: presumed circles, flank rings with pressure, role rings, role in summary. `SHIPS_BOT5_TRACE=1` prints flank state.

## Team field (2026-11-13)

Shared base for cover, spotting, checkpoints and station search (`bot5/field.rs`). Built every hive pass from belief; nothing cached or rebuilt per enemy.

- Cells: VisibilityGrid water cells (300 m), numbered row-major, so a disc is one index run per grid row (`Layout::spans`) and every test is a 64-cell word op.
- Sources: each contact within FORGET_S at its believed position, plus its position 20 s ahead along its course while seen.
- `shot` (team): OR over sources of the source's gun-matrix row (from its cell) clipped to its gun range. An unbuilt row counts its whole range disc as shot (`field_row_missing`).
- `seen(radius)` (per bot): OR over sources of the LOS row clipped to `radius`, plus the radar/hydro disc without LOS. Radius is concealment when staying dark (spotting, torpedo DDs), gun range when firing (firing blooms to gun range).
- Danger = seen & shot (one spotter lays every gun on us). Hidden = !seen. Shielded = seen & !shot.
- `lights(k)`: sources a ship in cell k sees inside their concealment (per-cell bit reads, for scoring).
- Our shot from cell k at target t is bit (k, cell t) of our gun matrix: strided, read only for cells that pass the bitset filters.
- Snapshot carries concealment, radar/hydro reach (running, else carried x0.9), and the reach_gun shell per ship. Matrices are registered and their build order sited by v5 itself (`ensure_matrix`, `set_sites`); the disk cache is now always read (written with `--gun-matrix-cache`).
- Smoke is not in the field: exact rays on the final picks only.
- Debug: Ctrl+R overlay modes FIELD5 (firing bloom) and FIELD5_DARK (concealment), one byte per cell every 0.5 s: yellow seen not shot, cyan shot not seen, red both.
- Gun matrices are generated at runtime; `--gun-matrix-cache` (testing only) reads and writes the disk cache.

## Engage station scan (2026-11-13)

`bot5/station.rs` replaces SHOT_SWINGS. Bearing is free: no preferred side, the cell's own numbers decide.

- Candidates: water cells in the band ring around the anchor, deep enough for the hull; seam bots only within 2.5 km of their seam line; after arrival or a blocked release, at least 1.5 km from the old station.
- Value: our damage per minute on the target from the cell (range, the target's aspect when seen, else aspect mean). Cells our gun matrix says cannot reach the target are dropped; an unbuilt row is left to the exact check.
- Exposure: when the cell is seen at firing bloom, sum over believed enemies whose gun-matrix row hits it of their damage per minute on our hull at that range (aspect mean).
- Score: value - risk x exposure - best value x transit / 90 s. Risk is per playstyle (tank 0.6 .. island hugger 2.0) times (2 - hp).
- Top 6 checked in order by the exact terrain ray; an expired plan keeps its station within 10% of the best.
- Curves: each point table flattened once (damage 1, no fire or saturation) into per-shot value by range and aspect, cached by table key, so pairs sharing a table share a curve; re-read every 5 s until complete. Damage per minute = value x shell damage x barrels x 60 / reload, better shell.
- Enemy-vs-us tables come from the same runtime queue (`start_runtime_tables` already queues every pair both ways); the hub hands their keys over with `set_threat`.
- Counters: `station_scan`, `station_scan_empty`, `station_no_shot` (had a target, top 6 failed the exact ray), `station_no_value`, `station_no_column`, `threat_no_table`, `exact_ray_fail` / `exact_ray_fail_centre_ok` (ray clear to the target's cell centre but not its true position).
- Cost per scan: cells on every other grid cell, then the full grid around the best 8; transit (sail table) only while a cell can still beat the kept six; curves resampled to 100 m steps, rebuilt from table slots at most 4 per pass and only after a table grows 10%.

### Gun matrices around targets

Each team hands every matrix a demand per hive pass (`GunMatrix::demand`): the believed enemy cells. The worker builds, nearest first out to 900 m from each:
- rows of the enemy's own gun kind at those cells (where its shells land: exposure),
- columns of our gun kinds (which cells can land on that cell: our shot, read as one contiguous bitset per scan).

Columns are sparse (built only around targets, 1.6 KB each). Demand is rescanned only when it changes or is unfinished. Then the old background fill (rows nearest the sites) resumes.

Next: cover gate, checkpoints, Spot posture.

## Frame spreading (2026-11-14)

- A team pass is resumable: flanks, field, curves and the aptitude order are fixed at its start; bots then resolve in that order until 2 of them re-plan this frame, and the rest resume next frame with the same committed list (`hive_pass_resumed`). Bots keeping their plan do not count. Count budget, not time, so runs stay deterministic.
- One team's hive work per frame: an unfinished pass first, else the most overdue team. Teams start half an interval apart.
- At most 4 jumped-station navigator pushes per frame.
- The hub fills point-table pair and threat keys for 2 bots per frame and skips bots that have them all.

## Station transit and damage calibration (2026-11-14)

- Transit: one Dijkstra flood per scan from our cell over the 300 m water grid (hull clearance), out to 240 s past the first band cell (median ~7.5k cells, ~0.5 ms; rates memoized per cell). Each cell gets sail time and the route's earnings: damage out minus risk x damage in, per step, at that cell's rates (out is 0 past our gun range or where our column misses).
- Score = (route earnings + 90 s x the cell's net rate) / (sail time + 90 s): an average rate, so a route that keeps shooting costs nothing. Replaces the 90 s horizon penalty and the coarse/refine sampling (every band cell the flood reaches is scored).
- Calibration: the hub sends cumulative main-battery damage dealt and taken (`Stats.main_taken`) every 0.5 s; the world books the raw predicted rates (exposure at our cell; value on our seen in-range target) against them, per `in|class` and `out|class>class` (`bot5.calib` in metrics). `tools/botmatch/bot5_learn.py <metrics>...` writes `assets/bot5_calib.json`; the scan scales exposure by `in` and value by `out`. No file = raw, with a warning.
- First fold (2 x 12v12): taken is ~0.2-0.25 of predicted for every class; dealt 0.10 (Dd>Ca, Bb>Ca) to 0.48 (Ca>Dd).
- Re-plans per frame cut to 1 (a scan is now ~0.5 ms). The damage sample reads only our own cell's seen bit (`TeamField::seen_at`); a full seen bitset per bot per sample was a frame spike.
- Trace: `SHIPS_BOT5_SCAN_TRACE=1` prints a `scan5` line per scan (pick, best zero-exposure cell and why it lost).
- Blocked guns release a plan only within 1 km of its station (`BLOCKED_AT_M`); blocked in transit is expected. 12v12 seed 1: blocked releases 754 -> 16, scans 1730 -> 1100.

## Feature station scan (2026-11-14)

Replaces the flood. `bot5/features.rs`, built at prepare from the VisibilityGrid (~1 ms):
- Islands: 8-connected land components of the 300 m grid; each water cell labelled with its nearest island by sail distance.
- Berths: water within 900 m of land, per island, sorted by bearing from its centre. Gaps: cells where two islands' labels meet, 600 m - 3 km from land, every other cell. Lattice: every 4th cell.
- Debug: Ctrl+R overlay FEATURES5 (green berths, magenta gaps, white lattice).

Scan (`station.rs`):
- Candidates: lee berths (within 60° of the side away from the enemies' centre) of islands in gun range of the anchor, gaps, our cell, the kept station; each within [lo, hi] of some foe (or a spot foe's concealment when dark is allowed). Lattice only when none nets >= 0.
- Per foe (every field contact): our value at its aspect x calibration / its HP, best target full (the hive's target first when set) and the next three at 0.5, 0.25, 0.125.
- Gates: the hive's target in gun range with a column hit, at least min(2, foes) foes in gun range, one in band; relaxed to 1 when no candidate passes.
- Net (HP share per minute) = value + spot - risk x exposure / our HP, at the worse of now and 60 s ahead (field forecast now 60 s), + 0.25 x the covered share of water within 900 m x value.
- Spot: per pass, allies lighting each enemy (eyes with LOS inside its concealment, or radar/hydro) and bots' fire on it (only bots targeting it or with no target). A foe nobody else lights is worth the others' fire on it to whoever lights it.
- Dark: DDs, and CAs with concealment under 0.7 of gun range, also score holding fire (no gun value, seen at concealment); the plan's `dark` holds fire (`dark` gate).
- Two stages: now-only, straight-line transit for every candidate; the top 24 in full (ahead, dark, defensibility, sail-table transit).
- Expiry: the held station is scored alone (`Req::only`); held again for HOLD_S if it nets >= 0 and >= 0.75 of its score when set (`station_hold_ok`).
- Re-plans per frame back to 2. 12v12 seed 1: scan 266 us mean; 606 scans, 247 holds re-used.

### Feature scan: pending optimizations

Tail cost is candidates x foes: in a 12-contact fight a long-range BB passes 500-900 berths and gaps through the prefilter (~1-1.3 ms per scan).
1. One berth ring per island: keep only the nearest ring the hull can use, not all water within 900 m (~3 rings). ~3x fewer berths.
2. Prefilter on the hive target's band (or the flank group centre), not the union of every foe's band.
3. Quick pass on every second berth along an arc, refine around the best.
Target: worst scan under ~300 us.

## Checkpoints (2026-11-14)

- Plan keeps `goal` (the scan's pick) and `station` (where the navigator sails). A goal over 90 s away by sail gets a checkpoint: the best station passing the gates with net >= 0, within 90 s, at least 1 km nearer the goal, exact-checked when firing. The scan scores up to 8 near candidates in full for this.
- Arriving at a checkpoint re-scans with keep = goal (`checkpoint` release); arriving at the goal holds it while it still scores (same check as expiry), else moves on (`arrived`).
- Anchor stickiness: the previous plan's anchor contact is kept while in view and ours, after the hive target.
- Counters: `station_checkpoint`.

## v4 vs v5 baseline (2026-11-14, 12v12 t10, seeds 1-4, v5 on each side)

| build | v5 wins / 8 | damage v5/v4 |
|---|---|---|
| feature scan | 0 | 0.51 |
| + checkpoints | 1 | 0.60 |

v5 BBs take ~3x the damage of v4 BBs (Yamato 150k vs 60k, Montana 131k vs 54k): v5 has no stance (heading broadside to the anchor, no angling, no dodge).

## Stance (2026-11-14)

`bot5/stance.rs`, 4 Hz per bot, staggered (phase `stance`).

- Rates per hull heading (72 bins, 5°), HP share per minute:
  - in: each threat whose shells land on our cell, while our cell is seen, `Fire.at(range, our aspect to it)` × risk × k_in / our hp;
  - out: our value on the target × share of mounts bearing at that heading (masks sampled from the turret arcs at registration).
- Heading: best within ±45° of the bearing to the next waypoint (astern: of its reciprocal); at the station, any heading at 1/4 throttle.
  Priced over 30 s, the swing included at the hull's turn rate and rudder lag. A held heading stays unless beaten by 10%.
- Gear veto, only when the route lies behind the bow and stance is active: turn unless the turn would sink us.
  The turn is sailed on the navigator's hull model (`Hull::step`, 0.5 s steps, until the bow is within 10° of the best heading ahead, at most 300 s)
  from the hull's real speed and power; incoming at each step's heading, risk taken out, summed as a share of HP now. ≥ 1: back toward the station.
  Re-checked at most every 1 s; gear held at least 8 s. The hull swings while it backs and brakes, so a backing ship is not priced as stopped.
- Stance active: the navigator gets heading weight 1, `prefer_reverse` astern, `forbid_reverse` ahead. Inactive (nothing in or out): the navigator's own gear.
- Counters: `stance_ahead/turn/astern/hold`, `stance_veto_turn/astern`. Trace: `SHIPS_BOT5_STANCE_TRACE`.
- Pending: dodge (shells in the air), destroyed mounts, torpedo exposure by aspect.
- Escape at the station (2026-11-19): a hold heading must leave a way out from where the hull lies: ahead clear of land for a
  turning radius and opening from the guns (within 90° of away) or reaching covered water (no enemy shells land, or unseen at
  concealment), or astern (full astern from rest, `Hull::step`, 60 s) reaching covered water before land. Bow toward the enemy is
  fine when backing reaches cover; an astern-only heading creeps astern. None passing: the unmasked best (`stance_hold_no_escape`).
- Land (2026-11-19): within 1.5 turning radii + clearance of land, the stance heading must be reachable ahead: the turn onto it at
  full power on `Hull::step`, either way, then a turning radius sailed, clear of the navigator's rollout limit. Else the next best
  heading in the window, up to 4 (`stance_land_reangle`); none, with the bow within a ship length of land under 0.3 of top speed and
  a ship length astern clear: astern, held ≥ 8 s, re-checked after (`stance_astern_land`). Not against land: unchanged
  (`stance_land_none`); astern blocked too: unchanged (`stance_boxed`).
  Why: nose-in with the route behind or a big turn wanted, stance forbade reverse and the navigator flipped full ahead / astern every
  1-10 s (3 s engine commit) without moving. Trace `SHIPS_BOT5_HELM_TRACE` (1 Hz per bot: gear, sdf at bow/stern, aspect).
- First result (12v12 t10, seeds 1-4, both sides): v5 0/8, damage ratio 0.58 (0.60 before). v5 BBs still take ~2.5× v4's incoming per second and fire 30-40% fewer salvos; Montana takes 36k from torpedoes (v4: 0). Stance 56 µs mean per frame, ~260 µs worst; drive +50 µs.

## Threat, cover first, disengage (2026-11-14)

v4's ladder, native, per bot each hive pass (`World::danger`, `hive::Danger`).

- Threat = 1 − exp(−H · Σ share), H = −ln(0.6) · 0.2 · match time left (time to die at 20% of the match left scores 0.4).
  share per enemy, HP now per second: its curve at our aspect to it, k_in, only while its shells land on our cell and we are seen
  (firing bloom, or concealment on a dark plan); the larger of now and FORECAST_S ahead; times the share of its aim we draw
  against lit allies in its range, weighted 1/d².
- Time to win: sail into range of our target at the band middle, then sink it alone (our curve, k_out).
- Cover first unless we alone light our target: threat ≥ 0.35 and not outliving time to win by 1.25 (aggression-scaled), or any
  enemy in range that takes our HP share faster than we take its. The scan then admits only stations whose worse-moment
  exposure stays under the 0.35 threat rate (covered water has none); none passing → disengage (`no_cover`).
- Disengage replaces Retreat (no HP trigger): starts seen at threat ≥ 0.4 unless outliving time to win, 15 s cooldown
  unless ≥ 0.6; held ≥ 20 s while seen; ends at threat ≤ 0.35 or outliving time to win by 1.25. Station: escape scan from
  us, lee berths, gaps, lattice in gun range, scored on exposure and the sail there only; dark for hulls that may go dark.
- Counters: `cover_first`, `threat_high`; releases `posture`, `no_cover`.

## Stations that shoot (2026-11-14)

- A fighting station must pass the exact shell check to its target; the scan checks its best 32 in order. None passing:
  no fighting station (under fire: disengage to cover, the only use of cover that cannot shoot).
- Guns: while the assigned target cannot be shot, the nearest seen enemy in range with a clear shot, held 4 s.
- Flank: the scan's foes are the flank's enemies, the target, and anything already reaching us; threats stay all enemies.
- Crossfire: stations hit from bearings spread over 90° (now or ahead) fail the gate, the hold check included.
- Result (12v12 t10, seeds 1-4, both sides): v5 0/8, damage 0.64 (best so far). Guns blocked at the station: under 1% of
  terrain blocks; the rest are in transit or disengaging.

## Threat rings, window, hops, two flanks (2026-11-15)

- Fire fix: offence `Fire` took reload, barrels and shell damage from the target, not us. `Fire::new(curves, gun, pose)`. Calibration refit (`bot5_learn.py` on the 8 matches after the fix).
- Secondaries: snapshot rows 32/33 carry secondary range and dpm (v4's `_secondary_dps` at half range on its own hull, once per scene). `Fire` adds them inside their range (exposure, threat, out-trade, stance, our value); calibration books mains only.
- Threat ring per enemy (`station::ring_of`): secondary range + 500 m unless we out-trade it by 1.25 at half that range. No fighting station or hop inside any ring, now or ahead. Rings go to the navigator as route walls (pulled 200 m short of the station), re-sent only when one moves 500 m.
- v4 window: every station within 6 km of us (not the no-contact opening). No station deeper (own→enemy spawn axis) than the shallowest enemy whose guns reach it.
- Hops replace far-goal checkpoints: with no non-negative fighting station passing the exact shot, the cell within 6 km unseen now and ahead (concealment), out of rings and short of the front, gaining most (≥ 500 m) on the anchor; held dark. Else the negative station, else disengage when threatened, else a window-clipped approach.
- Flanks: two by default (one for under 3 enemies); seam roles removed. Flank-mates spread: station value × (1 + 0.5 · min(sep / 60°, 1)), sep the least angle at the anchor to a flank-mate's station.
- Focus: a target our shells cannot clear terrain to from here keeps 0.2 of its score; the focus bonus counts only allies who had a clear shot on it.
- 8 matches v4 vs v5 (12v12 t10, seeds 1-4, both sides), refit calibration: 0/8, damage ratio 0.59 (0.64 before refit, 0.64 previous build). v5 BBs still take ~2-3x v4's damage.

## v4 vs v5 baseline (2026-11-16, `make vs`, 7390b98b + point-table fix)

100 matches of 12v12 t10: seeds 0-49, each played with v5 on team 0 and on team 1. Results in `~/Documents/ships_sim/vs_baseline_20261116`.

| v5 wins | damage v5/v4 | v5 damage share | v5 ships alive at end | v4 ships alive at end |
|---|---|---|---|---|
| 6 / 100 | 0.65 | 0.378 ± 0.006 | 3-9% | 40-72% |

Every v5 class takes more damage and deals less than the same v4 class. Biggest gaps: BB damage taken (Yamato 143k vs 78k, KW 179k vs 126k) and DD/CA damage dealt (Shimakaze 18k vs 65k, Smolensk 18k vs 52k).

## Dodge and torpedo avoidance (2026-11-16)

- Torpedoes: the hub pushes every armed enemy torpedo the target team has seen (`set_torpedoes`, once per frame). Each
  bot's navigator gets those within 3 km whose closest approach on our held course passes within a hull length + 30 s of
  top speed (`torp_closes`), as v4 torpedo obstacles (id −100000 − k, length 0). The navigator's torpedo override wins over stance and dodge.
- Dodge (`bot5/dodge.rs`), every 3 frames staggered: fresh enemy shells within 1.5 km → sail the lie (stance heading,
  last throttle) and full rudder held 0/1/2/3/4/6 s/whole flight × levels 4/3/2/0/−1 on `Hull::step` at 0.25 s; v4's
  `shell_hit` (caliber³ over 300 mm, citadel ×4, citadel box from the hull's mesh). Stays in the progress cone, off land;
  must beat the lie by 0.5 after 0.3/rad off-lie and 0.2/power gear costs. Rudder/throttle set directly until the last shell lands.
- Counters: `dodge_turn/astern/forward/stop/lie`, `dodge_frames`, `torp_override_frames`. Trace: `SHIPS_BOT5_DODGE_TRACE`.

| build | v5 wins / 100 | v5 damage share | hub mean µs | drive µs |
|---|---|---|---|---|
| baseline | 6 | 0.378 | 1464 | 303 |
| + dodge + torpedoes | 28 | 0.438 | 2250 | 1023 |
| + closest-approach filter | 32 | 0.443 | 1967 | 745 |

Still open: v5 BBs take 3-6× v4's torpedo damage (KW 25k vs 7k, Yamato 15k vs 4k); drive is 2.5× baseline (torpedo
override bypasses the steering cache); dodge has no aspect weighting (v4 used hit rows).

### Dodge aspect weighting (2026-11-16)

Each shell is matched to the enemy within 10° of the bearing it came from (99.9% matched). Its weight per arrival aspect is that
shooter's AP or HE (as the shell is) damage per hit on our hull, best aim slot `v[0] / landed` (`Curve::hit_at`), over
the row's mean. Rows look right (Yamato vs 460 mm AP: 0.37 bow, 1.47 at ~65°, 0.75 stern; HE flat).

| build | v5 wins / 100 | v5 damage share |
|---|---|---|
| dodge, no aspect (2 batches) | 28, 32 | 0.438, 0.443 |
| dodge + aspect (2 batches) | 22, 31 | 0.427, 0.434 |

Pooled −1.0 point, about 1.4 s.e.: no measured gain, possibly a small loss.

t11_vs_t11 (Wotan vs Vermont, both v5, 100 seeds per arm; `SHIPS_BOT5_DODGE_ASPECT=0` turns it off; telemetry `angling`
= angle off the bow of the heaviest incoming shell, per ship and AP/HE, sampled while shells are in the air):

| arm | Wotan wins / draws / losses | Wotan dealt | Wotan vs AP: 0-45° / 70-115° | Wotan vs HE: 0-45° / mean |
|---|---|---|---|---|
| aspect on | 90 / 10 / 0 | 156.5k | 52% / 49% | 41% / 64° |
| aspect off | 68 / 31 / 1 | 128.0k | 2% / 76% | 43% / 60° |

Vermont fires 88% HE. Against AP, aspect weighting turns Wotan bow-in instead of broadside. Against HE, Wotan still lies
within 45° about 40% of the time in both arms: that angling comes from stance, whose `Fire.at` takes the better shell
(AP) at each aspect, with no shell read (v4: two HE salvos in a row → price HE).

### Shell read (2026-11-16)

v4's SalvoClock read in `bot5/shell_read.rs`: each enemy shell landing near us is attributed by its landing velocity to
the enemy within 10° of that bearing (no owner lookup); landings > 3 s apart start a salvo. Last salvo AP → AP, last two
HE → HE, else the worse curve. Applied to every threat (`Fire::read` in `threats_of`). `SHIPS_BOT5_SHELL_READ=0` turns it off.

| test | read on | read off |
|---|---|---|
| t11 Wotan wins / draws (both v5) | 71 / 29 | 96 / 4 |
| t11 Vermont dealt | 174.8k | 159.3k |
| t11 Wotan vs HE within 45° | 36% | 42% |
| 12v12 vs v4: v5 share | 0.431 | 0.427, 0.434 (aspect batches) |

Wotan's angling to HE is from the HE curve itself (bow-on takes fewer HE hits), not a missing read. In t11 the read helps
Vermont (it reads Wotan's AP and kites stern-on more). 12v12: no change.

## Trade rings, brawler push, spotter roles (2026-11-16)

- `bot5/trade.rs`: v4 `_desired_by_trade` port. Kill rates per range from mains + secondaries (`Fire`) + torpedoes (v4 torpedo_curve/rate; snapshot now carries torpedo stats, guns-bear aspect, rudder lag). Band = contiguous ranges within 10% of the chosen range's ratio; ring = band lo − 500 m. Replaces `station::ring_of`.
- Brawler (secondaries ≥ 0.75 × mains at half secondary range) with the guns on us inside 90°: band 0–min(4 km, trade range), no ring, no cover-first, disengage only at force threat.
- Kite: inside the near half of any enemy's band, stations are limited to ±35° of the away bearing; v4 kite leg as fallback. The same cone applies to Disengage.
- Spotters: one per flank (torp DD > DD > BB > CA). Spot target = nearest field enemy in the flank. Band capped at target detection − 500 m, ideally past own detection. LOS to it required. With no field contact, it hunts: last seen position, then enemy spawn.
- Fixed: ring route walls were never cleared once rings went empty, which left ships idling against a stale wall.

| t11 Wotan vs Vermont, both v5, 100 each | Wotan | Vermont | draw | Vermont dealt |
|---|---|---|---|---|
| before (read on) | 71 | | | 174.8k |
| rings + spotters | 58 | 42 | 0 | 228.2k |
| rings, spotters off | 33 | 25 | 42 | 223.5k |

t11 outcomes cluster into ~5 distinct trajectories per arm; effective N is small.

| 12v12 v5 vs v4 | wins | share |
|---|---|---|
| dodge2 | 32 | 0.443 |
| read | 21 | 0.431 |
| rings + spotters | 21 | 0.426 |
