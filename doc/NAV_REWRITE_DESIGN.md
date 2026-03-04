# Navigation System Rewrite — Design Document

## Problem Statement

The current `NavigationMap` + `ShipNavigator` C++ GDExtension classes are corrupt and do not work as intended. Key issues:

1. **Undeclared variables**: `using_simulated_path`, `simulated_waypoints`, `simulated_wp_index`, `forward_sim` are used throughout `ship_navigator.cpp` but never declared in `ship_navigator.h`.
2. **Undefined types**: `KinematicPathResult` is referenced in the header but never defined anywhere.
3. **Two conflicting path systems**: A legacy A* path (`current_path`) and an incremental forward simulation (`ForwardSimulation`) coexist with unclear ownership. The header comments claim the kinematic path is the "SINGLE source of truth" but the implementation uses both interchangeably.
4. **No turning radius in pathfinding**: The A* runs on the raw SDF grid with a scalar clearance value. A 650m-turning-circle battleship gets the same path as a 200m-turning-circle destroyer — the path doesn't account for whether the ship can physically make the turns.
5. **Poor reverse support**: Reverse is a bolt-on check (`angle_to_target > 117° && close && slow`) rather than an integrated part of the pathfinding. The navigator never plans a path that includes a reverse segment.
6. **Rudder response time ignored in planning**: The `predict_arc` function models rudder lag, but pathfinding and waypoint generation don't account for it. The ship commits to turns it can't physically execute in time.
7. **Excessive forward simulation**: The multi-frame incremental `ForwardSimulation` simulates the ship's full physics to the destination, producing hundreds of `SimulatedNavPoint`s. This is expensive and fragile — any obstacle invalidation triggers expensive re-simulation.

## Design Goals

1. **Turning-radius-aware pathfinding** — paths that the ship can actually follow without grounding.
2. **Reverse as a first-class maneuver** — when the destination is behind and close, plan a reverse approach rather than a wide loop.
3. **Rudder response time in steering** — lead the rudder command so the ship arrives at the correct heading at the right time, not after overshooting.
4. **No high-fidelity simulation in the pathfinder** — use analytical/geometric approximations for turning, not frame-by-frame physics integration.
5. **Clean, compilable code** — no undeclared variables, no undefined types, no conflicting state.
6. **Preserve external API surface** — `BotControllerV4`, `NavigationMapManager`, behaviors, and debug systems all call into these classes. Keep method signatures compatible where possible.

## Architecture Overview

### What stays the same

- **`NavigationMap`**: SDF grid construction (`build_from_collision_shapes`, `build_from_raycast_scan`), SDF queries (`get_distance`, `get_gradient`, `is_navigable`), raycasting, island extraction, cover zone computation, `find_cover_candidates`. All of this works correctly.
- **`NavigationMapManager`** (GDScript autoload): Unchanged. Builds and holds the shared `NavigationMap`.
- **`NavIntent`** (GDScript): Unchanged. Behaviors produce intents, controller consumes them.
- **`BotControllerV4`** (GDScript): Moderate changes to use the cleaner navigator API. Same structure.
- **`nav_types.h`**: Cleaned up. Remove `ForwardSimulation`, `SimulatedNavPoint`, `KinematicPathResult`. Add new types.

### What gets rewritten

| Component | Current | New |
|---|---|---|
| **Pathfinding** (`NavigationMap::find_path_internal`) | Plain A* on SDF grid, scalar clearance | Weighted A* with turning-penalty cost function |
| **`ShipNavigator`** | ~3000 lines, two conflicting path systems, undeclared state | ~1500 lines, single path + reactive steering, clean state |
| **Forward simulation** | Multi-frame incremental `ForwardSimulation` producing hundreds of points | Removed entirely. Replaced by analytical turn feasibility checks at waypoints |

---

## Detailed Design

### 1. Turning-Aware Pathfinding (`NavigationMap`)

#### Current approach
```
A* on SDF grid, 8-connected.
Cost = Euclidean distance between cells.
Constraint = SDF(cell) >= clearance (scalar, beam/2 + safety).
Post-process = greedy LOS simplification.
```

