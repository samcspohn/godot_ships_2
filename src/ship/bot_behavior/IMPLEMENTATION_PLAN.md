# Bot Behavior Overhaul — Implementation Plan

## Overview

Replace the monolithic `get_nav_intent()` functions in each behavior subclass with a
composable system of **Skills** (positioning logic) driven by a **Tactical State Machine**
(decision logic) with a **BloomProbe** helper (concealment-aware gun policy).

### Architecture Summary

```
TACTICAL STATE MACHINE (lives in get_nav_intent, per ship class)
├── HUNTING      → SkillHunt / SkillChase   + guns: fire at will
├── SNEAKING     → [chosen skill]           + guns: hold fire
├── ENGAGED      → [chosen skill]           + guns: fire at will
└── DISENGAGING  → SkillKite (forced)       + guns: managed by BloomProbe
                   (overrides whatever skill was active)

SKILL (pure positioning — "where do I go, what heading")
├── SkillHunt         — push toward last-known / average enemy
├── SkillChase        — pursue a specific ship that went dark
├── SkillFindCover    — navigate behind an island, station-keep
├── SkillAngle        — present angled armor toward threat
├── SkillBroadside    — orbit at engagement range, full turret bearing
├── SkillKite         — fighting retreat, guns on target
├── SkillTorpedoRun   — flank for beam-on torpedo launch
├── SkillRetreat      — pure survival, run away
├── SkillFlank        — approach from off-angle, depth varies by class
├── SkillCamp         — hold position in firing range, local maneuver
├── SkillSpot         — position to reveal enemies for teammates
└── SkillSpread       — post-process modifier, anti-clump (not standalone)

GUN POLICY (derived from tactical state — never set independently)
├── FIRE    — shoot at will
├── HOLD    — no guns (torpedoes OK)
└── PROBE   — hold fire, bloom decaying, waiting for detection check
```

---

## File Layout

All new files go under `src/ship/bot_behavior/`. Existing files are modified in place.

```
src/ship/bot_behavior/
├── behavior.gd                  # MODIFIED — base class, keep utilities, remove old positioning
├── bb_behav.gd                  # MODIFIED — new get_nav_intent using state machine + skills
├── ca_behav.gd                  # MODIFIED — new get_nav_intent using state machine + skills
├── dd_behav.gd                  # MODIFIED — new get_nav_intent using state machine + skills
├── behavior_descriptions.txt    # UPDATED — reflects new architecture
├── IMPLEMENTATION_PLAN.md       # THIS FILE
├── tactical_state.gd            # NEW — TacticalState enum + BloomProbe
├── skill_context.gd             # NEW — SkillContext data object
├── skills/
│   ├── skill.gd                 # NEW — base Skill class
│   ├── skill_hunt.gd            # NEW
│   ├── skill_chase.gd           # NEW
│   ├── skill_find_cover.gd      # NEW — wraps _get_cover_position
│   ├── skill_angle.gd           # NEW — wraps _intent_angle
│   ├── skill_broadside.gd       # NEW — wraps BB arc + broadside heading
│   ├── skill_kite.gd            # NEW
│   ├── skill_torpedo_run.gd     # NEW — wraps DD torpedo positioning
│   ├── skill_retreat.gd         # NEW — wraps DD retreat logic
│   ├── skill_flank.gd           # NEW
│   ├── skill_camp.gd            # NEW
│   ├── skill_spot.gd            # NEW
│   └── skill_spread.gd          # NEW — post-process modifier
```

---

## Step-by-Step Implementation

### Phase 0 — Scaffolding (no behavior changes)

#### Step 0.1 — Create `skill_context.gd`

Data object passed to every skill. No logic, just references.

```gdscript
class_name SkillContext
extends RefCounted

var ship: Ship
var target: Ship              # current primary target (may be null)
var server: GameServer
var behavior: BotBehavior     # access to shared utilities (_get_valid_nav_point, etc.)

static func create(s: Ship, t: Ship, srv: GameServer, b: BotBehavior) -> SkillContext:
    var ctx = SkillContext.new()
    ctx.ship = s
    ctx.target = t
    ctx.server = srv
    ctx.behavior = b
    return ctx
```

File: `src/ship/bot_behavior/skill_context.gd`

---

#### Step 0.2 — Create base `skill.gd`

Abstract base class for all skills.

```gdscript
class_name BotSkill
extends RefCounted

## Execute the skill and return a NavIntent, or null if not applicable.
func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
    return null

## Optional: return true if the skill has "arrived" or completed its objective.
func is_complete(ctx: SkillContext) -> bool:
    return false

## Optional: reset internal state when the skill is selected fresh.
func reset() -> void:
    pass
```

File: `src/ship/bot_behavior/skills/skill.gd`

---

#### Step 0.3 — Create `tactical_state.gd`

Contains the TacticalState enum and BloomProbe helper class.

