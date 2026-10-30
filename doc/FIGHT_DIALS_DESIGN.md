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
| `range_m` | m | desired(P) trade range; advantage A; lateness L; push range (nearest range we out-trade P) | ring / walk radius |
| `exposure_tol` | share of max HP per s | trade HP, time to win, advantage | which cells are allowed: open water, cover, dark |
| `stealth` | 0–1 | trade ratio at `range_m` vs at our concealment radius | route cost of being seen while moving |
| `cover_kind` | 0 hidden … 1 shielded | sustain under P's fire at `range_m` | cover test: hidden from LOS vs shielded from most guns but still spotting |
| `spot` | 0–1 | per target: concealment gap, survival at its concealment radius, our damage there, target fit | value of cells that reveal enemies |
| `advance` | 0–1 | local friends vs enemies covering P, advantage | checkpoint delay (camp vs push) |

### Advantage A (−1…1)
Team outlook (strength, points), local force ratio near the priority, lateness.
Positive: closer `range_m`, higher `exposure_tol`, faster `advance`. Any ship brawls
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
- the route cost is weighted by `stealth` where the route is seen;
- checkpoint value is scaled by `advance`.

STATION / COVER / SPOT stop being modes, so there is nothing to flip between; the held
station persists across ticks under one objective.

## Steps
1. Dial module: compute, ease and log only (match metrics, debug overlay, BOT_TRACE). No behaviour change.
2. Feed the existing pieces: ring radius ← `range_m`; station acceptance ← `exposure_tol`;
   checkpoint delay ← `advance`; cover test ← `cover_kind`; BB spot ring ← target's concealment radius.
3. Merge cover and spot into FightStation's score; remove the modes.
4. Remove the per-class arms and flags.

Each step is measured with DestChurn (churn.py, disengage.py) and `make ab`.
