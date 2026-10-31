# Fight Dials — Design

Every ship can play any role. What a ship does comes from its stats and the match
situation through a few continuous, eased dials, and one station search reads them.
Replaces the per-class arms (brawl / opening / close / engaged / low threat), the class
flags (`brawler()`, `conceals_well`, `prefer_cover`, gunboat) and Fight's STATION /
COVER / SPOT modes. Disengage stays as the retreat. Builds on doc/FIGHT_V2_DESIGN.md.

## Problems being solved

| Symptom | Cause |
|---|---|
| Destination jumps (8–11 s between >500 m jumps) | Fight re-picks STATION/COVER/SPOT every tick; each switch resets the held station; callers search one FightStation with different params |
| Open-water BB leaves a good station for cover | `prefer_cover` runs the cover search first, every tick |
| KW sits on cover late in the match at threat ~0 | Cover checkpoints only advance after 10 s idle; nothing says "ahead, so push" |
| Yamato's spot station sits on its own concealment ring | SkillSpot assumes we out-conceal the target (`sr = max(sr - spread, det + LOOK_M)`) |
| BBs try to spot DDs | No target-fit test |
| Roles fixed by class | brawler(), gunboat, prefer_cover are class/hull flags, not situational |

## Dials

Recomputed every behaviour tick, eased (time constant, small hysteresis). Units are
physical so they compare across hulls.

| Dial | Unit | Inputs | Drives |
|---|---|---|---|
| `ring_shift` | 0–1 | advantage A, lateness L | every enemy's ring moves this share from desired(e) in to its push range (nearest range we out-trade it by TRADE_MARGIN); the ring walk over all local enemies sets the actual range |
| `exposure_tol` | share of max HP per s | trade HP, time to win, advantage | which cells are allowed: open water, cover, dark |
| `approach_stealth` | 0–1 | worst trade on the approach (seen and in its guns) vs the trade at the shifted ring | route cost of being seen while moving (KW) |
| `conceal_edge` | 0–1 | torpedo reach past our concealment radius; top priorities' concealment radius past ours | preference for stations outside enemy detection, hold-fire, dark spotting (DD, stealthy CA). Guns bloom to their range, so never count |
| `cover_kind` | 0 hidden … 1 shielded | sustain under P's fire at the shifted ring | cover test: hidden from LOS vs shielded from most guns but still spotting |
| `spot` | 0–1 | per target: concealment gap, survival at its concealment radius, our damage there, target fit | value of cells that reveal enemies |
| `advance` | 0–1 | local friends vs enemies covering P, advantage | checkpoint delay (camp vs push) |

Logged alongside: `station_d`, the held station's distance to its target (the range the walk actually chose), and `incoming` (share of max HP per s now).

### Advantage A (−1…1)
Team outlook (strength, points), local force ratio near the priority, lateness.
Positive: rings shifted in, higher `exposure_tol`, faster `advance`. Any ship brawls
when ahead late; a brawler camps when outnumbered.

### Spot desire, per target
- Concealment gap: our concealment radius vs the target's. Ours smaller: we spot unseen (DD style), spot = 1.
- Otherwise spotting means being seen at the target's concealment radius: survival there =
  trade HP over the fire of everyone in reach, against a sustain reference.
- Our damage there: spotting is worth more when we can also shoot what we reveal.
- Target fit: none for a target much stealthier than us that is also faster (a BB vs a DD).
- A hull that cannot survive at the target's radius gets spot ≈ 0: cover, or back until it can go dark.

## One search

FightStation's score (value − harm − route cost) gains the dials:
- value += `spot` × team damage on enemies the cell reveals;
- cells whose exposure exceeds `exposure_tol` are not stations (replaces the fixed 0.4 tests);
- cover is a cell property graded by `cover_kind` (hidden vs shielded-from-k-of-n);
- the route cost is weighted by `approach_stealth` where the route is seen;
- stations outside enemy detection gain by `conceal_edge`;
- checkpoint value is scaled by `advance`.

STATION / COVER / SPOT stop being modes, so there is nothing to flip between; the held
station persists across ticks under one objective.

## Steps
1. Dial module: compute, ease and log only (match metrics, debug overlay, BOT_TRACE). No behaviour change.
2. Feed the existing pieces: rings ← `ring_shift`; route seen-cost ← `approach_stealth`; dark-station preference ← `conceal_edge`; station acceptance ← `exposure_tol`;
   checkpoint delay ← `advance`; cover test ← `cover_kind`; BB spot ring ← target's concealment radius.
3. Merge cover and spot into FightStation's score; remove the modes.
4. Remove the per-class arms and flags.

Each step is measured with DestChurn (churn.py, disengage.py) and `make ab`.

## Step 2 as built
| Dial | Where | Effect |
|---|---|---|
| `ring_shift` | `BotBehavior.update_rings` | each enemy's wanted ring = `BotDials.shifted_ring(desired, push, ring_shift)` |
| `approach_stealth` | FightStation `route_w` | seen-cell route weight × (1 + `APPROACH_W` × dial) |
| `conceal_edge` | FightStation `seen_cost` (Rust `fight_cell`) | a station a free heavy enemy sees keeps 1 − `SEEN_SHARE` × dial of its value |
| `exposure_tol` | `SkillFight._station_ok` | open water accepted while the station's fire on us ≤ tol (replaces threat < 0.4 / station_threat < 0.4); chases keep the threat test |
| `advance` | `SkillFight._checkpoint`, FightStation `checkpoint` | cover idle wait = `COVER_IDLE_S` × 0.5 / advance; brawler checkpoint value × 2·advance |
| `cover_kind` | `SkillCover.search_opts` | OFFENSE takes seen-but-shielded cells only at cover_kind or approach_stealth ≥ `SHIELD_KIND`; the heavy-guns TTK for breaking a shield shrinks to `SHIELD_TTK_SHARE` at 1 |
| `spot` | `SkillFight._choose` | SPOT is not a fallback below `SPOT_DIAL_MIN` |
| — | `SkillSpot._inputs` | a target we do not out-conceal: only its radar, hydro and secondaries keep the spotter off, so the station can sit inside its concealment radius |