```gdscript
class_name TacticalStateHelper
extends RefCounted

enum TacticalState { HUNTING, SNEAKING, ENGAGED, DISENGAGING }

## BloomProbe — tracks concealment bloom decay to decide when to stop shooting.
##
## Usage:
##   - Call enter() when transitioning into DISENGAGING.
##   - Call update() every physics tick while in DISENGAGING.
##   - Read went_dark / probe_failed after update() to drive state transitions.
##   - Read can_fire() to gate gun usage.
class BloomProbe:
    enum Phase { SHOOTING, PROBING }
    var phase: Phase = Phase.SHOOTING
    var _probe_timer: float = 0.0
    var probe_timeout: float = 4.0   # seconds to wait during probe

    var went_dark: bool = false       # set true for one tick when ship goes undetected
    var probe_failed: bool = false    # set true for one tick when probe times out

    func enter() -> void:
        phase = Phase.SHOOTING
        _probe_timer = 0.0
        went_dark = false
        probe_failed = false

    func update(ship: Ship, delta: float) -> void:
        went_dark = false
        probe_failed = false

        if not ship.visible_to_enemy:
            went_dark = true
            return

        match phase:
            Phase.SHOOTING:
                if _is_bloom_decayed(ship):
                    phase = Phase.PROBING
                    _probe_timer = 0.0
            Phase.PROBING:
                _probe_timer += delta
                if not ship.visible_to_enemy:
                    went_dark = true
                elif _probe_timer >= probe_timeout:
                    probe_failed = true
                    phase = Phase.SHOOTING

    func can_fire() -> bool:
        return phase == Phase.SHOOTING

    func _is_bloom_decayed(ship: Ship) -> bool:
        var c: Concealment = ship.concealment
        return c.bloom_radius <= (c.params.p() as ConcealmentParams).radius
```

File: `src/ship/bot_behavior/tactical_state.gd`

---

#### Step 0.4 — Create `skills/` directory

Just the folder. All skill files go here.

---

### Phase 1 — Extract existing logic into skills (no behavior changes yet)

The goal of this phase is to wrap every existing function into its corresponding skill
class **without changing any game behavior**. Each skill calls back into `behavior.gd`
utility functions. The old `get_nav_intent()` functions remain active — skills are just
available alongside them.

#### Step 1.1 — `skill_hunt.gd`

Wraps `behavior._get_hunting_position()`.

Source logic: `behavior.gd` `_get_hunting_position()` (L668-727).

```
func execute(ctx, params) -> NavIntent:
    - Call ctx.behavior._get_hunting_position(ctx.server, friendly, fallback)
    - If result is zero, fall back to sailing forward (toward enemy spawn side)
    - Compute approach heading from ship to destination
    - Return NavIntent.create(dest, heading)
    - throttle_override = 4 (full speed)
```

Params:
- `approach_multiplier: float` — standoff ratio of gun range (default per class)
- `cautious_hp_threshold: float` — HP ratio below which to bias toward friendlies

No new math. Direct wrapper.

---

#### Step 1.2 — `skill_find_cover.gd`

Wraps `behavior._get_cover_position()` + CA's arrival/station-keep state machine.

Source logic:
- `behavior.gd` `_get_cover_position()` (L1197-1323)
- `behavior.gd` `_find_cover_position_on_island()` (L1094-1180)
- `ca_behav.gd` `get_nav_intent()` island state tracking (L322-439)

This is the most complex extraction because the CA's `get_nav_intent` interleaves
cover searching with arrival detection, recalc cooldowns, and fire suppression.

Internal state (lives on the skill instance, not on behavior):
- `_target_island_id: int`
- `_target_island_pos: Vector3`
- `_target_island_radius: float`
- `_nav_destination: Vector3`
- `_nav_destination_valid: bool`
- `_cover_recalc_ms: int`
- `_last_in_range_ms: int`

```
func execute(ctx, params) -> NavIntent:
    - If no valid destination, call ctx.behavior._get_cover_position(desired_range, target)
    - If cover found, store island state, set destination
    - If no cover, return null (caller falls back to another skill)
    - If have destination:
        - Periodically recalc cover position (cooldown gated)
        - Check arrival (hysteresis: arrival_radius vs exit_radius)
        - Compute tangential heading to island
        - If arrived: return intent with hold_radius, near_terrain = true
        - If en route: return intent, near_terrain = true
    - Expose can_shoot: bool for caller to check shell arc viability

func is_complete(ctx) -> bool:
    - Return true when arrived at cover and station-keeping

func reset() -> void:
    - Clear all island state, force fresh search
```

Params:
- `desired_range_ratio: float` — ratio of gun range for engagement distance
- `abandon_too_close: float` — min range ratio, abandon island if enemies closer
- `abandon_too_far: float` — max range ratio, abandon island if enemies farther
- `recalc_cooldown_ms: int` — minimum ms between cover recalculations
- `push_timeout_ms: int` — time without in-range targets before seeking new island (20s)

---

#### Step 1.3 — `skill_angle.gd`

Wraps `ca_behav._intent_angle()`.

Source logic: `ca_behav.gd` `_intent_angle()` (L208-261).

```
func execute(ctx, params) -> NavIntent:
    - Get target (use ctx.target or fallback to nearest spotted)
    - Compute enemy bearing from ship position
    - Pick angle range based on target ship class (from params or lookup)
    - Choose CW or CCW angling based on secondary threat exposure
    - Maintain engagement range while angling
    - Return NavIntent with angled heading + destination
```

