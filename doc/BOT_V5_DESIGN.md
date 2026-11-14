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