This produces shortest-distance paths that hug coastlines. A destroyer can follow them; a battleship with a 650m turning circle cannot make the sharp turns around island tips.

#### New approach: Weighted A* with curvature penalty

Keep the same grid, same 8-connected A* structure. Change the cost function:

```
base_cost = euclidean_distance(current, neighbor)

// Proximity penalty: exponential cost increase as SDF approaches the turning radius
// This pushes paths away from land proportional to the ship's turn circle
sdf_value = SDF(neighbor)
proximity_ratio = clamp(turning_radius / max(sdf_value, 1.0), 0.0, 5.0)
proximity_penalty = base_cost * proximity_ratio * 0.5

// Direction-change penalty: penalize sharp turns relative to turning radius
// parent → current → neighbor forms an angle; sharper angles cost more
if (has_parent):
    turn_angle = angle between (parent→current) and (current→neighbor)
    // How many cell-lengths the turning circle needs to execute this angle
    arc_length = turning_radius * abs(turn_angle)
    // Penalty scales with how much arc is needed vs how much space is available
    turn_penalty = (arc_length / cell_size) * 0.3

total_cost = base_cost + proximity_penalty + turn_penalty
```

**Why this works without simulation**: The proximity penalty ensures the path stays `~turning_radius` away from land wherever possible — giving the ship room to turn. The direction-change penalty makes the path prefer gentle curves over sharp corners. Together, they produce paths that a ship with a given turning circle can follow without grounding.

**Why this is better than simulating**: Simulation is O(path_length × physics_steps). The weighted A* is the same complexity as plain A* — the cost function is O(1) per neighbor evaluation. It runs once, produces a path, done.

#### Post-processing: Bézier smoothing instead of LOS simplification

After A* finds the weighted path, instead of greedy LOS simplification (which re-introduces sharp corners), smooth it:

1. **LOS simplification** (keep this — it removes redundant collinear waypoints)
2. **Catmull-Rom interpolation** at waypoints where the turn angle exceeds `π / (turning_radius / cell_size)`. Insert 2-3 intermediate points along the curve. This gives the ship a smooth trajectory to follow rather than point-to-point segments with sharp bends.
3. **SDF validation pass** on the smoothed points — if any interpolated point violates clearance, fall back to the un-smoothed segment.

#### New method signature

```cpp
PathResult find_path_internal(Vector2 from, Vector2 to, float clearance,
                              float turning_radius = 0.0f) const;
```

When `turning_radius` is 0, behaves identically to the current implementation (backward compatible). When nonzero, applies the curvature-aware cost function.

### 2. ShipNavigator Rewrite

#### State cleanup

Remove all undeclared/broken state. The new navigator has:

```cpp
// --- Path ---
PathResult current_path;        // From NavigationMap::find_path_internal
int current_wp_index;           // Index into current_path.waypoints
bool path_valid;
float path_recalc_cooldown;     // Seconds remaining before allowing recalc

// --- Steering output ---
float out_rudder;               // [-1, 1]
int out_throttle;               // [-1, 4]
bool out_collision_imminent;
float out_time_to_collision;

// --- Reactive avoidance ---
std::vector<ArcPoint> predicted_arc;  // Short-range (~3-5 ship lengths) arc prediction
AvoidanceState avoidance;

// --- No forward simulation, no simulated waypoints, no kinematic path ---
```

That's it. One path, one waypoint index, one steering output. No dual-path ambiguity.

#### Navigation modes (unchanged API)

- `navigate_to_position(Vector3 target)` — pathfind + follow
- `navigate_to_angle(float heading)` — rudder-only heading change
- `navigate_to_pose(Vector3 target, float heading)` — pathfind + arrive at heading
- `station_keep(Vector3 center, float radius, float preferred_heading)` — hold zone

#### Steering pipeline (per-frame, called from `set_state`)

```
1. PLAN:  Determine desired waypoint from path
2. STEER: Compute desired rudder toward waypoint (with rudder lead compensation)
3. CHECK: Predict short arc, check for terrain/obstacle collisions
4. REACT: If collision imminent, override rudder (select safe rudder from candidates)
5. SPEED: Compute throttle (approach deceleration, reverse if needed)
6. OUTPUT: Write out_rudder, out_throttle, out_collision_imminent
```