Params:
- `angle_ranges: Dictionary` — {ShipClass → Vector2(min_rad, max_rad)}
- `desired_range_ratio: float` — fraction of gun range to maintain

No state. Pure function of current positions.

---

#### Step 1.4 — `skill_broadside.gd`

Wraps BB's broadside heading + arc movement logic.

Source logic:
- `bb_behav.gd` `_calculate_broadside_heading()` (L237-274)
- `bb_behav.gd` `_apply_arc_movement()` (L168-201)
- `bb_behav.gd` `get_nav_intent()` engagement section (L211-235)
- `behavior.gd` `_calculate_tactical_position()` (L575-646)

Internal state:
- `current_arc_direction: int`
- `arc_direction_timer: float`

```
func execute(ctx, params) -> NavIntent:
    - Compute spotted danger center (prefer spotted over stale)
    - Calculate engagement range from HP + params
    - Call ctx.behavior._calculate_tactical_position(range, min_safe, flank_bias)
    - Apply arc movement around danger center
    - Calculate broadside heading (perpendicular to threat, bow-in offset)
    - Blend with evasion heading if ship is visible
    - Return NavIntent with position + broadside heading
```

Params:
- `engagement_range_ratio: float`
- `range_increase_when_damaged: float`
- `min_safe_distance_ratio: float`
- `arc_speed: float`
- `arc_change_time: float`
- `bow_in_offset_deg: float`
- `flank_bias_healthy: float`
- `flank_bias_damaged: float`

---

#### Step 1.5 — `skill_torpedo_run.gd`

Wraps DD's torpedo flanking + launch heading logic.

Source logic:
- `dd_behav.gd` `_get_torpedo_run_intent()` (L330-362)
- `dd_behav.gd` `_calculate_torpedo_launch_heading()` (L365-409)

```
func execute(ctx, params) -> NavIntent:
    - Choose flank side (left/right of target, pick closer to ship)
    - Position at concealment_radius * approach_ratio from target beam
    - Apply spread offset
    - If ship has torpedoes: compute beam-on launch heading
    - Else: compute approach heading
    - Return NavIntent with flank position + launch heading
```

Params:
- `approach_ratio: float` — multiplier of concealment radius for standoff (default 1.5)
- `prefer_escape_route: bool` — bias heading toward escape direction

No persistent state needed.

---

#### Step 1.6 — `skill_retreat.gd`

Wraps DD's retreat logic.

Source logic: `dd_behav.gd` `_get_retreat_intent()` (L296-327).

```
func execute(ctx, params) -> NavIntent:
    - Find closest enemy
    - Compute retreat direction (directly away from closest)
    - Scale retreat distance by concealment radius
    - If HP below threshold, bias toward nearest friendly cluster
    - Apply spread offset
    - Return NavIntent with retreat position + retreat heading
```

Params:
- `retreat_multiplier: float` — multiplier of concealment radius (default 2.0)
- `friendly_bias_hp_threshold: float` — HP ratio below which to bias toward friends
- `friendly_bias_weight: float` — 0-1 blend toward friendlies

---

#### Step 1.7 — `skill_kite.gd`

New skill, but logic extracted from existing patterns across CA/BB/DD retreat.
The key difference from Retreat: kiting maintains guns on target while pulling away.

```
func execute(ctx, params) -> NavIntent:
    - Get danger center (spotted preferred, fallback to all known)
    - Compute desired range (engagement range based on HP + params)
    - If closer than desired: move away along line from danger center through ship
    - If further: close cautiously
    - Compute heading: angled to threat (not perpendicular, not direct — ~30-45° for armor)
    - Blend retreat vector toward friendlies with configurable weight
    - Validate nav point
    - Return NavIntent with kite position + angled heading
```

Params:
- `desired_range_ratio: float` — fraction of gun range to hold
- `pull_toward_friendly_weight: float` — 0-1, how much to bias toward friendlies
- `angle_to_threat_deg: float` — desired angle relative to threat bearing (armor angling)

This is the skill that DISENGAGING forces.

---

#### Step 1.8 — `skill_spread.gd`

Wraps `behavior._calculate_spread_offset()`. Not a standalone skill — it's a
post-processor that modifies another skill's NavIntent.

Source logic: `behavior.gd` `_calculate_spread_offset()` (L648-662).

```
## Apply spread offset to an existing NavIntent.
func apply(intent: NavIntent, ctx: SkillContext, params: Dictionary) -> NavIntent:
    - Get friendly ships from server
    - Compute spread offset via ctx.behavior._calculate_spread_offset(...)
    - Add offset to intent.target_position
    - Re-validate the position
    - Return modified intent
```

Params:
- `spread_distance: float`
- `spread_multiplier: float`

---

### Phase 2 — New skills (Flank, Camp, Chase, Spot)

These skills contain new logic not currently in the codebase.

#### Step 2.1 — `skill_flank.gd`

Positions the ship to approach from off-angle relative to the enemy formation.

