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
4. Stance + dodge (port existing native pricing).
5. Static risk field.
6. Aptitude-ordered resolution + team terms: spot, crossfire, tank, stacking, retreat.
7. Learned risk from sim + live.
8. DD torpedoes. Then CV.

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
- Point-table keys and file loading still go through `BotGunnery._point_table` / `saturation_mask` / fire helpers. Move these into a standalone point-table module, then delete BotGunnery's db.
- Fire clearance is native (`Gunnery::clearance`): terrain via terrain-only `sim_can_shoot_over_terrain_impl`, then allies predicted along the arc against their hull box (`crosses`, unit-tested); 0.5 s / 50 m cache. Both count toward blocked_s.
- No torpedo/shell dodge, no hold fire, no stance (phase 4). DD torpedoes not fired (phase 8).
- Telemetry measures lead error of the aimed point only, not dispersion or real impacts. Keys count individual gun shots.