No simulation. No multi-frame incremental path building. The path from `NavigationMap` is already turning-aware. The per-frame steering just follows it with reactive safety checks.

#### Rudder lead compensation

The current `compute_rudder_to_heading` has a basic lead factor. The new version properly models rudder lag:

```
// Time for rudder to reach commanded position from current position
rudder_travel_time = |commanded_rudder - current_rudder| * rudder_response_time

// Predicted heading change during rudder travel (ship continues current turn)
heading_drift = current_angular_velocity * rudder_travel_time

// Effective target = desired heading minus the drift that will happen
// while the rudder is still traveling
effective_target = desired_heading - heading_drift * 0.5

// Now compute rudder toward effective_target
angle_error = normalize(effective_target - current_heading)
rudder = clamp(angle_error / (π/4), -1, 1)  // proportional with saturation
```

This means the ship starts turning the rudder *early enough* that it arrives at full deflection when needed, rather than commanding full rudder and waiting for it to catch up (which causes overshoot).

#### Reverse support

Instead of the current bolt-on check, reverse is integrated into the steering pipeline:

```
bearing_to_waypoint = angle from ship heading to waypoint
distance = distance to waypoint

USE_REVERSE when ALL of:
  - |bearing_to_waypoint| > 120°  (waypoint is behind us)
  - distance < turning_radius * 2  (close enough that reversing is faster than looping)
  - |current_speed| < max_speed * 0.3  (not moving fast forward)
  - No path waypoints ahead that require forward motion

When reversing:
  - throttle = -1
  - rudder is NEGATED (reversing inverts rudder effect)
  - Waypoint reach radius is tighter (ship is slower, more precise)
```

The key improvement: the **pathfinder** can also produce paths where the first segment is flagged as "reverse" — when the ship needs to back away from a coastline before it can turn toward the destination. This is done by checking: if the ship's current position is within `turning_radius` of land AND the destination requires turning toward that land, insert a reverse waypoint first.

#### Waypoint following improvements

Current waypoint reach detection uses distance + forward-dot-product. New version:

```
// Waypoint is "reached" when the ship's closest point of approach has passed
// (i.e., we're now moving away from it)
to_wp = waypoint - ship_position
forward = heading_vector
cross_track = dot(to_wp, perpendicular(forward))  // lateral offset
along_track = dot(to_wp, forward)                  // how far ahead

reached = along_track < 0  // we've passed it
       OR distance < reach_radius

// Dynamic reach radius based on speed and remaining path curvature
reach_radius = max(ship_length, min(turning_radius * 0.3, speed * 2.0))
```

#### Short-range arc prediction (reactive safety)

Keep `predict_arc()` but only use it for short-range reactive checks (~3-5 ship lengths). This catches:
- Dynamic obstacles (other ships)
- Land that the path didn't account for (rare with turning-aware pathfinding, but possible if the ship deviates)
- Emergency situations

The arc prediction remains the same physics model (rudder response, speed, turning circle). Only the *use* changes — it's purely reactive, not planning.

### 3. BotControllerV4 Changes

#### Simplified `_physics_process`

```gdscript
func _physics_process(delta):
    # 1. Update navigator state (ship position, velocity, heading, rudder, speed)
    navigator.set_state(...)

    # 2. Update obstacles (every N frames)
    if should_update_obstacles:
        _update_obstacles()

    # 3. Get intent from behavior (every M frames, or on event)
    if should_query_behavior:
        _update_nav_intent()

    # 4. Execute intent (sends command to navigator)
    _execute_nav_intent()

    # 5. Read steering output
    var rudder = navigator.get_rudder()
    var throttle = navigator.get_throttle()

    # 6. Apply behavior modifiers (speed multiplier, throttle override)
    # 7. Send to movement controller
    movement.set_movement_input([throttle, rudder])

    # 8. Behavior tick (target scanning, firing)
    _tick_behavior(delta)
```

This is essentially the same as current — the changes are all internal to the navigator.

#### Removed: `validate_destination_pose` complexity