**Initialization** (called once at match start or when skill is first selected):
- Read ship's `spawn_position` index from team_info to determine left/center/right
- Roll `flank_depth` — random float clamped by ship class:
  - BB: 0.1–0.3 (shallow, never behind enemy lines)
  - CA: 0.2–0.5 (moderate)
  - DD: 0.4–0.9 (deep penetration)
- Determine `flank_side` from spawn position:
  - Spawn index < team_count/3 → prefer left
  - Spawn index > team_count*2/3 → prefer right
  - Center → pick side based on nearest island or random

**Execution:**
```
func execute(ctx, params) -> NavIntent:
    - Get enemy avg position and enemy team facing direction
      (from spawn-to-center vector or average velocity)
    - Compute enemy "front" as a line perpendicular to their facing
    - Compute flank target position:
        - Start from enemy center
        - Rotate by flank_side * flank_angle (90-135° from enemy front)
        - Push out to engagement range
        - Push forward by flank_depth * (distance from enemy front to enemy spawn)
    - Clamp depth by concealment:
        - Max depth where ship would be within gun_range of enemy avg
          but further than own concealment from nearest known enemy
    - Safety: abort flanking if fewer than min_friendlies_in_front allies
              between flanker and enemy center (don't flank when team collapsed)
    - Validate nav point
    - Heading: approach heading toward flank position
    - Return NavIntent
```

Params:
- `flank_angle_deg: float` — target angle off enemy front (default 90)
- `flank_depth: float` — 0-1, set at init, how deep behind enemy lines
- `flank_side: int` — -1 left, +1 right, set at init
- `engagement_range_ratio: float` — distance from enemy center
- `min_friendlies_in_front: int` — safety check (default 1)
- `concealment_depth_clamp: bool` — whether to limit depth by concealment

Internal state:
- `_flank_side: int` — assigned once
- `_flank_depth: float` — assigned once
- `_initialized: bool`

---

#### Step 2.2 — `skill_camp.gd`

Hold position in firing range, maneuver locally to dodge. Retreat if focused.

```
func execute(ctx, params) -> NavIntent:
    - If not yet in firing range:
        - Navigate toward enemy cluster center, stop at desired_range
    - If in firing range:
        - Hold position with small random local offsets (jitter for dodge)
        - Track incoming fire concentration (number of enemies targeting us)
        - If focused (>= focus_threshold enemies shooting at us):
            - Return null to signal caller to switch to Kite/Retreat
    - Heading: broadside to primary target (same logic as SkillBroadside)
    - Return NavIntent with hold_radius > 0 for station-keeping
```

Params:
- `desired_range_ratio: float` — how far forward to push (default 0.65)
- `jitter_radius: float` — local maneuver radius when holding (default 500)
- `focus_threshold: int` — enemies targeting us before we consider retreating

Note: focus detection is a future feature. For now, can approximate by counting
enemies within gun range that have LOS. The retreat signal (returning null) lets the
state machine in `get_nav_intent` decide what to fall back to.

---

#### Step 2.3 — `skill_chase.gd`

Pursue a specific ship that went dark. Doesn't give up easily.

Internal state:
- `_chase_target_id: int` — instance ID of the ship we're chasing
- `_last_known_pos: Vector3` — last seen position
- `_last_known_velocity: Vector3` — last seen velocity (for prediction)
- `_last_seen_time: float` — when we last saw them
- `_chase_started_time: float`

```
func execute(ctx, params) -> NavIntent:
    - If chase target is visible again: update tracking, navigate toward them
    - If chase target is not visible:
        - Predict position: last_known_pos + last_known_velocity * time_since_seen
        - Validate predicted position is on navigable water
        - If predicted pos is behind an island, navigate around the island
          (use _get_valid_nav_point which already handles this)
        - If time_since_seen > chase_timeout: return null (give up)
    - Commitment check:
        - Compute advantage = (own_hp / own_max_hp) vs estimated target HP
        - Count nearby friendlies within support_radius
        - If advantage + support is low, reduce chase aggression (larger standoff)
        - If advantage is high, push hard (minimal standoff)
    - Heading: approach heading toward predicted position
    - Return NavIntent with full speed throttle override
```

Params:
- `chase_timeout: float` — seconds before giving up (BB: 60, DD: 30)
- `support_radius: float` — radius to count nearby friendlies for commitment
- `min_hp_ratio: float` — own HP below which to abandon chase
- `standoff_ratio: float` — gun range fraction to hold when cautious

---

#### Step 2.4 — `skill_spot.gd`

Position to reveal enemies for teammates.

```
func execute(ctx, params) -> NavIntent:
    - Get all known enemy positions (spotted + last known)
    - Get friendly positions
    - For DDs:
        - Find the nearest unspotted enemy (from server.get_unspotted_enemies)
        - Navigate to within own concealment radius of that enemy
        - If no unspotted: position between friendly fleet and nearest enemy cluster
          at own concealment radius from enemies (screening position)
    - For BBs/CAs (passive spotting):
        - This skill is less about positioning and more about target priority
        - Position to maintain LOS on enemies that friendly BBs are engaging
        - Stay within gun range of the same targets your fleet is shooting
    - Heading: approach heading toward spotting position
    - Return NavIntent (DD: possibly with throttle_override for speed)
```

