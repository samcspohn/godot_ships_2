# Fight v2 — Design

Replaces the cone Dijkstra Fight and most skills with two skills (Fight, Retreat)
driven by threat rings that remember where we were shot, the reach/LOS fields,
and a learned per-map heatmap.

Status: rings and the window search are implemented first, ahead of the heatmap.

## Problems being solved

| Symptom | Cause |
|---|---|
| CAs run open lanes (red), get lit and die | Only seen / LKP / presumed enemies are priced; a lane is "safe" until someone is spotted there |
| Ships take the middle (orange) and run into the spawn crossfire | Crossfire is priced against believed positions, which cluster centrally early on |
| Push → focused → ring blooms → retreat → focus drops → push again; Yamato circles | Rings depend on who is shooting me *now* |
| Ships kite each other while undetected | Harm/value walk has no notion of spotting or ideal range |
| Fight search cost (2 ms p50, 55 ms max) | Global Dijkstra over ±90° cones every reprice |
| Too many skills with overlapping jobs | Engage/Hold/Cover/Position/Spot/Flank/Chase/Camp/Hunt |

## 1. Map heatmap

Two layers, both recorded every match:
- **Occupancy** (enemy-centric): where enemies are. Hull-agnostic; feeds presumption.
- **Experience** (self-centric): per class, per cell we sat in, how often we were
  spotted, the damage we took, and the bearings it came from. Answers "am I spotted
  and damaged here" directly, partial island cover included, since it is measured.

Experience is the exposure term Fight reads; occupancy fills cells the bots never
visit (policy bias: a safe cell nobody uses has no experience) and drives presumption.

### Partial cover within a 1 km cell
Occupancy → exposure at our cell evaluates LOS and reach from every 300 m visibility
sub-cell of the 1 km occupancy cell: the cell spots us with the share of its sub-cells
that see us (any sub-cell seeing us makes it possible). An island covering half a cell
halves it, never zeroes it.

### Data
- Grid: 1 km cells over the map bounds.
- Time buckets: 0–2, 2–5, 5–10, 10+ min of match time.
- Per cell × bucket, in the frame of a team (spawn-relative, mirrored so both teams learn from every match):
  - `occupancy_s`: ship-seconds an enemy hull spent in the cell, split by class (DD, CA, BB, CV).
  - `fired_s`: ship-seconds spent firing main battery from the cell.
  - `deaths`: sinks in the cell.
- Experience, per cell × bucket × our class:
  - `present_s`, `spotted_s`, `damage_hp` (share of max HP taken).
  - `from[8]`: damage by source bearing octant (shielding side, crossfire spread).
- Mirroring uses the spawn geometry `EnemyPresumption._resolve_geometry` already resolves.

### Recording
- Server samples every alive ship once per second (cheap: position → cell index → increment).
- Recorded in `make sim`, `make ab`, `make watch` and live matches. Humans and bots both count.
- Match end (`_broadcast_match_end` / abandoned path) writes a delta file:
  `user://heatmap/<map signature>/<timestamp>-<pid>.delta`.
  Parallel sim jobs never write the same file.

### Merging
- On load, merge deltas into `user://heatmap/<map signature>/prior.bin` under a lock
  (same pattern as `gunnery_bake.lock`), then delete them.
- EMA per match: `prior = prior * (1 - α) + match * α`, α ≈ 0.02, so roughly the last 50
  matches dominate and the map can drift as behaviour changes.
- Map signature: `NavigationMapManager.get_visibility_signature()` (geometry + cell size);
  a map edit starts a fresh prior.

### Seed (no data yet)
- Occupancy along HPA routes from enemy spawn to caps and to the map's flank lanes,
  decaying with route distance per time bucket (ships ~10 m/s).
- Seed weight decays as real matches accumulate (seed counts as N = 5 matches).

### A/B hygiene
- `make ab` must read a frozen prior and not write: both arms see the same map,
  otherwise the learning itself is a confound. `--heatmap-frozen` flag; `ab.sh` passes it.
- Bot-only training learns bot habits. Occupancy (not outcome) limits the feedback loop;
  live human matches correct it.

### Derived fields (per map, per time bucket; rebuilt when prior changes)
- `presumed[c]`: normalised enemy occupancy, the presumption prior.
- `risk[class][c]`: spotted_s / present_s and damage_hp / present_s, shrunk toward the
  occupancy estimate where present_s is small.
- Not stored: per-hull spot risk. That is computed live from `presumed` + LOS + the hull's
  concealment, so one prior serves every hull.

### Consumers
- `EnemyPresumption`: when nothing is spotted, presumed contacts come from `presumed`
  (top-k occupancy clusters of the current time bucket) instead of the spawn line.
- Fight's exposure: presumed mass contributes spot and fire risk weighted by belief.
  Red lanes become high-exposure; the orange stop point falls out of `shooter_arc`
  once the two spawn-side clusters are separate contacts.
- Fight's score: `risk` as a prior exposure term on each window cell.

No anchors: the window search has no long jumps. Island-cover thresholds (how much
fire an island must block, how much of the enemy it must still see) will depend on
ship stats, likely HP and concealment.

## 2. Two skills

| Skill | Is | Absorbs |
|---|---|---|
| Fight | Ring walk below | Engage, Hold, Cover, Position, Spot, Flank, Chase, Camp, Hunt |
| Retreat | Current Disengage, unchanged: shoot while we can't go dark, go dark if we can, reach islands while angled | Retreat, Disengage |

