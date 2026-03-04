# AI Navigation System — ships_3

> Comprehensive reference for agentic development. Covers every file, class, data flow, and integration point of the new C++ GDExtension navigation system that replaces `NavigationAgent3D` + raycasts.

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Architecture Diagram](#architecture-diagram)
3. [File Index](#file-index)
4. [C++ GDExtension Layer](#c-gdextension-layer)
5. [GDScript Layer](#gdscript-layer)
6. [Data Flow: One Physics Frame](#data-flow-one-physics-frame)
7. [NavIntent — Behavior↔Controller Contract](#navintent--behaviorcontroller-contract)
8. [Navigation Modes](#navigation-modes)
9. [NavState Machine](#navstate-machine)
10. [Key Algorithms](#key-algorithms)
11. [Dynamic Obstacles & COLREGS Avoidance](#dynamic-obstacles--colregs-avoidance)
12. [Behavior Classes](#behavior-classes)
13. [Integration Checklist](#integration-checklist)
14. [Design Constraints & Gotchas](#design-constraints--gotchas)

---

## System Overview

The AI navigation system is a GDExtension-backed pipeline that gives every bot ship:

- **Terrain-aware pathfinding** (Theta* on a 2-D signed distance field)
- **Physics-validated arc prediction** — the ship's actual turning model is simulated forward to find collision-free steering
- **Incremental forward simulation** — builds a physics-correct path to the target across multiple frames so large ships never grind into islands
- **COLREGS-inspired ship-to-ship avoidance** — larger ships have right-of-way; give-way vessels maneuver starboard
- **Four navigation modes**: POSITION, ANGLE, POSE, STATION_KEEP
- **Island cover zones** — geometry query to find a safe hiding spot behind a land mass relative to a threat

The system replaces:
- `NavigationAgent3D` + navigation region assignment
- 16-raycast `get_threat_vector()` obstacle scan
- Grounded-ship recovery state machine
- Raw `Vector3` position returns from behaviors

---

## Architecture Diagram

```
/dev/null/diagram.txt#L1-25
┌─────────────────────────────────────────────────────────┐
│                    GDScript (per ship)                  │
│                                                         │
│  BotBehavior subclass                                   │
│    └─ get_nav_intent() ──► NavIntent (mode + target)    │
│                                  │                      │
│  BotControllerV4                 ▼                      │
│    ├─ _update_nav_intent()  validates via navigator     │
│    ├─ _execute_nav_intent() ──► ShipNavigator commands  │
│    └─ reads rudder/throttle ◄── ShipNavigator output    │
│                │                                        │
│  NavigationMapManager (autoload singleton)              │
│    └─ holds shared NavigationMap ref                    │
└──────────────────────┬──────────────────────────────────┘
                       │ GDExtension boundary
┌──────────────────────▼──────────────────────────────────┐
│                   C++ GDExtension                       │
│                                                         │
│  NavigationMap (RefCounted)                             │
│    ├─ SDF grid (signed distance field)                  │
│    ├─ Theta* pathfinding                                │
│    ├─ Island metadata + cover zones                     │
│    └─ safe_nav_point / validate_destination             │
│                                                         │
│  ShipNavigator (RefCounted)                             │
│    ├─ holds Ref<NavigationMap>                          │
│    ├─ arc prediction (predict_arc)                      │
│    ├─ incremental forward simulation                    │
│    ├─ COLREGS obstacle avoidance                        │
│    └─ outputs: rudder [-1,1], throttle [-1,4]           │
└─────────────────────────────────────────────────────────┘
```

---

## File Index

### C++ GDExtension — `gdextension/ships_core/src/`

| File | Class | Purpose |
|------|-------|---------|
| `nav_types.h` | *(structs/enums only)* | All shared data types: `ArcPoint`, `SimulatedNavPoint`, `ForwardSimulation`, `ShipParams`, `ShipState`, `SteeringResult`, `DynamicObstacle`, `ObstacleCollisionInfo`, `AvoidanceState`, `IslandData`, `CoverZone`, `RayResult`, `PathResult`, `NavState` enum, `NavMode` enum, inline math utilities |
| `navigation_map.h` / `navigation_map.cpp` | `NavigationMap` | Builds a 2-D SDF grid from island `StaticBody3D` collision shapes (or raycasts). Provides pathfinding, terrain queries, island metadata, cover zone computation, and safe destination helpers. Exposed to GDScript as a `RefCounted` GDExtension class. |
| `ship_navigator.h` / `ship_navigator.cpp` | `ShipNavigator` | Per-ship navigation brain. Consumes a `NavigationMap` ref + live ship state; outputs rudder and throttle each frame. Implements all four navigation modes, arc prediction, incremental forward simulation, and COLREGS avoidance. Exposed to GDScript as a `RefCounted` GDExtension class. |
| `register_types.cpp` | *(registration)* | Registers `NavigationMap` and `ShipNavigator` with Godot's ClassDB so they appear as native classes in GDScript. |

### GDScript — `src/`

| File | Class | Purpose |
|------|-------|---------|
| `src/autoload/navigation_map_manager.gd` | `NavigationMapManager` | **Autoload singleton.** Owns the one shared `NavigationMap` instance. Called once after the map scene loads (`build_map` or `build_map_raycast`). All other systems call `NavigationMapManager.get_map()`. Exposes convenience wrappers: `find_path`, `get_distance`, `is_navigable`, `get_islands`, `compute_cover_zone`, `safe_nav_point`, `validate_destination`. |
| `src/ship/nav_intent.gd` | `NavIntent` | **Lightweight data class.** Returned by behavior `get_nav_intent()`. Carries `mode` (POSITION / ANGLE / POSE / STATION_KEEP), `target_position`, `target_heading`, `zone_center`, `zone_radius`, `preferred_heading`, and optional `throttle_override`. Static factory methods: `NavIntent.position()`, `.angle()`, `.pose()`, `.station()`. |
| `src/ship/bot_controller_v4.gd` | `BotControllerV4` | **Per-ship controller node.** On `_ready` creates a `ShipNavigator`, sets ship params from `ShipMovementV4`, connects the shared `NavigationMap`. Each physics frame: updates navigator state → queries behavior for `NavIntent` → validates intent via `navigator.validate_destination_pose()` → executes the intent → reads `rudder`/`throttle` → sends to `ShipMovementV4`. |
| `src/ship/bot_controller_v4.tscn` | *(scene)* | Scene template for `BotControllerV4`. |
| `src/ship/bot_behavior/behavior.gd` | `BotBehavior` | **Base behavior class.** Shared state for evasion, island cover, and torpedoes. Subclasses override `get_nav_intent()`, `get_evasion_params()`, `get_positioning_params()`, `get_threat_class_weight()`, etc. |
| `src/ship/bot_behavior/bb_behav.gd` | `BBBehavior` | Battleship behavior. Slow deliberate weaves, spreads wide, no island cover, AP ammo. |
| `src/ship/bot_behavior/ca_behav.gd` | `CABehavior` | Cruiser behavior. Uses island cover via `NavigationMapManager.compute_cover_zone()`. Returns `NavIntent.station()` when behind cover. |
| `src/ship/bot_behavior/dd_behav.gd` | `DDBehavior` | Destroyer behavior. Speed variation evasion, aggressive torpedo hunting, high agility. |

### Documentation — `doc/`

| File | Purpose |
|------|---------|
| `doc/ship_navigator_design.md` | Full design document: algorithm descriptions, API surface, C++ implementation plan, performance analysis, migration path, testing strategy. **Source of truth for design intent.** |
| `doc/AI_NAVIGATION_README.md` | This file. Agentic development quick reference. |

---

## C++ GDExtension Layer

### `NavigationMap`

Built **once per match** by `NavigationMapManager`. Immutable after build.

**Build methods:**
- `build_from_collision_shapes(island_bodies: Array[Node3D])` — primary; rasterizes box/sphere/cylinder/convex/concave collision shapes into a binary land mask, then runs jump flood to produce the SDF.
- `build_from_raycast_scan(space_state, island_bodies, collision_mask)` — fallback; casts vertical rays per grid cell, marks cells with hit Y > 0 as land.

**Core query methods (all called from GDScript via wrappers):**

| Method | Returns | Notes |
|--------|---------|-------|
| `get_distance(x, z)` | `float` | Positive = water, negative = inside land. Bilinear interpolated. |
| `get_gradient(x, z)` | `Vector2` | Points away from nearest land. Use for SDF repulsion bias. |
| `is_navigable(x, z, clearance)` | `bool` | True if `get_distance >= clearance`. |
| `raycast(from, to, clearance)` | `Dictionary` | `{hit, position, distance, penetration}` |
| `find_path(from, to, clearance)` | `PackedVector2Array` | Theta* waypoints in XZ space. |
| `get_islands()` | `Array[Dictionary]` | Each dict: `{id, center, radius, area, edge_points}` |
| `get_nearest_island(pos)` | `Dictionary` | Nearest island + `valid` key. |
| `compute_cover_zone(island_id, threat_dir, clearance, min_range, max_range)` | `Dictionary` | `{center, arc_start_angle, arc_end_angle, min_radius, max_radius, best_position, best_heading, valid}` |
| `safe_nav_point(ship_pos, candidate, clearance, turning_radius)` | `Dictionary` | Pushes candidate out of land, slides tangentially along shore. |
| `validate_destination(ship_pos, dest, clearance, turning_radius)` | `Dictionary` | Adjusts approach angle to avoid perpendicular coastline arrivals. |

**Grid parameters:** default cell size `50.0 m`, bounds set from `Rect2` map bounds. SDF data accessible via `get_sdf_data()` for debug heatmap.

---

### `ShipNavigator`

One instance per bot ship. Holds a `Ref<NavigationMap>` (shared, read-only).

**Setup (call once in `_ready`):**
```
/dev/null/setup.gd#L1-12
navigator = ShipNavigator.new()
navigator.set_map(NavigationMapManager.get_map())
navigator.set_ship_params(
    turning_circle_radius,  # meters
    rudder_response_time,   # seconds center→full
    acceleration_time,      # seconds 0→max speed
    deceleration_time,      # seconds max→0
    max_speed,              # m/s
    reverse_speed_ratio,    # fraction of max_speed
    ship_length,            # meters
    ship_beam,              # meters
    turn_speed_loss         # fraction speed lost while turning
)
```

**Per-frame state update (before any navigation call):**
```
/dev/null/state.gd#L1-8
navigator.set_state(
    ship.global_position,   # Vector3
    ship.linear_velocity,   # Vector3
    heading,                # float radians
    angular_velocity.y,     # float rad/s
    movement.rudder_input,  # float [-1, 1]
    current_speed           # float m/s
)
```

**Navigation commands:**

| Command | Signature | Effect |
|---------|-----------|--------|
| `navigate_to_position` | `(target: Vector3)` | Pathfinds to position, avoids terrain |
| `navigate_to_angle` | `(heading: float)` | Acquires heading only, no position target |
| `navigate_to_pose` | `(target: Vector3, heading: float)` | Arrives at position facing direction |
| `station_keep` | `(center: Vector3, radius: float, preferred_heading: float)` | Holds zone at heading |
| `stop` | `()` | Cancels navigation, coasts to stop |

**Output (read after calling a navigation command):**

| Getter | Returns | Notes |
|--------|---------|-------|
| `get_rudder()` | `float [-1, 1]` | Apply to `movement.set_movement_input([throttle, rudder])` |
| `get_throttle()` | `int [-1, 4]` | Matches `ShipMovementV4` throttle levels |
| `get_nav_state()` | `int` | Cast to `NavState` enum value |
| `is_collision_imminent()` | `bool` | True when avoidance override is active |
| `get_time_to_collision()` | `float` | Seconds; `INF` if none |
| `get_desired_heading()` | `float` | Radians; for debug overlay |
| `get_distance_to_destination()` | `float` | Straight-line meters to final target |
| `get_current_path()` | `PackedVector3Array` | A* waypoints (Y=0) for debug draw |
| `get_predicted_trajectory()` | `PackedVector3Array` | Short-range arc prediction (Y=0) |
| `get_simulated_path()` | `PackedVector3Array` | Full incremental forward sim path |
| `get_current_waypoint()` | `Vector3` | Active waypoint being steered toward |
| `get_debug_info()` | `String` | Human-readable state summary |
| `validate_destination_pose(ship_pos, candidate)` | `Dictionary` | `{position, heading, valid, adjusted}` — simulates 10 ship-lengths at multiple headings to confirm safe arrival |

---

## GDScript Layer

### `NavigationMapManager` (Autoload)

**Registration:** Must be listed in `project.godot` autoloads as `NavigationMapManager`.

**Startup sequence:**
1. Map scene finishes loading
2. Call `NavigationMapManager.build_map(island_bodies, map_bounds)` **once**
3. All `BotControllerV4._ready()` calls thereafter will find a valid map

**Key wrapper methods** (thin GDScript↔C++ bridge, converts `Vector3`↔`Vector2` and typed arrays):
- `get_map() -> NavigationMap` — returns the raw C++ object (passed directly to `ShipNavigator.set_map()`)
- `is_map_ready() -> bool` — safe guard before issuing nav commands
- `find_path(from, to, clearance)` — returns `PackedVector2Array`
- `compute_cover_zone(island_id, threat_pos, ship_pos, clearance, min_range, max_range)` — converts threat to direction vector before calling C++
- `safe_nav_point(ship_pos, candidate, clearance, turning_radius) -> Vector3`
- `validate_destination(ship_pos, dest, clearance, turning_radius) -> Vector3`

---

### `NavIntent`

Pure data class (`extends RefCounted`). No logic — just a typed container.

```
/dev/null/navintent_usage.gd#L1-14
# Static factory methods — the only correct way to construct NavIntent:
NavIntent.position(target: Vector3)           -> NavIntent
NavIntent.angle(heading: float)               -> NavIntent
NavIntent.pose(target: Vector3, h: float)     -> NavIntent
NavIntent.station(center: Vector3, radius: float, heading: float) -> NavIntent

# Fields (read by BotControllerV4):
intent.mode           # NavIntent.Mode enum
intent.target_position
intent.target_heading
intent.zone_center
intent.zone_radius
intent.preferred_heading
intent.throttle_override   # -1 = let navigator decide
```

---

### `BotControllerV4`

**Node tree expectation:** Must be a child of the `Ship` node, sibling of `MovementController` (`ShipMovementV4`).

**Key internal methods:**

| Method | Called when | Purpose |
|--------|-------------|---------|
| `_ready()` | scene ready | Creates navigator, sets params, inits behavior |
| `_deferred_init()` | 0.2s after ready | Re-checks map, sets initial destination |
| `_physics_process(delta)` | every physics tick | Full update loop (see data flow below) |
| `_check_intent_events()` | every frame (gated by 1 s cooldown) | Lightweight checks for tactical events that force an immediate intent update |
| `_update_nav_intent()` | every 12th frame (staggered), or immediately on event | Queries behavior, compares raw intent to previous raw intent, validates via `validate_destination_pose` |
| `_is_intent_similar()` | inside `_update_nav_intent` | Returns true if new **raw** intent is close enough to previous **raw** intent — prevents validation-induced oscillation |
| `_execute_nav_intent()` | every frame | Calls appropriate `navigator.*` command |
| `_update_obstacles()` | every 4th frame (offset stagger) | Registers/updates/removes nearby ships as dynamic obstacles |
| `assign_nav_agent(ship)` | external | Sets `_ship` reference |
| `defer_target(ship)` | external | Sets `target` reference |

**Frame stagger:** `_update_nav_intent` runs every 12 frames (≈0.2 s at 60 fps), offset by `bot_id % 12`. `_update_obstacles` runs every 4 frames. This spreads CPU load across bots.

**Event-driven overrides:** `_check_intent_events()` is gated by a 1-second cooldown (`EVENT_COOLDOWN_DURATION`) to prevent rapid re-firing from oscillating game state (e.g. enemies flickering at concealment edge). It sets `_force_intent_next_frame = true` when any of these occur:
- **Visible enemy count changes** — uses the size of `get_valid_targets()` (already filtered to visible enemies) rather than per-ship `visible_to_enemy` tracking, which avoids sensitivity to concealment-edge oscillation
- A **friendly ship dies** (team alive count decreases)
- The ship **reaches its cover position** (`behavior.is_in_cover` transitions from false → true)
- The **target changes** during `_tick_behavior`

When a visibility count change is detected, the controller also rescans targets if the current target is null or no longer visible.

When the flag is set, the same frame bypasses the stagger timer and queries the behavior immediately. The cooldown is then reset to 1 second, preventing further event-driven queries until it expires.

**Intent similarity filtering:** `_is_intent_similar()` compares the new **raw** behavior intent against `_last_raw_intent` (the previous raw intent, stored *before* `validate_destination_pose` adjusts it). This prevents the oscillation cycle where: behavior returns position A → validation adjusts to A′ → next query returns A again → A′ vs A = "different" → re-validate → produces A′ again → repeat forever. By comparing raw-to-raw (A vs A), the intent is correctly identified as "similar" and the existing validated intent is kept. If the mode is the same and the position shifted by less than 500 m (or the heading changed by less than ~20°), only the heading field is updated in-place on the existing validated `_last_intent`.

---

## Data Flow: One Physics Frame

```
/dev/null/flow.txt#L1-28
_physics_process(delta):
  1. navigator.set_state(position, velocity, heading, ang_vel, rudder, speed)
  
  2. [every 4 frames, staggered] _update_obstacles()
       → server_node.get_team_ships() + get_valid_targets()
       → navigator.register_obstacle / update_obstacle / remove_obstacle
  
  2b. [gated by 1 s cooldown] _check_intent_events()
       → track visible enemy count via get_valid_targets().size()
       → track friendly alive count (death detection)
       → track cover arrival (is_in_cover transition)
       → sets _force_intent_next_frame = true on change
       → rescans target if current target is null/hidden on vis change
  
  3. [every 12 frames staggered, OR immediately if forced] _update_nav_intent()
       → behavior.get_nav_intent(target, ship, server_node)  → NavIntent
       → _is_intent_similar(_last_raw_intent, new) — compares raw-to-raw
       → if similar: keep existing validated _last_intent, update heading only
       → if different: store as _last_raw_intent, then validate:
         → navigator.validate_destination_pose(ship_pos, intent.target)
         → _last_intent updated (possibly mode upgraded to POSE)
  
  4. _execute_nav_intent()
       → navigator.navigate_to_position / navigate_to_angle /
          navigate_to_pose / station_keep
       (C++ side: small destination shift → retarget_forward_simulation
        instead of full path+sim reset)
  
  5. rudder = navigator.get_rudder()
     throttle = navigator.get_throttle()
     throttle *= behavior.get_speed_multiplier()   # DD evasion only
  
  6. movement.set_movement_input([throttle, rudder])
```

---

## NavIntent — Behavior↔Controller Contract

Behaviors **must** implement:

```
/dev/null/contract.gd#L1-5
func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent
func get_speed_multiplier() -> float   # return 1.0 if not overriding
```

If a behavior does not yet implement `get_nav_intent`, the controller falls back to the legacy `get_desired_position` + `get_desired_heading` interface and wraps the result in a `NavIntent.position()` or `NavIntent.pose()`.

**`throttle_override` field** (default `-1` = let navigator decide):
When set to `0`–`4`, the bot controller applies it as a **minimum throttle floor** after reading the navigator's output. This prevents the navigator's `compute_throttle_for_approach` from decelerating too early when the behavior wants to maintain speed (e.g. CAs approaching island cover). The override is **ignored when `is_collision_imminent()` is true** — collision avoidance always takes priority. Example usage: `CABehavior` sets `throttle_override = 4` when >500 m from cover, `3` when >200 m, and `-1` (navigator-controlled) for the final approach.

**Intent validation flow in `_update_nav_intent`:**
- `POSITION` → always upgraded to `POSE` after `validate_destination_pose`
- `POSE` → position and/or heading adjusted if simulation finds collision; behavior heading preserved if within 60° of safe heading; `throttle_override` is preserved through validation
- `STATION_KEEP` → zone center validated and adjusted if inside land

---

## Navigation Modes

| Mode | Navigator method | Use case |
|------|-----------------|----------|
| `POSITION` | `navigate_to_position(target)` | Move to world position; navigator chooses arrival heading |
| `ANGLE` | `navigate_to_angle(heading)` | Rotate to heading in place (no destination) |
| `POSE` | `navigate_to_pose(target, heading)` | Arrive at position facing a specific direction (combat broadside, island approach) |
| `STATION_KEEP` | `station_keep(center, radius, heading)` | Hold circular zone at preferred heading; sub-states: APPROACH → SETTLE → HOLDING → RECOVER |

---

## NavState Machine

States are integers from the `NavState` C++ enum. Read via `navigator.get_nav_state()`.

| Value | Name | Meaning |
|-------|------|---------|
| 0 | `IDLE` | No active navigation command |
| 1 | `NAVIGATING` | Following A* path waypoints |
| 2 | `ARRIVING` | Decelerating near destination |
| 3 | `TURNING` | Angle-only navigation — acquiring heading |
| 4 | `STATION_APPROACH` | Heading toward station-keep zone center |
| 5 | `STATION_SETTLE` | Inside zone, slowing to hold speed |
| 6 | `STATION_HOLDING` | Actively holding position within zone |
| 7 | `STATION_RECOVER` | Drifted out of zone, returning |
| 8 | `AVOIDING` | Collision avoidance override active |
| 9 | `EMERGENCY` | Emergency reverse / evasion |

---

## Key Algorithms

### Signed Distance Field (SDF)
- Binary land mask built from rasterized collision shapes
- Jump flood algorithm converts mask to exact signed distances
- Positive values = open water (meters to nearest land)
- Negative values = inside land
- Bilinear interpolation for sub-cell accuracy

### Theta* Pathfinding
- Runs on the SDF grid with configurable clearance
- Any-angle paths via line-of-sight shortcuts
- Pre-computed region connectivity for O(1) unreachability rejection before pathfinding

### Arc Prediction (`predict_arc`)
- Simulates ship's turning physics (rudder lag, speed loss in turns, acceleration/deceleration) forward until `lookahead_distance` meters of ground distance are covered
- Lookahead scales with ship size: at least 3× ship length
- Two-tier collision check: **hard clearance** (beam/2 + safety — never violate) and **soft clearance** (turning radius — only triggers if arc settles inside it)

### Incremental Forward Simulation (`ForwardSimulation`)
- Builds a physics-validated path to destination incrementally, 2 ship-lengths per frame
- Stored as `SimulatedNavPoint` sequence — full ship state at each point, resumable at any index
- **Path reuse on small destination shifts:** When the new destination is within 500 m of the old one (or < 15% of remaining distance), the simulation is **retargeted** rather than discarded. `retarget_forward_simulation()` keeps all validated intermediate points and only updates the frontier's target endpoint. The incomplete tail is trimmed and re-simulated toward the new position.
- **Full invalidation** only when: mode changes, destination shifts beyond reuse thresholds, ship deviates from path by > 2× turning circle radius
- Partial invalidation via `invalidate_from(index)` — trims and resumes from that point without full replan
- Dynamic obstacle threats also trigger partial invalidation (one point before the collision)

### Safe Nav Point
- If candidate is inside land → push to nearest navigable cell
- If approach angle is near-perpendicular to coastline → slide tangentially along shore so arrival arc curves away from land

---

## Dynamic Obstacles & COLREGS Avoidance

**Registration (in `BotControllerV4._update_obstacles`):**
```
/dev/null/obstacles.gd#L1-4
navigator.register_obstacle(id, position_2d, velocity_2d, radius, ship_length)
navigator.update_obstacle(id, position_2d, velocity_2d)
navigator.remove_obstacle(id)
navigator.clear_obstacles()
```
`position` and `velocity` are `Vector2` (XZ plane). `id` should be stable per ship (e.g., `ship.get_instance_id()`). Only ships within `OBSTACLE_REGISTER_RANGE` (5000 m) are registered.

**COLREGS give-way logic:**
- Relative bearing determines if obstacle is on port or starboard bow
- Larger ships (by `ship_length`) have right-of-way
- Give-way vessel steers starboard; stand-on vessel holds course unless TTC < 3 s
- Avoidance maneuvers commit for at least 4 seconds (`COMMIT_DURATION`) to prevent oscillation

---

## Behavior Classes

All behaviors extend `BotBehavior` and live in `src/ship/bot_behavior/`.

### `BotBehavior` (base) — `behavior.gd`
Shared systems: evasion state machine, island cover cache, torpedo fire control, friendly fire checks. Subclasses override weight/param methods.

### `BBBehavior` — `bb_behav.gd`
- Ammo: AP
- Evasion: slow 20 s period, 25–35° weave, no speed variation
- No island cover
- Spread: 3000 m between allied BBs
- Arc direction reversal every 30 s for unpredictability

### `CABehavior` — `ca_behav.gd`
- Ammo: HE
- Evasion: 5 s period, 30–45° weave
- **Island cover (visibility-tested multi-candidate system):**
  - Selects the best island based on tactical scoring (range, alignment, size)
  - Uses C++ `find_cover_candidates()` SDF-cell-based search for ranked concealment positions near the island shore
  - **Asynchronously validates shootability** via `can_shoot_target_from_position()` ballistic sim (2 candidates per physics frame) — iterates the ranked list to find the best position the ship can arc shells over the island from
  - Selects the candidate that hides the ship from the most threats while staying in gun range; prefers full concealment, moderate island distance, and proximity to the ship
  - **Navigation modes by situation:**
    - **In cover and undetected**: holds position with a tight `STATION_KEEP` radius
    - **Approaching cover (not yet arrived)**: uses `POSE` mode to pilot directly to cover position at speed; `throttle_override` keeps throttle at 4 (>500 m), 3 (>200 m), or navigator-controlled (≤200 m) to prevent premature deceleration
    - **Spotted while in cover**: moves closer to the island (`POSE` toward `island_center − to_island_dir × min_safe_dist`) to tuck in tighter and break LOS; if already at minimum distance, **abandons cover entirely** and falls through to tactical kiting
    - **Spotted while approaching cover**: recompute fires every 0.25 s to update the cover position; `POSE` with throttle scaling drives the ship to the new position
    - **Visible to enemy but no known enemies** (`danger_center == 0`): abandons startup cover immediately and sails forward (`POSE` 3 000 m ahead) to break detection and find the threat, rather than sitting exposed
  - Recomputes cover every 4 s normally, every 0.25 s when spotted
  - **Async eval preservation**: when recomputing for the same island (e.g. frequent spotted recomputes), the in-progress ballistic evaluation is preserved rather than restarted, preventing the candidate search from being perpetually reset
- Cover zone state tracked in `_cover_island_id`, `_cover_zone_valid`, `_cover_zone_center`, `_cover_zone_radius`, `_cover_zone_heading`; async evaluation state in `_cover_eval_*` variables
- Abandons cover if target moves too far (>80% gun range) or too close (<35% gun range)
- Startup island selection uses SDF walk to find near-side position; returns `POSE` to sail there at speed, switching to `STATION_KEEP` only once arrived

### `DDBehavior` — `dd_behav.gd`
- Ammo: HE (+ torpedoes via base class)
- Evasion: fast 2.5 s period, 10–25°, **speed variation** (`get_speed_multiplier()` returns 0.6–1.0 sine wave)
- No island cover
- Spread: 1500 m
- Aggressive approach multiplier (0.8)

---

## Integration Checklist

When spawning a bot ship:

- [ ] `NavigationMapManager.build_map()` has been called (check `is_map_ready()`)
- [ ] Ship scene has `BotControllerV4` as a child node of the `Ship` root
- [ ] `BotControllerV4._ship` set via `assign_nav_agent(ship)`
- [ ] `BotControllerV4.behavior` assigned to the correct `BotBehavior` subclass instance **before** `_ready` runs (or set and `add_child` manually)
- [ ] `ShipMovementV4` is a sibling node named `MovementController`
- [ ] `ShipMovementV4` exposes: `turning_circle_radius`, `rudder_response_time`, `acceleration_time`, `deceleration_time`, `max_speed`, `reverse_speed_ratio`, `ship_length`, `ship_beam`, `turn_speed_loss`, `rudder_input`
- [ ] `NavigationMapManager` is registered as an autoload in `project.godot`
- [ ] `bot_id` is set to a unique integer per bot (used for frame stagger)

When adding a new behavior:

- [ ] Extend `BotBehavior`
- [ ] Implement `get_nav_intent(target, ship, server) -> NavIntent`
- [ ] Implement `get_speed_multiplier() -> float` (return `1.0` if unused)
- [ ] Override param methods as needed: `get_evasion_params()`, `get_positioning_params()`, `get_threat_class_weight()`, `get_target_weights()`, `get_hunting_params()`
- [ ] If using island cover, call `NavigationMapManager.compute_cover_zone()` and return `NavIntent.station()`

---

## Design Constraints & Gotchas

| Constraint | Detail |
|-----------|--------|
| **Map must be built before bots spawn** | `BotControllerV4._ready` calls `NavigationMapManager.get_map()`. If null, navigator works without terrain (no pathfinding or avoidance). A deferred re-check in `_deferred_init` (0.2 s) catches late builds. |
| **`set_state` must precede navigation calls** | The navigator reads live ship state from the last `set_state` call. Call it every frame before `navigate_to_*`. |
| **`Vector2` XZ convention** | All C++ internal calculations use `Vector2(x, z)`. `Vector3.y` is always 0 in output path arrays. |
| **Heading convention** | `0` radians = +Z axis (forward in Godot), `π/2` = +X (starboard). Matches Godot's `atan2` convention for XZ plane. |
| **Throttle levels** | `-1`=reverse, `0`=stop, `1–4`=ahead dead slow→full. Matches `ShipMovementV4` `throttle_settings` array `[-0.5, 0.0, 0.25, 0.5, 0.75, 1.0]`. |
| **Clearance values** | Hard clearance = `beam/2 + safety` (ship cannot be here). Soft clearance = `turning_circle_radius` (ship prefers not to be here). Navigator enforces hard clearance strictly; soft clearance only triggers if the arc *ends* inside it. |
| **`validate_destination_pose` is expensive** | Runs a full physics simulation at multiple headings. Only call from `_update_nav_intent` (every 12 frames or on event), never every frame. Skipped entirely when `_is_intent_similar` determines the raw behavior intent hasn't meaningfully changed. |
| **Island cover requires NavigationMap** | `CABehavior` calls `NavigationMapManager.compute_cover_zone()`. If map is not ready, cover zone `valid` will be false and behavior falls back to open-water positioning. |
| **Forward simulation retargeting** | Small destination shifts (< 500 m or < 15% of remaining distance) trigger `retarget_forward_simulation()` instead of a full reset. All validated intermediate simulation points are preserved; only the tail is re-simulated. Large shifts or mode changes still cause a full `init_forward_simulation()`. |
| **Forward simulation full reset** | Only occurs when: switching nav modes, destination shifts beyond reuse thresholds, or the ship deviates > 2× turning circle from the simulated path. |
| **Event-driven intent updates** | Visible enemy count change, friendly death, and cover arrival bypass the 12-frame stagger and trigger an immediate behavior query. Events are gated by a 1-second cooldown to prevent rapid re-firing from concealment-edge oscillation. |
| **Intent similarity filtering** | `_is_intent_similar()` compares against `_last_raw_intent` (pre-validation), not `_last_intent` (post-validation). This prevents the oscillation cycle where validation adjusts position A to A′, then the next query returns A again (raw A vs raw A = similar, so A′ is kept). Position must shift > 500 m or mode must change to be considered "different". |
| **COLREGS commit timer** | Give-way maneuvers hold for 4 s minimum. Do not issue rapid conflicting `navigate_to_*` commands during avoidance — they will be processed but the avoidance rudder bias will persist until the timer expires. |