Params:
- `approach_distance: float` — how close to get (DD: concealment radius, others: gun range)
- `screen_offset: float` — distance ahead of friendly fleet for screening position
- `prefer_unspotted: bool` — prioritize revealing new contacts vs maintaining existing

Note: DD spotting + SNEAK travel mode combine naturally. The DD uses SkillSpot to find
where to go, and SNEAKING ensures it doesn't shoot while getting there.

---

### Phase 3 — Wire up state machines in each behavior class

This is where the old `get_nav_intent()` functions get replaced. Each ship class gets
its own decision tree that selects skills and manages tactical state transitions.

#### Step 3.1 — Add shared state to `behavior.gd`

Add to the base class (available to all ship types):

```gdscript
# Tactical state
var _tactical_state: TacticalStateHelper.TacticalState = TacticalStateHelper.TacticalState.HUNTING
var _bloom_probe: TacticalStateHelper.BloomProbe = TacticalStateHelper.BloomProbe.new()
var _active_skill_name: StringName = &""

# Skill instances (created in subclass _init or on first use)
var _skills: Dictionary = {}  # StringName -> BotSkill

# Flank identity (rolled once at match start)
var _flank_side: int = 0      # -1 left, +1 right, 0 unassigned
var _flank_depth: float = 0.0
var _flank_initialized: bool = false
```

Add a helper to initialize flank identity from spawn position:

```gdscript
func _init_flank_identity(ship: Ship, server: GameServer) -> void:
    if _flank_initialized:
        return
    _flank_initialized = true

    # Determine side from spawn position relative to team center
    var spawn_pos = ship.global_position  # at init time, this IS the spawn
    var team_spawn = server.get_team_spawn_position(ship.team.team_id)
    var to_ship = spawn_pos - team_spawn
    to_ship.y = 0.0
    var right = Vector3.UP.cross(team_spawn).normalized()
    var side_dot = to_ship.dot(right)

    if abs(side_dot) < 2000.0:
        # Center spawn — random side
        _flank_side = 1 if randf() > 0.5 else -1
    else:
        _flank_side = 1 if side_dot > 0 else -1

    # Roll depth clamped by subclass (override in subclass)
    _flank_depth = _roll_flank_depth()

func _roll_flank_depth() -> float:
    ## Override per ship class
    return randf_range(0.2, 0.5)
```

Also add the shared `can_fire_guns()` method:

```gdscript
func can_fire_guns() -> bool:
    match _tactical_state:
        TacticalStateHelper.TacticalState.SNEAKING:
            return false
        TacticalStateHelper.TacticalState.DISENGAGING:
            return _bloom_probe.can_fire()
        _:
            return true
```

---

#### Step 3.2 — Modify `engage_target` in behavior.gd

The base `engage_target()` must respect the gun policy:

```gdscript
func engage_target(target: Ship) -> void:
    if not can_fire_guns():
        # Still aim (for instant response when policy changes) but don't fire
        _ship.artillery_controller.set_aim_input(target.global_position + target_aim_offset(target))
        return
    # ... existing fire logic ...
```

Each subclass that overrides `engage_target` must also call `can_fire_guns()`.
- `ca_behav.gd`: already has `shooting_ok` guard — add `and can_fire_guns()` to it
- `dd_behav.gd`: has `should_shoot_guns` — AND it with `can_fire_guns()`
- `bb_behav.gd`: uses `super.engage_target(target)` — base class handles it

---

#### Step 3.3 — Rewrite `ca_behav.gd` `get_nav_intent()`

The CA is the most complex and benefits the most from this refactor.

**Skill instances** (created in `_init` or lazily):
- `_skill_hunt: SkillHunt`
- `_skill_cover: SkillFindCover`
- `_skill_angle: SkillAngle`
- `_skill_kite: SkillKite`
- `_skill_flank: SkillFlank`
- `_skill_spot: SkillSpot`
- `_skill_spread: SkillSpread`

**Decision tree:**

```
func get_nav_intent(target, ship, server) -> NavIntent:
    ctx = SkillContext.create(ship, target, server, self)
    _init_flank_identity(ship, server)
    delta = 1.0 / Engine.physics_ticks_per_second

    # --- Update tactical state transitions ---
    _update_ca_tactical_state(ship, target, server, delta)

    # --- Execute skill based on state ---
    var intent: NavIntent = null
    match _tactical_state:
        HUNTING:
            if _last_known_enemy_valid:
                intent = _skill_chase.execute(ctx, chase_params)
            if intent == null:
                intent = _skill_hunt.execute(ctx, hunt_params)
        SNEAKING:
            intent = _execute_ca_sneak_skill(ctx)
        ENGAGED:
            intent = _execute_ca_engaged_skill(ctx)
        DISENGAGING:
            intent = _skill_kite.execute(ctx, kite_params)

    # --- Fallback ---
    if intent == null:
        intent = _skill_angle.execute(ctx, angle_params)
    if intent == null:
        intent = _intent_sail_forward(ship)

    # --- Post-process spread ---
    intent = _skill_spread.apply(intent, ctx, spread_params)
    return intent
```