Stance (turn vs astern sim, angling) stays the shared layer under both.
Class doctrine shrinks to the Fight ↔ Retreat thresholds and objective weights.

### Retreat triggers
- Flank falls: friendly mass on our side below threshold vs enemy mass → Retreat toward
  the nearest friendly group, then Fight resumes there with their spotting.
- Lit and threat above the class threshold (CA: 0.5 / release 0.4, existing).
- A rusher out-trading us at every range closing (Kaiser on Yamato): Retreat kites;
  friends get a priority bonus for a target closing on a teammate.

## 3. Fight: ring window search

No travel cost. Pick the position that maximises output (damage, later spotting,
survival) within a short window; Retreat handles being threatened. The short window
plus Retreat keep positioning stable and safe.

### Rings (`BotBehavior.ring`)
- `ideal`: the trade curve (`_trade`): nearest range we out-trade it by TRADE_MARGIN
  (push), else where the trade is best, never inside its secondaries (hold).
- While it shoots at us: `ring = max(ideal, distance + RING_SHOT_MARGIN_M)`, the last
  radius where we were shot.
- Otherwise the remembered ring sinks back to `ideal` at RING_DECAY_MPS (5 m/s).
- Retreat feeds the rings: retreating under fire raises them, so Fight resumes outside
  where we were last shot instead of walking straight back in.
- Removed: friend screening, approach check, rate limit.

### Search (`VisibilityGrid.fight_search`)
- Cells (300 m) reachable by water within WINDOW_M (6 km) of the ship. Measured 12v12: 0.47 ms p50, 1.2 ms p99, 8.8 ms max.
- A cell is no station when it is inside an enemy's ring and that enemy's shells
  land there (or its fire plane is unknown). Shielded cells inside a ring are fine.
- Score = value − harm: best target's trade value less exposure (focus, crossfire arc,
  front relief, harm price λ).
- Must shoot ≥ 1 enemy. No such cell in the window: the window cell nearest the most
  valued target, outside rings (chase); re-picked every MARCH_MS, so it leads the ship in.
  Against an enemy we never out-trade (no push range), the chase also stays out of its
  sight inside our concealment radius: it walks their concealment ring.
- Survival check: the straight run to the station costing ≥ SURVIVE_SHARE (0.8) of our
  HP hands off to Disengage, its toward cone turned onto the station (at most CONE off
  the threat axis), so cover is sought near where Fight wanted to be.
- Held station kept while it still has a target outside the rings, unless a cell beats
  it by MARCH_SWITCH_REL / ABS.

### Crossfire and spacing (done)
- A target is worth up to XF_BONUS (BB: XF_BONUS_BB) more as our bearing to it swings
  90° off any friend's whose guns reach it.
- Team-mates' claimed stations cost a cell up to SPACING_COST of the held net value
  inside SPACING_M.

### Later in this section
- `need` per enemy (open / LOS cover / shield) once spotting value lands.
- Flank collapse: not a flat retreat but a fighting retreat / kite toward the friendly
  group that maximises time alive while slowing the enemy push (draw their fire and
  movement, stay in range of friends' guns).

## 4. Roles from one objective

`spot_value(c)` = Σ over enemies only we would spot from `c` (no friend or friend radar
spots them) of the friends' dps on them, minus our exposure while spotting.

| Situation | Outcome |
|---|---|
| DD, nobody spotting | Concealment beats their detection: spots cheaply, drops torps (`torp_value`) |
| DD, a friend already spots | spot_value → 0; gunboats: behind cover when close, open water behind a push or on a wide flank |
| CA with radar | Spots from LOS cover; short range + high threat prefer LOS cover over shield |
| BB | Spots only when no one else does; otherwise gunboats, seeks crossfire with other BBs |
| No DDs left | CAs out-spot BBs on concealment alone |
| No BBs left | Fewer heavy guns reach forward cells; CAs push |

`torp_value`: torpedo lanes from the cell into presumed enemy density; ties into the
deferred torpedo-exposure work.

## 5. Performance targets

| Piece | Where | Budget |
|---|---|---|
| Heatmap sample | server, 1 Hz | < 0.05 ms |
| Prior merge | load / match end | < 1 s |
| Per-enemy ring | per bot, 5 s cache | < 0.3 ms |
| Window search | per bot, 1 s | < 1 ms p50, < 5 ms max |

## Phases

1. **Rings + window search** (done, first cut): shot-memory rings, 3 km window, chase.
2. **Heatmap**: occupancy + experience recorders, delta files, merge + EMA, seed,
   frozen flag for A/B, debug overlay. Experience as a Fight score term; occupancy into presumption.
3. **Crossfire bonus and `need`** (open / LOS cover / shield).
4. **Roles**: `spot_value`, radar, `torp_value`.
5. **Collapse**: delete the absorbed skills, doctrine to Fight/Retreat.
6. **Terrain tuck** (skill-gated): finer reach/LOS near coast so a ship can sit against an
   island with only bow or stern guns open; navigator allowed to ram the shore to get covered;
   leaves the tuck when unspotted or HP allows.
7. **Match plan** (after the heatmap): per spawn, a route of islands to take in order;
   hold each until its enemies are dead or pushed back, then advance to the next.

## Open questions
- RING_DECAY_MPS: 5 m/s takes ~3 min to give back 1 km.
- WINDOW_M: 6 km vs a speed-scaled window (DDs cover more ground).
- Survival check ignores detection: an unseen ship is not stopped (Disengage needs us lit).
- Experience shrinkage: how many seconds of `present_s` before it overrides occupancy.
