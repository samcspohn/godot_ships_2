# Bot Behavior Overhaul — Progress Tracker

## Phase 0 — Scaffolding
- [x] Step 0.1 — `skill_context.gd`
- [x] Step 0.2 — `skills/skill.gd`
- [x] Step 0.3 — `tactical_state.gd`
- [x] Step 0.4 — `skills/` directory

## Phase 1 — Extract existing logic into skills
- [x] Step 1.1 — `skill_hunt.gd`
- [x] Step 1.2 — `skill_find_cover.gd`
- [x] Step 1.3 — `skill_angle.gd`
- [x] Step 1.4 — `skill_broadside.gd`
- [x] Step 1.5 — `skill_torpedo_run.gd`
- [x] Step 1.6 — `skill_retreat.gd`
- [x] Step 1.7 — `skill_kite.gd`
- [x] Step 1.8 — `skill_spread.gd`

## Phase 2 — New skills
- [x] Step 2.1 — `skill_flank.gd`
- [x] Step 2.2 — `skill_camp.gd`
- [x] Step 2.3 — `skill_chase.gd`
- [x] Step 2.4 — `skill_spot.gd`

## Phase 3 — Wire up state machines
- [x] Step 3.1 — Add shared state to `behavior.gd` (`_tactical_state`, `_bloom_probe`, `_flank_*`, `can_fire_guns()`, `_init_flank_identity()`)
- [x] Step 3.2 — Modify `engage_target` in `behavior.gd` (gun policy via `can_fire_guns()`)
- [x] Step 3.3 — Rewrite `ca_behav.gd` `get_nav_intent()` (state machine + skills + legacy debug sync)
- [x] Step 3.4 — Rewrite `dd_behav.gd` `get_nav_intent()` (state machine + skills + sneak torpedo run)
- [x] Step 3.5 — Rewrite `bb_behav.gd` `get_nav_intent()` (state machine + skills + camp/broadside engage)

## Phase 4 — Integration and cleanup
- [ ] Step 4.1 — Remove dead code from `behavior.gd`
- [ ] Step 4.2 — Update `bot_controller_v4.gd`
- [ ] Step 4.3 — Update `behavior_descriptions.txt`

---

## Notes
- Phase 0–2: Skills exist alongside old code — no behavior changes until Phase 3
- Phase 3: Old `get_nav_intent()` replaced with state machine + skills (DONE)
- Phase 4: Dead code removal after testing confirms all behaviors work correctly
- All diagnostic errors after Phase 3 are LSP indexing issues (new `class_name` files not yet scanned by Godot editor). They resolve on project rescan.
- CA `engage_target` now gates on `can_fire_guns()` and references `_skill_cover._nav_destination_valid`
- DD `engage_target` adds `and can_fire_guns()` to `should_shoot_guns` check
- BB uses base class `engage_target` which already has `can_fire_guns()` gate
- DD bloom probe timeout set to 3.0s (shorter than default 4.0s)
- BB transitions: HUNTING → ENGAGED (skips SNEAKING), DISENGAGING re-engages at HP > 35%