**CA sneak skill selection** (`_execute_ca_sneak_skill`):
```
- If island cover is available or active: SkillFindCover
- Elif should flank (healthy, no island): SkillFlank
- Else: SkillHunt (push forward silently)
```

**CA engaged skill selection** (`_execute_ca_engaged_skill`):
```
- If at cover (SkillFindCover.is_complete): SkillFindCover (station-keep + fire)
- Elif should reposition to new cover: SkillFindCover (reset + seek)
- Elif target in range, open water: SkillAngle
- Else: SkillKite
```

**CA tactical state transitions** (`_update_ca_tactical_state`):
```
match _tactical_state:
    HUNTING:
        if has_spotted_enemies:
            _tactical_state = SNEAKING
            _pick_ca_sneak_skill()

    SNEAKING:
        if ship.visible_to_enemy:
            _tactical_state = DISENGAGING
            _bloom_probe.enter()
        elif skill_cover.is_complete():
            _tactical_state = ENGAGED

    ENGAGED:
        # Normal combat. State changes driven by skill returning null
        # (e.g. island abandoned, need to relocate)
        pass

    DISENGAGING:
        _bloom_probe.update(ship, delta)
        if _bloom_probe.went_dark:
            _tactical_state = SNEAKING
        elif _bloom_probe.probe_failed:
            _tactical_state = ENGAGED
            # Accept the fight — enemy has LOS at base concealment
```

---

#### Step 3.4 — Rewrite `dd_behav.gd` `get_nav_intent()`

**Skill instances:**
- `_skill_hunt: SkillHunt`
- `_skill_chase: SkillChase`
- `_skill_torpedo_run: SkillTorpedoRun`
- `_skill_retreat: SkillRetreat`
- `_skill_kite: SkillKite`
- `_skill_flank: SkillFlank`
- `_skill_spot: SkillSpot`
- `_skill_spread: SkillSpread`

**Decision tree:**

```
func get_nav_intent(target, ship, server) -> NavIntent:
    ctx = SkillContext.create(ship, target, server, self)
    delta = 1.0 / Engine.physics_ticks_per_second

    _update_dd_tactical_state(ship, target, server, delta)

    var intent: NavIntent = null
    match _tactical_state:
        HUNTING:
            if _last_known_enemy_valid:
                intent = _skill_chase.execute(ctx, chase_params)
            if intent == null:
                intent = _skill_hunt.execute(ctx, hunt_params)
        SNEAKING:
            intent = _execute_dd_sneak_skill(ctx)
        ENGAGED:
            # DD engaged = spotted, fighting. Use kite or retreat.
            if hp_ratio < 0.3:
                intent = _skill_retreat.execute(ctx, retreat_params)
            else:
                intent = _skill_kite.execute(ctx, kite_params)
        DISENGAGING:
            intent = _skill_kite.execute(ctx, kite_params)

    if intent == null:
        intent = _intent_sail_forward(ship)

    intent = _skill_spread.apply(intent, ctx, spread_params)
    return intent
```

**DD sneak skill selection** (`_execute_dd_sneak_skill`):
```
- If target is BB/CA and has torpedoes: SkillTorpedoRun
- Elif should spot for team (no DDs spotting, team needs vision): SkillSpot
- Elif should flank: SkillFlank
- Else: SkillTorpedoRun (default DD sneak behavior)
```

**DD tactical state transitions:**
```
match _tactical_state:
    HUNTING:
        if has_targets:
            _tactical_state = SNEAKING

    SNEAKING:
        if ship.visible_to_enemy:
            _tactical_state = DISENGAGING
            _bloom_probe.enter()

    ENGAGED:
        if not ship.visible_to_enemy:
            _tactical_state = SNEAKING

    DISENGAGING:
        _bloom_probe.update(ship, delta)
        if _bloom_probe.went_dark:
            _tactical_state = SNEAKING
        elif _bloom_probe.probe_failed:
            _tactical_state = ENGAGED
```

DD `_roll_flank_depth()` override: `return randf_range(0.4, 0.9)`
DD `probe_timeout`: shorter (3.0s — DDs are fast, concealment is small)

---

#### Step 3.5 — Rewrite `bb_behav.gd` `get_nav_intent()`

BBs are simpler — they rarely sneak (too large) and primarily engage directly.

**Skill instances:**
- `_skill_hunt: SkillHunt`
- `_skill_chase: SkillChase`
- `_skill_broadside: SkillBroadside`
- `_skill_kite: SkillKite`
- `_skill_camp: SkillCamp`
- `_skill_flank: SkillFlank`
- `_skill_find_cover: SkillFindCover` (low HP fallback)
- `_skill_spread: SkillSpread`

**Decision tree:**