Currently `_update_nav_intent` runs the navigator's `validate_destination_pose` which does multi-heading physics simulation. With turning-aware pathfinding, this is unnecessary — the path itself avoids putting the ship in positions it can't escape from.

Replace with a simpler check:

```gdscript
# Just ensure the destination is in navigable water with clearance
if not NavigationMapManager.is_navigable(dest, clearance):
    dest = NavigationMapManager.safe_nav_point(ship_pos, dest, clearance, turning_radius)
```

The `safe_nav_point` function already exists and works correctly.

#### Debug API preserved

All existing debug methods remain with the same signatures:
- `get_debug_heading_vector()` → unchanged
- `get_debug_nav_path()` → returns `navigator.get_current_path()` (now the single path, no dual-path confusion)
- `get_debug_simulated_path()` → returns empty (no forward simulation) or the arc prediction points
- `get_clearance_radius()` / `get_soft_clearance_radius()` → unchanged

### 4. nav_types.h Cleanup

#### Remove
- `SimulatedNavPoint` — no more forward simulation
- `ForwardSimulation` — no more forward simulation
- `KinematicPathResult` — never defined, never actually used

#### Keep (unchanged)
- `ArcPoint` — used by short-range arc prediction
- `PathResult` — A* path output
- `IslandData`, `CoverZone`, `RayResult` — map features
- `ShipParams`, `ShipState`, `SteeringResult` — ship config/state
- `DynamicObstacle`, `ObstacleCollisionInfo`, `AvoidanceState` — obstacle avoidance
- `NavState`, `NavMode` — state machine enums
- All math utilities

#### Add
- `WaypointFlags` — per-waypoint metadata (e.g., `REVERSE_SEGMENT` flag)

---

## Performance Analysis

| Operation | Current | New |
|---|---|---|
| **Pathfinding** | A* + multi-frame forward sim (hundreds of physics steps) | Weighted A* (same grid, slightly more expensive cost function, ~10% slower per A* expansion) + Catmull-Rom smoothing (O(waypoint_count)) |
| **Per-frame steering** | `predict_arc` at full lookahead (~10 ship lengths) + obstacle check + forward sim advance | `predict_arc` at short range (~3 ship lengths) + obstacle check |
| **Path recalculation** | Full A* + full forward sim reset | Full weighted A* only |
| **Memory** | `ForwardSimulation` vector (hundreds of `SimulatedNavPoint`s) + `simulated_waypoints` vector + `current_path` | `current_path` only |

Net: **faster per frame** (no forward sim advance), **similar path computation cost**, **less memory**.

## Migration / Rollback Plan

1. The current `ship_navigator.cpp` / `.h` and `navigation_map.cpp` / `.h` will be replaced.
2. `nav_types.h` will be cleaned.
3. `bot_controller_v4.gd` will be updated.
4. `navigation_map_manager.gd` unchanged.
5. All behavior scripts (`behavior.gd`, `ca_behav.gd`, `dd_behav.gd`, `bb_behav.gd`) unchanged — they produce `NavIntent`s, the interface is the same.
6. `debug.gd` unchanged — all debug accessors are preserved.

To roll back: restore the old `.cpp`, `.h`, and `.gd` files from git.

## File Changes Summary

| File | Action |
|---|---|
| `gdextension/ships_core/src/nav_types.h` | Clean up: remove broken types, add `WaypointFlags` |
| `gdextension/ships_core/src/navigation_map.h` | Add `turning_radius` parameter to `find_path` signatures |
| `gdextension/ships_core/src/navigation_map.cpp` | Modify `find_path_internal` with weighted cost + smoothing |
| `gdextension/ships_core/src/ship_navigator.h` | Full rewrite: clean state, remove undeclared variables |
| `gdextension/ships_core/src/ship_navigator.cpp` | Full rewrite: single-path steering pipeline |
| `src/ship/bot_controller_v4.gd` | Simplify intent validation, remove `validate_destination_pose` usage |
| `src/ship/nav_intent.gd` | No changes |
| `src/autoload/navigation_map_manager.gd` | No changes |
| `src/autoload/debug.gd` | No changes |
| `src/ship/bot_behavior/*.gd` | No changes |