```
func get_nav_intent(target, ship, server) -> NavIntent:
    ctx = SkillContext.create(ship, target, server, self)
    delta = 1.0 / Engine.physics_ticks_per_second

    _update_bb_tactical_state(ship, target, server, delta)

    var intent: NavIntent = null
    match _tactical_state:
        HUNTING:
            if _last_known_enemy_valid:
                intent = _skill_chase.execute(ctx, chase_params)
            if intent == null:
                intent = _skill_hunt.execute(ctx, hunt_params)
        SNEAKING:
            # BBs rarely sneak, but can when disengaging at low HP
            intent = _skill_kite.execute(ctx, kite_params)
        ENGAGED:
            intent = _execute_bb_engaged_skill(ctx)
        DISENGAGING:
            intent = _skill_kite.execute(ctx, kite_params)

    if intent == null:
        intent = _skill_broadside.execute(ctx, broadside_params)
    if intent == null:
        var fwd = _calc_approach_heading(ship, ship.global_position - ship.basis.z * 10000)
        intent = NavIntent.create(ship.global_position - ship.basis.z * 10000, fwd)

    intent = _skill_spread.apply(intent, ctx, spread_params)
    return intent
```

**BB engaged skill selection** (`_execute_bb_engaged_skill`):
```
- If center spawn and healthy: SkillCamp (push to range, hold)
- If flank spawn: SkillFlank → SkillBroadside once in position
- If damaged (< 40% HP): SkillKite
- If very damaged (< 20% HP) and island nearby: SkillFindCover
- Default: SkillBroadside
```

**BB tactical state transitions:**
BBs mostly stay in HUNTING → ENGAGED. They transition to DISENGAGING only when
very damaged. They almost never SNEAK (concealment too large to matter). The
state machine is simpler:

```
match _tactical_state:
    HUNTING:
        if has_spotted_enemies:
            _tactical_state = ENGAGED

    ENGAGED:
        if not has_enemies:
            _tactical_state = HUNTING
        elif hp_ratio < 0.2 and ship.visible_to_enemy:
            _tactical_state = DISENGAGING
            _bloom_probe.enter()

    DISENGAGING:
        _bloom_probe.update(ship, delta)
        if _bloom_probe.went_dark:
            # BB went dark — rare but possible (behind island, enemies died)
            _tactical_state = SNEAKING
        elif _bloom_probe.probe_failed:
            _tactical_state = ENGAGED
        # BB can also re-engage if HP is stabilized by repair
        if hp_ratio > 0.35:
            _tactical_state = ENGAGED

    SNEAKING:
        # Unlikely state for BB, transition out quickly
        if ship.visible_to_enemy:
            _tactical_state = ENGAGED
        elif has_spotted_enemies:
            _tactical_state = ENGAGED
```

BB `_roll_flank_depth()` override: `return randf_range(0.1, 0.3)`

---

### Phase 4 — Integration and cleanup

#### Step 4.1 — Remove dead code from `behavior.gd`

After all three behaviors are converted, the following base class methods become
internal utilities only called by skills (not directly by `get_nav_intent`):

**Keep** (used by skills as utilities):
- `_get_valid_nav_point()`
- `_calculate_tactical_position()`
- `_calculate_spread_offset()`
- `_get_hunting_position()`
- `_get_cover_position()`
- `_find_cover_position_on_island()`
- `_get_danger_center()` / `_get_spotted_danger_center()`
- `_get_nearest_enemy()`
- `_get_flanking_info()` / `_get_flanking_direction()`
- `_gather_threat_positions()`
- `_compute_safe_direction()` / `_compute_hide_heading()`
- `_sdf_walk_to_shore()` / `_is_los_blocked_with_clearance()`
- `_tangential_heading()`
- `_safe_validate()`
- `_get_ship_clearance()` / `_get_turning_radius()`
- `_normalize_angle()` / `_get_ship_heading()`
- All torpedo functions
- `pick_target()`, `pick_ammo()`, `target_aim_offset()`
- `try_use_consumable()`
- `get_target_weights()`, `get_positioning_params()`, etc. (config methods)
- `can_fire_guns()` (new)
- `_init_flank_identity()` (new)

**Remove** (replaced by state machine + skills):
- `get_desired_position()` — replaced by skills
- `get_desired_heading()` — evasion logic moves into SkillKite / SkillAngle
- `should_evade()` — replaced by tactical state check
- `_calculate_evasion_heading()` — absorbed into SkillKite
- `_get_weighted_threat_bearing()` — absorbed into SkillKite
- The default `get_nav_intent()` in behavior.gd — each subclass provides its own

**Remove from subclasses:**
- `bb_behav.gd`: `get_desired_position()`, `_apply_arc_movement()`, `_calculate_broadside_heading()` → moved to SkillBroadside
- `ca_behav.gd`: `_intent_hunt()`, `_intent_angle()`, `_intent_sail_forward()`, all island state vars → moved to skills
- `dd_behav.gd`: `get_desired_position()`, `_get_retreat_intent()`, `_get_torpedo_run_intent()`, `_calculate_torpedo_launch_heading()` → moved to skills

#### Step 4.2 — Update `bot_controller_v4.gd`

The bot controller calls `behavior.engage_target()` which now respects `can_fire_guns()`.
No other changes needed — the controller already calls `behavior.get_nav_intent()` and
passes the result to the navigator. The skill system is invisible to the controller.

One small change: remove the fallback legacy path in `_update_nav_intent()` that calls
`get_desired_position()`. After phase 3, all behaviors implement `get_nav_intent()` via
the skill system, so the legacy fallback is dead code.

#### Step 4.3 — Update `behavior_descriptions.txt`

Rewrite to reflect the new skill-based architecture, tactical states, and bloom probe.

---

## Implementation Order (Priority)

| Order | What | Depends On | Risk |
|-------|------|------------|------|
| 1 | Phase 0 (scaffolding: SkillContext, BotSkill, TacticalState, BloomProbe) | Nothing | None — no behavior changes |
| 2 | Phase 1.1 SkillHunt | Phase 0 | Low — direct wrapper |
| 3 | Phase 1.7 SkillKite | Phase 0 | Medium — new skill but simple math |
| 4 | Phase 1.6 SkillRetreat | Phase 0 | Low — direct wrapper |
| 5 | Phase 1.5 SkillTorpedoRun | Phase 0 | Low — direct wrapper |
| 6 | Phase 1.8 SkillSpread | Phase 0 | Low — direct wrapper |
| 7 | Phase 3.4 DD state machine | Steps 2-6 | Medium — first full rewrite |
| 8 | Test DD thoroughly | Step 7 | — |
| 9 | Phase 1.3 SkillAngle | Phase 0 | Low — direct wrapper |
| 10 | Phase 1.2 SkillFindCover | Phase 0 | High — most complex extraction |
| 11 | Phase 3.3 CA state machine | Steps 9-10 | Medium — complex decision tree |
| 12 | Test CA thoroughly | Step 11 | — |
| 13 | Phase 1.4 SkillBroadside | Phase 0 | Low — direct wrapper |
| 14 | Phase 3.5 BB state machine | Step 13 | Low — simplest state machine |
| 15 | Test BB thoroughly | Step 14 | — |
| 16 | Phase 2.1 SkillFlank | Phase 0 | Medium — new logic |
| 17 | Phase 2.2 SkillCamp | Phase 0 | Medium — new logic |
| 18 | Phase 2.3 SkillChase | Phase 0 | Medium — new logic |
| 19 | Phase 2.4 SkillSpot | Phase 0 | Medium — new logic |
| 20 | Wire new skills into state machines | Steps 16-19 | Low — just adding branches |
| 21 | Phase 4 cleanup | All above | Low |

**Recommended approach:** Implement DD first (steps 1-8) as the proving ground. DD has
the simplest existing `get_nav_intent` and benefits immediately from SNEAK/DISENGAGE.
Once DD works, CA and BB follow the same pattern with confidence.

---

## Testing Strategy

- **Parity test:** Before rewriting a behavior's `get_nav_intent`, record a match replay.
  After rewriting, the ship should behave similarly in equivalent situations (same island
  choices, same engagement ranges, same retreat triggers). Exact parity isn't needed —
  the refactor intentionally improves some behaviors — but gross regressions should be caught.

- **State transition logging:** Add a debug print whenever `_tactical_state` changes:
  `print("[%s] %s → %s (skill: %s)" % [ship.name, old_state, new_state, _active_skill_name])`
  This makes it easy to trace why a ship is doing something unexpected.

- **Bloom probe logging:** Log probe start, probe end (success/fail), and bloom_radius
  at each transition. Verify that ships stop shooting when bloom decays and resume when
  probe fails.

- **Flank identity logging:** At match start, log each ship's flank_side and flank_depth
  to verify distribution makes sense (BBs shallow, DDs deep, sides match spawn positions).

- **Edge cases to test:**
  - Ship spawns center → should camp or pick a random flank
  - Ship gets spotted immediately on match start → should go straight to ENGAGED
  - Ship is last alive on team → hunting/chasing should still work
  - No islands on map → CA should fall back to angle/kite, never hang waiting for cover
  - All enemies dead except one hiding → chase should activate
  - Ship behind island gets spotted by DD within concealment → DISENGAGE → bloom probe
    should correctly identify that enemy has LOS at base concealment

---

## Notes

- **Skills are stateless where possible.** Only SkillFindCover, SkillBroadside (arc state),
  SkillFlank (identity), and SkillChase (target tracking) need persistent state. Everything
  else is a pure function of current game state.

- **Skills never set gun policy.** That's entirely the tactical state machine's job via
  `can_fire_guns()`. Skills just return positions and headings.

- **Skills can return null.** This signals "I can't do my job right now" and the caller
  falls back to another skill. This is how SkillFindCover says "no island available" and
  how SkillCamp says "I'm taking too much fire."

- **The base class `get_nav_intent()` should remain as a fallback** during migration but
  can be removed once all three subclasses are converted (Phase 4).

- **Torpedo firing is orthogonal.** `engage_target()` handles torpedo logic via
  `update_torpedo_aim()` and `try_fire_torpedoes()`. Torpedoes are NOT gated by
  `can_fire_guns()` — only guns are. DDs should always fire torpedoes when they have
  a solution, even while sneaking.