# Navigation System V5 — Design Document

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture Changes](#2-architecture-changes)
3. [Phase 1: Foundation Types & Unified API](#3-phase-1-foundation-types--unified-api)
4. [Phase 2: Heading-Aware Path Planning](#4-phase-2-heading-aware-path-planning)
5. [Phase 3: Unified State Machine](#5-phase-3-unified-state-machine)
6. [Phase 4: Remove apply_gradient_bias](#6-phase-4-remove-apply_gradient_bias)
7. [Phase 5: Event-Driven Recalculation](#7-phase-5-event-driven-recalculation)
8. [Phase 6: GDScript Layer Updates](#8-phase-6-gdscript-layer-updates)
9. [Implementation Order](#9-implementation-order)
10. [File Change Manifest](#10-file-change-manifest)
11. [Testing Plan](#11-testing-plan)

---

## 1. Overview

### Problem Statement

The current navigation system (V4) has five separate navigation modes (NONE, POSITION, ANGLE, POSE, STATION_KEEP) with four separate update methods that duplicate logic, handle reverse inconsistently, and produce paths that ignore the ship's current heading. The A* pathfinder has no knowledge of which direction the ship is facing when it starts — it can produce paths that begin with a 180° turn the ship cannot physically execute. Reversing is a last-resort hack rather than a first-class maneuver. Ships that run aground have no structured recovery mechanism. Path recalculation is cooldown-gated rather than event-driven.

### Solution Summary

1. **Unified navigation**: One command (`navigate_to`), one state machine, one update loop.
2. **Heading-aware pathfinding**: The A* planner seeds with the ship's actual heading (forward) and optionally its reverse heading, evaluating both and choosing the shorter path. The existing curvature penalty naturally discourages paths that start with impossible turns.
3. **Reverse as a first-class path segment**: Waypoints carry a `WP_REVERSE` flag. The steering pipeline follows reverse waypoints the same way it follows forward ones — no special state needed.
4. **Stuck recovery in the planner**: When the ship is stuck (both forward arcs blocked), the planner generates recovery waypoints (short reverse + forward turn) as part of the path. The steering pipeline just follows them.
5. **Event-driven recalculation**: Dirty flags replace cooldown timers. The GDScript layer signals intent changes based on tactical events rather than frame-count stagger.

### What Does NOT Change

- `NavigationMap` — SDF grid, A* internals, island extraction, cover zones, raycast, LOS: **untouched** (the A* itself is only called differently, its algorithm is unchanged).
- `select_safe_rudder` — collision avoidance pipeline: **untouched**.
- `predict_arc_internal` / `predict_arc_to_heading` — arc simulation: **untouched**.
- `compute_rudder_to_position` / `compute_rudder_to_heading` — steering math: **untouched**.
- Dynamic obstacle tracking (register/update/remove): **untouched**.
- Behavior positioning logic (BB arc movement, DD torpedo runs, CA island finding): **untouched** (only the NavIntent return type changes).

---

## 2. Architecture Changes

### Current Architecture (V4)

```
BotBehavior.get_nav_intent()
    → NavIntent { mode: POSITION|ANGLE|POSE|STATION_KEEP, ... }
        → BotControllerV4._execute_nav_intent()
            → ShipNavigator.navigate_to_position() / navigate_to_angle() / navigate_to_pose() / station_keep()
                → set nav_mode, call maybe_recalc_path()
                    → set_state() dispatches to update_navigate_to_position() / _angle() / _pose() / station_keep()
                        → 4 separate steering pipelines with duplicated logic
```

### New Architecture (V5)

```
BotBehavior.get_nav_intent()
    → NavIntent { position, heading, hold_radius, ... }
        → BotControllerV4._execute_nav_intent()
            → ShipNavigator.navigate_to(position, heading, hold_radius)
                → set target, mark dirty
                    → set_state(delta) calls update(delta)
                        → state machine: PLANNING → NAVIGATING → ARRIVING → SETTLING → HOLDING
                            → single steering pipeline reads waypoint flags for forward/reverse
```

### Key Architectural Decisions

**Decision 1: Path planner owns all intelligence about how to reach the destination.**
The planner produces a complete waypoint sequence with direction flags. The steering pipeline is a dumb follower. Recovery from stuck states is just "the planner generated recovery waypoints."

**Decision 2: The A* algorithm itself is not modified.**
Instead, `find_path_internal` gets a new parameter: `start_heading`. The caller (ShipNavigator) computes a "virtual start point" ahead of the ship and passes it as the `from` parameter, with the real ship position used to seed the parent direction. This lets the existing curvature penalty naturally penalize paths that start with sharp turns away from the ship's heading. See Phase 2 for details.

**Decision 3: Two competing A* searches (forward start vs reverse start) are evaluated, not run in parallel.**
The forward path runs first. Then the reverse path runs with an early termination bound: if at any point the reverse path's g_cost exceeds the forward path's total cost, the reverse search aborts. The shorter result wins.

**Decision 4: State machine states track execution phase, not intent type.**
There is no STATION_KEEP mode. Station-keeping is just HOLDING with `hold_radius > 0`. There is no REVERSING state. Reversing is just NAVIGATING along a waypoint with `WP_REVERSE` flag.

---

## 3. Phase 1: Foundation Types & Unified API

### 3.1 nav_types.h Changes

#### Remove NavMode

Delete the `NavMode` enum entirely.

#### New NavState

Replace the current NavState with:

```cpp
enum class NavState {
    PLANNING    = 0,  // Computing path (transitions out within same frame)
    NAVIGATING  = 1,  // Following waypoints forward or reverse (per waypoint flag)
    ARRIVING    = 2,  // Within approach radius, blending position + heading
    SETTLING    = 3,  // At position, correcting heading via short maneuvers
    HOLDING     = 4,  // Position + heading achieved, micro-corrections only
    AVOIDING    = 5,  // Collision avoidance temporarily overriding steering
    EMERGENCY   = 6,  // Last-resort gradient escape
};
```

Rationale for each removed state:
- `IDLE` → replaced by `HOLDING` (a ship at rest is station-keeping at its current position)
- `TURNING` → subsumed by `NAVIGATING` (angle-only nav is just navigating to current position with a target heading)
- `STATION_APPROACH` → `NAVIGATING` (approaching a hold zone is just navigating to a point)
- `STATION_SETTLE` → `SETTLING` (same behavior, unified name)
- `STATION_HOLDING` → `HOLDING`
- `STATION_RECOVER` → `PLANNING` → `NAVIGATING` (drift recovery triggers a replan)
- `REVERSING` → not a state; it's `NAVIGATING` along a `WP_REVERSE` waypoint
- `UNSTICKING` → not a state; it's `NAVIGATING` along recovery waypoints the planner generated

#### New NavTarget

Replace scattered target fields with a single struct:

```cpp
struct NavTarget {
    Vector2 position;       // Destination XZ
    float heading;          // Desired heading on arrival (radians)
    float hold_radius;      // 0 = arrive and stop, >0 = station-keep within this radius

    NavTarget()
        : position(Vector2()), heading(0.0f), hold_radius(0.0f) {}
};
```

#### Updated WaypointFlags

```cpp
enum WaypointFlags : uint8_t {
    WP_NONE      = 0,
    WP_REVERSE   = 1 << 0,  // Ship should reverse through this segment
    WP_SMOOTHED  = 1 << 1,  // Inserted by Catmull-Rom smoothing
    WP_DEPARTURE = 1 << 2,  // Departure/recovery waypoint (prepended by planner)
};
```

### 3.2 ship_navigator.h Changes

#### Remove old navigation command methods

Delete declarations for:
- `navigate_to_position(Vector3 target)`
- `navigate_to_angle(float target_heading)`
- `navigate_to_pose(Vector3 target, float target_heading)`
- `station_keep(Vector3 center, float radius, float preferred_heading)`

#### Add new unified command

```cpp
// The single navigation command.
// target:      world XZ position to reach
// heading:     desired heading on arrival (radians, 0 = +Z)
// hold_radius: 0 = arrive and stop, >0 = station-keep within radius
void navigate_to(Vector3 target, float heading, float hold_radius = 0.0f);
```

Keep `stop()` — it becomes `navigate_to(current_position, current_heading, 0)` + transition to HOLDING.

#### Replace member variables

Remove:
- `NavMode nav_mode`
- `Vector2 target_position`
- `float target_heading`
- `Vector3 station_center`
- `float station_radius`
- `float station_preferred_heading`
- `float station_settle_timer`
- `float station_hold_timer`

Add:
- `NavTarget target`
- `float settle_timer`
- `float hold_timer`
- `float stuck_timer` (time at near-zero speed while NAVIGATING)
- `int replan_frame_cooldown` (frame counter, not float timer)

#### Update set_state signature

```cpp
// Now takes delta explicitly — no more hardcoded 1/60
void set_state(Vector3 position, Vector3 velocity, float heading,
               float angular_velocity_y, float current_rudder,
               float current_speed, float delta);
```

#### Remove apply_gradient_bias

Delete declaration.

#### Remove old update methods

Delete declarations for:
- `update_navigate_to_position()`
- `update_navigate_to_angle()`
- `update_navigate_to_pose()`
- `update_station_keep(float delta)`

#### Add new update methods

```cpp
void update(float delta);
void update_planning();
void update_navigating();
void update_arriving(float delta);
void update_settling(float delta);
void update_holding(float delta);
void update_emergency();

// Path computation (replaces maybe_recalc_path)
void compute_path();

// Heading-correction waypoint generation for SETTLING state
void plan_heading_correction();

// Check if the path needs recomputation (called each frame from update_navigating)
bool check_replan_needed();

// Determine if the current waypoint should be followed in reverse
bool current_waypoint_is_reverse() const;
```

### 3.3 Bind Methods Update

```cpp
// Old bindings to remove:
// ClassDB::bind_method("navigate_to_position", ...)
// ClassDB::bind_method("navigate_to_angle", ...)
// ClassDB::bind_method("navigate_to_pose", ...)
// ClassDB::bind_method("station_keep", ...)

// New binding:
ClassDB::bind_method(D_METHOD("navigate_to", "target", "heading", "hold_radius"),
                     &ShipNavigator::navigate_to, DEFVAL(0.0f));
```

### 3.4 Constants

```cpp
// Existing constants retained:
static constexpr float PATH_REUSE_ABSOLUTE_THRESHOLD = 500.0f;
static constexpr float PATH_REUSE_RELATIVE_FRACTION = 0.15f;

// Renamed/new constants:
static constexpr int   REPLAN_FRAME_COOLDOWN = 9;          // ~0.15s at 60fps safety floor
static constexpr float HEADING_TOLERANCE = 0.2618f;        // ~15 degrees (was STATION_HEADING_TOLERANCE)
static constexpr float SPEED_THRESHOLD = 2.0f;             // m/s (was STATION_SPEED_THRESHOLD)
static constexpr float STUCK_TIME_THRESHOLD = 2.0f;        // seconds at near-zero speed before recovery
static constexpr float REVERSE_DISTANCE_CAP_FACTOR = 2.5f; // max reverse = turning_radius * this
```

---

## 4. Phase 2: Heading-Aware Path Planning

This is the most significant algorithmic change. The goal: make the A* path planner aware of the ship's current heading so it produces paths the ship can actually follow from its current orientation.

### 4.1 The Problem

Currently, `find_path_internal(from, to, clearance, turning_radius)` starts the A* search at the grid cell containing `from` (the ship's position). The start cell's parent is itself (`parent[start_idx] = start_idx`), so when expanding neighbors from the start cell, `has_parent_dir = false` — the curvature penalty is zero. This means the first step of the path can go in any direction, even directly behind the ship.

The result: A* might produce a path whose first waypoint is 170° behind the ship. The ship then has to do an expensive U-turn that the pathfinder didn't account for.

### 4.2 The Solution: Virtual Departure Point

Instead of starting A* at the ship's position, we start it at a **virtual departure point** — a grid cell a short distance ahead of (or behind) the ship along its heading. The ship's actual position is set as the parent of this departure cell. This means:

1. The first expansion from the departure cell **does** have a parent direction (the direction from ship → departure point = the ship's heading).
2. The curvature penalty immediately kicks in for the first step, penalizing paths that deviate sharply from the ship's heading.
3. The A* naturally finds paths that continue roughly in the ship's current direction, curving gently toward the destination.

For reverse paths, the departure point is placed behind the ship (along the reverse heading), and the resulting waypoints are flagged `WP_REVERSE` until the path naturally transitions to forward.

### 4.3 New find_path_internal Signature

```cpp
// navigation_map.h — new overload
PathResult find_path_internal(
    Vector2 from,              // Ship's actual position (used for path reconstruction)
    Vector2 to,                // Destination
    float clearance,           // SDF clearance required
    float turning_radius,      // For curvature penalty
    float start_heading        // Ship's current heading (radians, 0 = +Z)
                               // NAN = legacy behavior (no heading awareness)
) const;
```

The old 4-parameter version remains as a backward-compatible overload that passes `NAN` for `start_heading`.

### 4.4 Implementation Detail: Virtual Departure Cell

When `start_heading` is not NAN:

```
Step 1: Compute departure point
    departure_dist = max(cell_size * 2, ship_length / cell_size)  // ~2-4 cells ahead
    departure = from + (sin(heading), cos(heading)) * departure_dist

Step 2: Convert to grid
    dep_gx, dep_gz = world_to_grid(departure)
    dep_ix = round(dep_gx), dep_iz = round(dep_gz)

Step 3: Validate departure cell is navigable
    If not navigable, shorten departure_dist in steps until it is, or fall back to from

Step 4: Seed A*
    // The ship's actual position cell becomes a "virtual parent" for the departure cell
    from_ix, from_iz = world_to_grid(from)
    from_idx = cell_idx(from_ix, from_iz)

    // Departure cell is the real start of A*
    start_idx = cell_idx(dep_ix, dep_iz)
    g_cost[start_idx] = 0.0
    parent[start_idx] = from_idx   // <-- KEY: parent points back to ship position
    open.push({heuristic(dep_ix, dep_iz, ex, ez), start_idx})

    // Mark the ship position cell as closed so A* doesn't pathfind backward through it
    closed[from_idx] = true

Step 5: Run A* as normal
    The first expansion from start_idx will compute parent direction as:
        d1 = (dep_ix - from_ix, dep_iz - from_iz)  // = ship's heading direction
    And the curvature penalty will penalize any neighbor that deviates sharply from this.

Step 6: Reconstruct path
    Prepend the ship's actual position (from) to the path before the departure cell.
    The departure cell itself may be simplified away by the LOS pass.
```

### 4.5 Forward vs Reverse Path Evaluation

The `ShipNavigator::compute_path()` method (replacing `maybe_recalc_path`) runs up to two A* searches:

```
compute_path():
    // --- Forward path ---
    forward_result = map->find_path_internal(
        state.position, target.position, clearance, turning_radius, state.heading)

    // --- Should we try reverse? ---
    // Only if destination is roughly behind the ship and close enough
    bearing_to_dest = atan2(target.x - pos.x, target.y - pos.y)
    angle_to_dest = abs(angle_difference(state.heading, bearing_to_dest))
    dist_to_dest = state.position.distance_to(target.position)
    reverse_cap = params.turning_circle_radius * REVERSE_DISTANCE_CAP_FACTOR

    try_reverse = (angle_to_dest > PI * 0.5)
                  AND (dist_to_dest < reverse_cap)
                  AND (forward_result.valid)  // only compare if we have a forward path

    if try_reverse:
        // Reverse heading = heading + PI
        reverse_heading = normalize_angle(state.heading + PI)
        reverse_result = map->find_path_internal(
            state.position, target.position, clearance, turning_radius, reverse_heading,
            forward_result.total_distance)  // <-- cost bound for early termination

        if reverse_result.valid AND reverse_result.total_distance < forward_result.total_distance:
            // Use reverse path — mark departure waypoints as WP_REVERSE
            current_path = reverse_result
            // Flag the initial segment(s) that go in the reverse direction
            flag_reverse_departure(current_path, state.heading)
        else:
            current_path = forward_result
    else:
        current_path = forward_result
```

### 4.6 Early Termination for Reverse Search

To avoid wasting CPU on the reverse A* when the forward path is already short, `find_path_internal` gets an optional `cost_bound` parameter:

```cpp
PathResult find_path_internal(
    Vector2 from, Vector2 to, float clearance, float turning_radius,
    float start_heading = NAN,
    float cost_bound = INFINITY   // A* aborts if best g_cost exceeds this
) const;
```

In the A* loop, after popping a node:

```cpp
if (cg > cost_bound) {
    // This path is already more expensive than the known alternative — abort
    break;
}
```

Since A* expands nodes in f_cost order and the heuristic is admissible (Euclidean distance), if the cheapest unexpanded node's g_cost exceeds the bound, no cheaper path exists.

### 4.7 Flagging Reverse Waypoints

After the reverse path is chosen, we need to determine which waypoints should be traversed in reverse. The logic:

```
flag_reverse_departure(path, ship_heading):
    // Walk the path from the start. Each waypoint is "reverse" until the path
    // direction aligns with a heading the ship can reach by continuing forward.
    // In practice, this is usually just the first 1-2 waypoints (the departure
    // segment that backs the ship out before turning forward).

    for i in 0..path.waypoints.size()-1:
        if i == 0:
            path.flags[i] |= WP_REVERSE | WP_DEPARTURE
            continue

        // Direction from waypoint i-1 to waypoint i
        dir = (path.waypoints[i] - path.waypoints[i-1]).normalized()
        wp_heading = atan2(dir.x, dir.y)

        // If this segment's heading is within 90° of the ship's forward heading,
        // the ship can follow it going forward — stop flagging reverse.
        angle_diff = abs(angle_difference(ship_heading, wp_heading))
        if angle_diff < PI * 0.5:
            break
        else:
            path.flags[i] |= WP_REVERSE
```

### 4.8 Stuck Detection and Recovery Waypoints

Stuck detection happens in `compute_path()` when the planner fails to find any viable path (both forward and reverse A* fail or produce paths that start inside the turning dead zone).

Recovery waypoint generation:

```
compute_recovery_path():
    // Called when normal pathfinding fails because the ship is hemmed in.

    // 1. Find escape direction via SDF gradient
    grad = map->get_gradient(state.position)
    escape_heading = atan2(grad.x, grad.y)
    angle_to_escape = abs(angle_difference(state.heading, escape_heading))

    // 2. Compute how far the ship can safely reverse
    //    March backward along the reverse heading, checking SDF clearance
    reverse_dir = (sin(heading+PI), cos(heading+PI))
    max_reverse = 0
    for dist in [ship_length*0.5, ship_length, ship_length*1.5]:
        test = state.position + reverse_dir * dist
        if map->get_distance(test) >= clearance:
            max_reverse = dist
        else:
            break

    // 3. Compute how far forward the ship needs to go at full rudder to
    //    align with the escape heading.
    //    Use predict_arc_internal to simulate: from (state.position + reverse_offset),
    //    full rudder toward escape heading, find where heading aligns.
    //    The distance of this arc = the forward leg length.

    // 4. Build recovery waypoints:
    //    WP0: state.position + reverse_dir * max_reverse  [WP_REVERSE | WP_DEPARTURE]
    //    WP1: end of forward arc from WP0                  [WP_DEPARTURE]

    // 5. After WP1, attempt normal A* pathfinding from WP1 to destination
    //    with WP1's heading as start_heading.

    // 6. Concatenate: [WP0, WP1, ...normal_path...]
    //    If normal A* from WP1 also fails, return just [WP0, WP1] and set a
    //    "needs_replan_after_recovery" flag so the navigator retries after executing.
```

### 4.9 Changes to NavigationMap

The `NavigationMap` class gets ONE change: a new overload of `find_path_internal` with the `start_heading` and `cost_bound` parameters. The A* algorithm body is shared — only the initialization of the start cell's parent differs.

The original 4-parameter overload calls the new one with `start_heading = NAN, cost_bound = INFINITY`.

```cpp
// navigation_map.h — add new overload
PathResult find_path_internal(Vector2 from, Vector2 to, float clearance,
                              float turning_radius, float start_heading,
                              float cost_bound = std::numeric_limits<float>::infinity()) const;

// navigation_map.cpp — old overload becomes a forwarder
PathResult NavigationMap::find_path_internal(Vector2 from, Vector2 to, float clearance,
                                             float turning_radius) const {
    return find_path_internal(from, to, clearance, turning_radius,
                              std::numeric_limits<float>::quiet_NaN());
}
```

---

## 5. Phase 3: Unified State Machine

### 5.1 State Dispatch

In `set_state()`, replace the `switch (nav_mode)` with:

```cpp
void ShipNavigator::set_state(Vector3 position, Vector3 velocity, float heading,
                               float angular_velocity_y, float current_rudder,
                               float current_speed, float delta) {
    // Update live state
    state.position = Vector2(position.x, position.z);
    state.velocity = Vector2(velocity.x, velocity.z);
    state.heading = heading;
    state.angular_velocity_y = angular_velocity_y;
    state.current_rudder = current_rudder;
    state.current_speed = current_speed;

    // Tick timers
    if (replan_frame_cooldown > 0) replan_frame_cooldown--;
    avoidance.tick(delta);

    // Run state machine
    update(delta);

    // Update predicted arc for debug visualization
    update_predicted_arc();
}

void ShipNavigator::update(float delta) {
    switch (nav_state) {
        case NavState::PLANNING:    update_planning(); break;
        case NavState::NAVIGATING:  update_navigating(); break;
        case NavState::ARRIVING:    update_arriving(delta); break;
        case NavState::SETTLING:    update_settling(delta); break;
        case NavState::HOLDING:     update_holding(delta); break;
        case NavState::AVOIDING:    update_navigating(); break;  // same loop, avoidance tracked separately
        case NavState::EMERGENCY:   update_emergency(); break;
    }
}
```

### 5.2 navigate_to() — The Single Command

```cpp
void ShipNavigator::navigate_to(Vector3 p_target, float p_heading, float p_hold_radius) {
    Vector2 new_pos(p_target.x, p_target.z);
    float dist_change = new_pos.distance_to(target.position);
    float heading_change = std::abs(angle_difference(target.heading, p_heading));

    bool position_changed = dist_change > params.turning_circle_radius * 0.5f;
    bool heading_changed = heading_change > 0.35f;  // ~20 degrees
    bool radius_changed = std::abs(p_hold_radius - target.hold_radius) > 50.0f;

    target.position = new_pos;
    target.heading = p_heading;
    target.hold_radius = p_hold_radius;

    if (position_changed || radius_changed) {
        // Meaningful target change — replan
        nav_state = NavState::PLANNING;
    } else if (heading_changed) {
        // Heading changed but position didn't — if we're already HOLDING or SETTLING,
        // just update the target heading (the settling logic will correct).
        // If NAVIGATING/ARRIVING, no action needed (heading only matters on arrival).
        if (nav_state == NavState::HOLDING) {
            nav_state = NavState::SETTLING;
            settle_timer = 0.0f;
        }
    }
    // else: trivial change — ignore
}
```

### 5.3 stop()

```cpp
void ShipNavigator::stop() {
    target.position = state.position;
    target.heading = state.heading;
    target.hold_radius = 0.0f;
    path_valid = false;
    nav_state = NavState::HOLDING;
    set_steering_output(0.0f, 0, false, INFINITY);
}
```

### 5.4 update_planning()

```cpp
void ShipNavigator::update_planning() {
    compute_path();

    if (path_valid) {
        stuck_timer = 0.0f;
        nav_state = NavState::NAVIGATING;
    } else {
        // No path found — try to reach destination directly
        // This handles open-water cases where A* can't find a path
        // (e.g., start and end are in the same cell)
        float dist = state.position.distance_to(target.position);
        if (dist < params.turning_circle_radius * 0.5f) {
            nav_state = NavState::ARRIVING;
        } else {
            // Can't plan — hold position and hope the behavior gives us a new target
            nav_state = NavState::HOLDING;
        }
    }

    // Always produce steering output even on the planning frame
    // (use the NAVIGATING or HOLDING output from the transition)
    update(0.0f);  // re-enter with the new state for one iteration
}
```

Note: `update_planning` transitions to a new state and calls `update` again so that the ship always gets a steering output on the frame a new target is set. This avoids a 1-frame delay where the ship outputs stale rudder/throttle.

### 5.5 update_navigating()

This replaces ALL of `update_navigate_to_position`, `update_navigate_to_angle`, `update_navigate_to_pose`, and the STATION_APPROACH case of `update_station_keep`.

```cpp
void ShipNavigator::update_navigating() {
    // --- 1. Advance waypoints ---
    advance_waypoint();

    // --- 2. Check: arrived at approach radius? ---
    float dist_to_dest = state.position.distance_to(target.position);
    float approach_radius = get_approach_radius();
    if (dist_to_dest < approach_radius) {
        nav_state = NavState::ARRIVING;
        return;
    }

    // --- 3. Determine steer target and direction ---
    Vector2 steer_target;
    bool use_reverse = false;

    if (path_valid && current_wp_index < (int)current_path.waypoints.size()) {
        steer_target = current_path.waypoints[current_wp_index];
        use_reverse = (current_path.flags[current_wp_index] & WP_REVERSE) != 0;
    } else {
        steer_target = target.position;
    }

    // --- 4. Compute steering ---
    float desired_rudder = compute_rudder_to_position(steer_target, use_reverse);

    int desired_throttle;
    if (use_reverse) {
        desired_throttle = -1;
    } else {
        desired_throttle = compute_throttle_for_approach(dist_to_dest);
        float turn_angle = std::abs(angle_difference(state.heading,
            std::atan2(steer_target.x - state.position.x,
                       steer_target.y - state.position.y)));
        if (turn_angle > Math_PI * 0.5f && desired_throttle > 2) {
            desired_throttle = 2;
        }
    }

    // --- 5. Collision avoidance ---
    float ttc;
    bool collision;
    float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

    // --- 6. State transitions ---
    if (collision && ttc < 3.0f) {
        nav_state = NavState::EMERGENCY;
    } else if (collision) {
        nav_state = NavState::AVOIDING;
    } else if (nav_state == NavState::AVOIDING) {
        // Was avoiding, threat cleared — back to navigating
        nav_state = NavState::NAVIGATING;
    }

    // --- 7. Compute final throttle ---
    int final_throttle;
    if (collision) {
        if (nav_state == NavState::EMERGENCY) {
            final_throttle = out_throttle;  // Emergency handler sets this
        } else {
            final_throttle = std::min(desired_throttle, std::max(use_reverse ? -1 : 1, out_throttle));
        }
    } else {
        final_throttle = desired_throttle;
    }

    set_steering_output(safe_rudder, final_throttle, collision, ttc);

    // --- 8. Stuck detection ---
    if (std::abs(state.current_speed) < SPEED_THRESHOLD && !use_reverse) {
        stuck_timer += 1.0f / 60.0f;  // Will be replaced with delta in Phase 5
        if (stuck_timer > STUCK_TIME_THRESHOLD) {
            // Trigger replan with recovery
            nav_state = NavState::PLANNING;
            stuck_timer = 0.0f;
        }
    } else {
        stuck_timer = 0.0f;
    }

    // --- 9. Replan check ---
    if (check_replan_needed()) {
        nav_state = NavState::PLANNING;
    }
}
```

### 5.6 update_arriving()

Handles the terminal approach phase — blends position and heading steering as the ship decelerates. Replaces the "Phase 2: Terminal maneuver" section of old `update_navigate_to_pose` and the arrival check in old `update_navigate_to_position`.

```cpp
void ShipNavigator::update_arriving(float delta) {
    float dist = state.position.distance_to(target.position);
    float heading_error = std::abs(angle_difference(state.heading, target.heading));

    // Close enough in position AND heading? Start settling.
    if (dist < params.turning_circle_radius * 0.3f) {
        nav_state = NavState::SETTLING;
        settle_timer = 0.0f;
        return;
    }

    // Drifted too far back out? Return to navigating.
    float approach_radius = get_approach_radius();
    if (dist > approach_radius * 1.5f) {
        nav_state = NavState::PLANNING;
        return;
    }

    // Blend position and heading steering based on proximity
    float heading_weight = 1.0f - (dist / approach_radius);
    heading_weight = clamp_f(heading_weight, 0.0f, 0.7f);

    float pos_rudder = compute_rudder_to_position(target.position);
    float heading_rudder = compute_rudder_to_heading(target.heading);
    float blended_rudder = lerp_f(pos_rudder, heading_rudder, heading_weight);

    int desired_throttle = compute_throttle_for_approach(dist);
    desired_throttle = std::min(desired_throttle, 2);  // Don't overshoot

    // Collision avoidance
    float ttc;
    bool collision;
    float safe_rudder = select_safe_rudder(blended_rudder, desired_throttle, ttc, collision);

    int final_throttle;
    if (collision) {
        final_throttle = std::min(desired_throttle, 1);
    } else {
        final_throttle = desired_throttle;
    }

    set_steering_output(safe_rudder, final_throttle, collision, ttc);
}
```

### 5.7 update_settling()

Handles heading correction once the ship is at the destination. Absorbs the old STATION_SETTLE logic. For large heading errors, generates 3-point turn waypoints and drops back to NAVIGATING.

```cpp
void ShipNavigator::update_settling(float delta) {
    settle_timer += delta;
    float heading_error = std::abs(angle_difference(state.heading, target.heading));
    float speed = std::abs(state.current_speed);
    float dist = state.position.distance_to(target.position);

    // Heading achieved?
    if (heading_error < HEADING_TOLERANCE && speed < SPEED_THRESHOLD) {
        nav_state = NavState::HOLDING;
        hold_timer = 0.0f;
        return;
    }

    // Drifted too far from position?
    float max_drift = (target.hold_radius > 0.0f)
        ? target.hold_radius * 1.5f
        : params.turning_circle_radius;
    if (dist > max_drift) {
        nav_state = NavState::PLANNING;
        return;
    }

    // Large heading error + slow → plan 3-point turn waypoints
    if (heading_error > Math_PI * 0.5f && speed < SPEED_THRESHOLD * 2.0f && settle_timer > 1.0f) {
        plan_heading_correction();
        nav_state = NavState::NAVIGATING;
        return;
    }

    // --- Forward heading correction ---
    // (Small heading error or still moving — gentle corrections)

    float heading_rudder = 0.0f;
    if (heading_error > 0.05f) {
        heading_rudder = compute_rudder_to_heading(target.heading);
    }

    // Blend in center-seeking when drifting from target position
    float center_rudder = compute_rudder_to_position(target.position);
    float center_weight = clamp_f(dist / std::max(target.hold_radius, params.turning_circle_radius * 0.5f), 0.0f, 0.5f);
    float desired_rudder = lerp_f(heading_rudder, center_rudder, center_weight);

    // Throttle: just enough to maintain rudder authority
    int desired_throttle = 0;
    if (heading_error > HEADING_TOLERANCE && speed < SPEED_THRESHOLD * 2.0f) {
        desired_throttle = 1;
    }

    // Collision avoidance
    float ttc;
    bool collision;
    float safe_rudder = select_safe_rudder(desired_rudder, desired_throttle, ttc, collision);

    int final_throttle = collision ? 0 : desired_throttle;
    set_steering_output(safe_rudder, final_throttle, collision, ttc);
}
```

### 5.8 plan_heading_correction()

Generates short waypoints for a 3-point turn when the heading error is too large for a simple forward correction. The waypoints are injected into `current_path` and the state transitions to NAVIGATING.

```cpp
void ShipNavigator::plan_heading_correction() {
    // Determine how much room we have to maneuver
    float room_forward = estimate_room_in_direction(state.heading);
    float room_reverse = estimate_room_in_direction(state.heading + Math_PI);

    // Generate reverse leg: back up a short distance
    float reverse_dist = std::min(room_reverse, params.ship_length * 1.5f);
    Vector2 reverse_dir(std::sin(state.heading + Math_PI), std::cos(state.heading + Math_PI));
    Vector2 wp_reverse = state.position + reverse_dir * reverse_dist;

    // Generate forward leg: drive forward with full rudder toward target heading
    // Rudder direction: whichever side has the shorter turn to target heading
    float heading_diff = angle_difference(state.heading, target.heading);
    float forward_dist = std::min(room_forward, params.turning_circle_radius * 0.5f);
    Vector2 forward_dir(std::sin(state.heading), std::cos(state.heading));
    Vector2 wp_forward = state.position + forward_dir * forward_dist;

    // Build the correction path
    current_path.waypoints.clear();
    current_path.flags.clear();

    current_path.waypoints.push_back(wp_reverse);
    current_path.flags.push_back(WP_REVERSE | WP_DEPARTURE);

    current_path.waypoints.push_back(wp_forward);
    current_path.flags.push_back(WP_DEPARTURE);

    // Append the target position itself so the ship returns to it after the turn
    current_path.waypoints.push_back(target.position);
    current_path.flags.push_back(WP_NONE);

    current_path.valid = true;
    path_valid = true;
    current_wp_index = 0;
}
```

Where `estimate_room_in_direction` is a helper that checks how far the ship can go in a direction before hitting land:

```cpp
float ShipNavigator::estimate_room_in_direction(float heading) const {
    if (map.is_null() || !map->is_built()) return params.ship_length * 2.0f;

    float clearance = get_ship_clearance();
    Vector2 dir(std::sin(heading), std::cos(heading));

    for (float d = params.ship_beam; d <= params.ship_length * 3.0f; d += params.ship_beam) {
        Vector2 test = state.position + dir * d;
        if (map->get_distance(test.x, test.y) < clearance) {
            return std::max(d - params.ship_beam, 0.0f);
        }
    }
    return params.ship_length * 3.0f;
}
```

### 5.9 update_holding()

Replaces old STATION_HOLDING. Minimal corrections — the ship stays put.

```cpp
void ShipNavigator::update_holding(float delta) {
    hold_timer += delta;
    float dist = state.position.distance_to(target.position);
    float heading_error = std::abs(angle_difference(state.heading, target.heading));

    // Drifted out of zone?
    float max_drift = (target.hold_radius > 0.0f)
        ? target.hold_radius
        : params.turning_circle_radius * 0.5f;
    if (dist > max_drift) {
        nav_state = NavState::PLANNING;
        return;
    }

    // Heading drifted significantly?
    if (heading_error > HEADING_TOLERANCE * 2.0f) {
        nav_state = NavState::SETTLING;
        settle_timer = 0.0f;
        return;
    }

    // Micro-corrections
    float rudder = 0.0f;
    if (heading_error > HEADING_TOLERANCE) {
        rudder = compute_rudder_to_heading(target.heading);
        rudder = clamp_f(rudder, -0.3f, 0.3f);
    }

    int throttle = 0;
    if (std::abs(rudder) > 0.1f && std::abs(state.current_speed) < 1.0f) {
        throttle = 1;  // Need some speed for rudder authority
    }

    // Even in holding, check for collisions (another ship drifting toward us)
    float ttc;
    bool collision;
    float safe_rudder = select_safe_rudder(rudder, throttle, ttc, collision);

    set_steering_output(safe_rudder, collision ? 0 : throttle, collision, ttc);
}
```

### 5.10 update_emergency()

Unchanged from current behavior — gradient escape heading, reverse if facing terrain.

```cpp
void ShipNavigator::update_emergency() {
    // Check if we've cleared the emergency
    auto desired_arc = predict_arc_internal(0.0f, 2, get_lookahead_distance());
    float ttc = check_arc_collision(desired_arc, get_ship_clearance(), get_soft_clearance());
    float arc_time = desired_arc.empty() ? 0.0f : desired_arc.back().time;

    if (ttc >= arc_time * 0.9f) {
        // Clear — replan from here
        nav_state = NavState::PLANNING;
        return;
    }

    // Still in danger — gradient escape
    if (map.is_valid() && map->is_built()) {
        Vector2 grad = map->get_gradient(state.position.x, state.position.y);
        float escape_heading = std::atan2(grad.x, grad.y);
        float rudder = compute_rudder_to_heading(escape_heading);
        float angle_to_escape = std::abs(angle_difference(state.heading, escape_heading));

        if (angle_to_escape < Math_PI * 0.5f) {
            set_steering_output(rudder, 2, true, ttc);
        } else {
            set_steering_output(rudder, -1, true, ttc);
        }
    } else {
        float rudder = (state.angular_velocity_y > 0.0f) ? 1.0f : -1.0f;
        set_steering_output(rudder, -1, true, ttc);
    }
}
```

### 5.11 get_approach_radius()

New helper replacing the inline `approach_radius` calculations scattered through the old code:

```cpp
float ShipNavigator::get_approach_radius() const {
    return std::max(params.turning_circle_radius * 2.0f, get_stopping_distance() * 1.5f);
}
```

### 5.12 check_replan_needed()

Replaces the ad-hoc replan checks scattered at the bottom of old update methods:

```cpp
bool ShipNavigator::check_replan_needed() {
    if (replan_frame_cooldown > 0) return false;

    // Path deviation
    if (path_valid && current_wp_index < (int)current_path.waypoints.size()) {
        Vector2 nearest_wp = current_path.waypoints[current_wp_index];
        float dist = state.position.distance_to(nearest_wp);
        if (dist > params.turning_circle_radius * 2.0f) {
            replan_frame_cooldown = REPLAN_FRAME_COOLDOWN;
            return true;
        }

        // Current waypoint in turning dead zone (and it's the last one)
        if (current_wp_index >= (int)current_path.waypoints.size() - 1) {
            if (is_waypoint_in_turning_dead_zone(nearest_wp)) {
                replan_frame_cooldown = REPLAN_FRAME_COOLDOWN;
                return true;
            }
        }
    }

    // Avoidance just cleared — check if path is still viable
    if (!avoidance.active && nav_state == NavState::AVOIDING) {
        replan_frame_cooldown = REPLAN_FRAME_COOLDOWN;
        return true;
    }

    return false;
}
```

---

## 6. Phase 4: Remove apply_gradient_bias

### Rationale

`apply_gradient_bias` is currently a no-op (`return rudder;` on the first line, dead code below). When it was active, it fought against the desired heading during CA island cover holding — the SDF gradient pushed the ship away from the island, overriding the tangential heading the behavior requested.

The arc-based collision avoidance in `select_safe_rudder` already handles terrain avoidance properly via forward simulation + SDF checks. The gradient bias was double-dipping.

### Changes

**ship_navigator.h**: Delete `float apply_gradient_bias(float rudder) const;`

**ship_navigator.cpp**: Delete the entire `apply_gradient_bias` method (~40 lines). Remove all call sites — approximately 12 occurrences of `desired_rudder = apply_gradient_bias(desired_rudder);` throughout the file. Since the new unified state machine won't have these calls, this happens naturally during Phase 3.

---

## 7. Phase 5: Event-Driven Recalculation

### 7.1 C++ Side: Dirty Flags

Replace `path_recalc_cooldown` (float timer) with `replan_frame_cooldown` (int frame counter). Path recomputation happens when:

| Trigger | Where Detected | Mechanism |
|---------|---------------|-----------|
| New target | `navigate_to()` | Sets `nav_state = PLANNING` |
| Path deviation | `check_replan_needed()` | Distance to current waypoint > 2× turning radius |
| Dead-zone waypoint | `check_replan_needed()` | Last waypoint in turning dead zone |
| Avoidance cleared | `check_replan_needed()` | `avoidance.active` went false |
| Stuck timeout | `update_navigating()` | Speed < threshold for > 2 seconds |
| Drift from hold | `update_holding()` | Distance > hold_radius |
| Heading drift | `update_holding()` | Heading error > 2× tolerance |

Safety floor: `REPLAN_FRAME_COOLDOWN = 9` frames (~0.15s) between replans, tracked as a decrementing integer.

### 7.2 GDScript Side: Extended Intent Events

In `bot_controller_v4.gd`, update `_check_intent_events()`:

**New triggers to add:**

```gdscript
# --- NEW: Enemy centroid shift ---
var enemy_avg = server_node.get_enemy_avg_position(_ship.team.team_id)
if enemy_avg != Vector3.ZERO:
    if _cached_enemy_avg != Vector3.ZERO:
        if enemy_avg.distance_to(_cached_enemy_avg) > 500.0:
            _force_intent_next_frame = true
    _cached_enemy_avg = enemy_avg

# --- NEW: HP threshold crossing ---
var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp
var hp_bracket = 4  # full
if hp_ratio < 0.25: hp_bracket = 1
elif hp_ratio < 0.50: hp_bracket = 2
elif hp_ratio < 0.75: hp_bracket = 3
if _last_hp_bracket >= 0 and hp_bracket != _last_hp_bracket:
    _force_intent_next_frame = true
_last_hp_bracket = hp_bracket
```

**New member variables:**

```gdscript
var _cached_enemy_avg: Vector3 = Vector3.ZERO
var _last_hp_bracket: int = -1
```

**Replace BEHAVIOR_QUERY_INTERVAL stagger with min/max interval:**

```gdscript
const MIN_BEHAVIOR_INTERVAL: float = 0.3   # minimum seconds between queries
const MAX_BEHAVIOR_INTERVAL: float = 2.0   # maximum seconds without a query
var _behavior_timer: float = 0.0

# In _physics_process:
_behavior_timer += delta
var should_query: bool = false

if _force_intent_next_frame:
    should_query = true
    _force_intent_next_frame = false
    _event_cooldown = EVENT_COOLDOWN_DURATION
    _behavior_timer = 0.0
elif _behavior_timer >= MAX_BEHAVIOR_INTERVAL:
    should_query = true
    _behavior_timer = 0.0
# MIN_BEHAVIOR_INTERVAL is enforced by _event_cooldown for event triggers
```

---

## 8. Phase 6: GDScript Layer Updates

### 8.1 NavIntent Simplification

**nav_intent.gd** — remove Mode enum, simplify to universal struct:

```gdscript
class_name NavIntent
extends RefCounted

## Target world position
var target_position: Vector3 = Vector3.ZERO

## Target heading in radians (0 = +Z)
var target_heading: float = 0.0

## Hold radius: 0 = arrive and stop, >0 = station-keep within this radius
var hold_radius: float = 0.0

## Optional throttle override (-1 = navigator decides)
var throttle_override: int = -1

## Create a navigation intent
static func create(pos: Vector3, heading: float, radius: float = 0.0) -> NavIntent:
    var i = NavIntent.new()
    i.target_position = pos
    i.target_heading = heading
    i.hold_radius = radius
    return i
```

### 8.2 bot_controller_v4.gd Changes

**_execute_nav_intent** simplification:

```gdscript
func _execute_nav_intent() -> void:
    if _last_intent == null:
        navigator.navigate_to(Vector3(destination.x, 0.0, destination.z), get_ship_heading(), 0.0)
        return
    navigator.navigate_to(
        _last_intent.target_position,
        _last_intent.target_heading,
        _last_intent.hold_radius
    )
```

**_update_nav_intent** — remove the `match _last_intent.mode:` branching for validation and destination tracking. Replace with:

```gdscript
# Validate
if _last_intent != null and NavigationMapManager.is_map_ready():
    var nav_map = NavigationMapManager.get_map()
    var clearance = navigator.get_clearance_radius()
    var turning_radius = movement.turning_circle_radius
    var ship_pos_2d = Vector2(_ship.global_position.x, _ship.global_position.z)
    var dest_2d = Vector2(_last_intent.target_position.x, _last_intent.target_position.z)
    if not nav_map.is_navigable(dest_2d.x, dest_2d.y, clearance):
        var safe = nav_map.safe_nav_point(ship_pos_2d, dest_2d, clearance, turning_radius)
        _last_intent.target_position = Vector3(safe["position"].x, 0.0, safe["position"].y)

# Track for debug
if _last_intent != null:
    destination = _last_intent.target_position
```

**_is_intent_similar** — no more mode comparison:

```gdscript
func _is_intent_similar(old_intent: NavIntent, new_intent: NavIntent) -> bool:
    var pos_dist = old_intent.target_position.distance_to(new_intent.target_position)
    if pos_dist >= INTENT_POSITION_REUSE_THRESHOLD:
        return false
    var radius_diff = absf(old_intent.hold_radius - new_intent.hold_radius)
    if radius_diff >= 100.0:
        return false
    return true
```

**get_nav_mode_string** — simplify to always return "NAVIGATE" or remove entirely.

**get_nav_state_string** — update to new state names:

```gdscript
func get_nav_state_string() -> String:
    var state_names = [
        "PLANNING", "NAVIGATING", "ARRIVING",
        "SETTLING", "HOLDING", "AVOIDING", "EMERGENCY"
    ]
    var state_idx = navigator.get_nav_state()
    if state_idx >= 0 and state_idx < state_names.size():
        return state_names[state_idx]
    return "UNKNOWN"
```

**Pass delta to set_state**:

```gdscript
# In _physics_process:
navigator.set_state(
    _ship.global_position,
    _ship.linear_velocity,
    get_ship_heading(),
    _ship.angular_velocity.y,
    movement.rudder_input,
    get_current_speed(),
    delta   # NEW: explicit delta
)
```

### 8.3 Behavior File Changes

All behaviors change NavIntent construction:

| Old Call | New Call |
|----------|---------|
| `NavIntent.pose(dest, heading)` | `NavIntent.create(dest, heading)` |
| `NavIntent.position(dest)` | `NavIntent.create(dest, approach_heading)` |
| `NavIntent.station(center, radius, heading)` | `NavIntent.create(center, heading, radius)` |
| `NavIntent.angle(heading)` | `NavIntent.create(ship.global_position, heading)` |

**behavior.gd** — `get_nav_intent` base implementation:

```gdscript
func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
    var friendly = server.get_team_ships(ship.team.team_id)
    var enemy = server.get_valid_targets(ship.team.team_id)
    if original_dest == null:
        original_dest = ship.global_position + Vector3(0,0,20_000) * (1 if ship.team.team_id == 0 else -1)
    var dest = get_desired_position(friendly, enemy, target, original_dest)

    if ship.visible_to_enemy and target != null:
        var heading_info = get_desired_heading(target, _get_ship_heading(), 0.0, dest)
        if heading_info.get("use_evasion", false):
            return NavIntent.create(dest, heading_info.heading)

    var to_dest = dest - ship.global_position
    to_dest.y = 0.0
    var approach_heading = _get_ship_heading()
    if to_dest.length_squared() > 1.0:
        approach_heading = atan2(to_dest.x, to_dest.z)
    return NavIntent.create(dest, approach_heading)
```

**ca_behav.gd** — station-keeping at island:

```gdscript
# Old:
return NavIntent.station(_nav_destination, arrival_radius * 0.5, heading)
# New:
return NavIntent.create(_nav_destination, heading, arrival_radius * 0.5)
```

**bb_behav.gd** — all uses already return POSE, just change constructor:

```gdscript
# Old:
return NavIntent.pose(desired_position, broadside_heading)
# New:
return NavIntent.create(desired_position, broadside_heading)
```

**dd_behav.gd** — torpedo runs and retreat:

```gdscript
# Old:
return NavIntent.pose(desired_position, launch_heading)
# New:
return NavIntent.create(desired_position, launch_heading)
```

---

## 9. Implementation Order

Implementation is ordered to minimize time the project is in a broken state. Each step should compile and run (possibly with degraded behavior) before the next step begins.

### Step 1: Remove apply_gradient_bias (Phase 4)

**Effort:** Small (< 1 hour)
**Risk:** Zero — it's already a no-op
**Dependencies:** None

- Delete the method body from `ship_navigator.cpp`
- Delete the declaration from `ship_navigator.h`
- Remove all `desired_rudder = apply_gradient_bias(desired_rudder)` call sites
- Build and verify

### Step 2: Add delta to set_state (Part of Phase 1)

**Effort:** Small (< 1 hour)
**Risk:** Low
**Dependencies:** None

- Add `float delta` parameter to `set_state` in `.h` and `.cpp`
- Replace all `1.0f / 60.0f` in `set_state` with `delta`
- Update `bot_controller_v4.gd` to pass `delta`
- Build and verify — behavior should be identical at 60fps

### Step 3: New types + navigate_to alongside old API (Phase 1)

**Effort:** Medium (2-3 hours)
**Risk:** Medium
**Dependencies:** Step 2

- Add `NavTarget`, new `NavState` enum, new `WaypointFlags` to `nav_types.h`
  - Keep OLD enums temporarily (rename them with `_V4` suffix to avoid conflicts)
- Add `navigate_to()` to `ship_navigator.h` and `.cpp`
  - Initially, `navigate_to` internally dispatches to the old `navigate_to_pose` / `station_keep` based on `hold_radius`
  - This is a **shim** — it lets GDScript migrate without changing C++ steering yet
- Update bind methods to expose `navigate_to`
- Build and verify — old behavior, new API available

### Step 4: Migrate GDScript to new API (Phase 6)

**Effort:** Medium (2-3 hours)
**Risk:** Medium
**Dependencies:** Step 3

- Rewrite `nav_intent.gd` — new `NavIntent.create()` API
- Update `bot_controller_v4.gd`:
  - `_execute_nav_intent` calls `navigate_to`
  - `_is_intent_similar` simplified
  - `_update_nav_intent` validation simplified
  - `get_nav_state_string` updated (keep both old and new names during transition)
  - Pass delta to `set_state`
- Update all behavior files (`behavior.gd`, `ca_behav.gd`, `bb_behav.gd`, `dd_behav.gd`)
- Build and verify — everything should work identically since `navigate_to` is still a shim

### Step 5: Heading-aware pathfinding (Phase 2)

**Effort:** Large (4-6 hours)
**Risk:** Medium-High — this changes path quality
**Dependencies:** Step 3

- Add new `find_path_internal` overload with `start_heading` + `cost_bound` to `navigation_map.h/.cpp`
- The old overload forwards to the new one with `NAN` heading
- Implement virtual departure cell seeding
- Update `ShipNavigator::compute_path()` (new method, doesn't replace `maybe_recalc_path` yet)
  - Forward path with heading
  - Conditional reverse path with early termination
  - Reverse waypoint flagging
  - Recovery waypoint generation for stuck cases
- **Test extensively:**
  - Ship facing toward destination (should produce same path as before)
  - Ship facing away from close destination (should produce reverse path)
  - Ship facing away from far destination (should produce forward U-turn path)
  - Ship hemmed in near terrain (should produce recovery waypoints)

### Step 6: Unified state machine (Phase 3)

**Effort:** Large (6-8 hours)
**Risk:** High — complete steering pipeline rewrite
**Dependencies:** Steps 4 + 5

- Implement all `update_*` methods in `ship_navigator.cpp`
- Remove the old `navigate_to` shim — make it set `NavTarget` directly
- Remove old `update_navigate_to_*` and `update_station_keep` methods
- Remove the `NavMode` enum and all references
- `set_state` dispatches via `update(delta)` to the new state machine
- Wire `compute_path()` into `update_planning()`
- Remove `maybe_recalc_path`
- **Test extensively:**
  - All ship classes navigate to positions
  - Station-keeping at islands (CA behavior)
  - Broadside maneuvering (BB behavior)
  - Torpedo runs with heading (DD behavior)
  - Reverse parking into tight spaces
  - Recovery from grounding
  - 3-point turns in harbors
  - Collision avoidance still works
  - Torpedo avoidance still works

### Step 7: Event-driven recalculation (Phase 5)

**Effort:** Medium (2-3 hours)
**Risk:** Low
**Dependencies:** Step 6

- Replace `path_recalc_cooldown` with `replan_frame_cooldown`
- Implement `check_replan_needed()`
- Add new event triggers to `_check_intent_events()` in GDScript
- Replace `BEHAVIOR_QUERY_INTERVAL` with min/max timer
- Add `_cached_enemy_avg`, `_last_hp_bracket` tracking

### Step 8: Cleanup

**Effort:** Small (1 hour)
**Risk:** Zero
**Dependencies:** Step 7

- Remove old `NavMode` enum (if not done in Step 6)
- Remove old `_V4` suffixed enums
- Remove backward-compatible shims
- Remove `navigate_to_position`, `navigate_to_angle`, `navigate_to_pose`, `station_keep` bindings
- Remove `NavIntent.Mode` references if any remain
- Final build and full test pass

---

## 10. File Change Manifest

### C++ Files

| File | Changes |
|------|---------|
| `nav_types.h` | Remove `NavMode`. New `NavState`. New `NavTarget`. Update `WaypointFlags`. Remove old state constants. |
| `navigation_map.h` | Add new `find_path_internal` overload with `start_heading` + `cost_bound`. |
| `navigation_map.cpp` | Implement heading-aware A* start seeding. Old overload forwards to new. |
| `ship_navigator.h` | Remove old nav commands + old update methods + `apply_gradient_bias` + `NavMode` member. Add `navigate_to`, `NavTarget`, new update methods, new helpers. Update `set_state` signature. |
| `ship_navigator.cpp` | Complete rewrite of steering pipeline. Remove 4 old update methods + `apply_gradient_bias`. Add unified state machine, `compute_path`, heading correction planner. |

### GDScript Files

| File | Changes |
|------|---------|
| `nav_intent.gd` | Remove `Mode` enum. Remove `zone_center`, `zone_radius`, `preferred_heading`. Add `hold_radius`. Replace factory methods with `create()`. |
| `bot_controller_v4.gd` | Simplify `_execute_nav_intent`. Simplify `_update_nav_intent` validation. Simplify `_is_intent_similar`. Update `get_nav_state_string`. Add `delta` to `set_state` call. Add new event triggers. Replace frame-stagger with timer. |
| `behavior.gd` | Update `get_nav_intent` to use `NavIntent.create()`. |
| `ca_behav.gd` | Update `NavIntent.station()` → `NavIntent.create()`. |
| `bb_behav.gd` | Update `NavIntent.pose()` → `NavIntent.create()`. |
| `dd_behav.gd` | Update `NavIntent.pose/position()` → `NavIntent.create()`. |

### Files NOT Changed

| File | Reason |
|------|--------|
| `navigation_map.cpp` (SDF, rasterization, islands, cover) | Untouched — only the new `find_path_internal` overload is added |
| `debug.gd` | No nav-mode-specific logic; reads generic debug vectors |
| `ShipMovementV4` | Interface unchanged — still receives `[throttle, rudder]` |

---

## 11. Testing Plan

### Unit Tests (Manual Scenarios)

1. **Forward path, open water**: Ship facing destination 5000m ahead. Expected: straight-line path, no departure waypoint needed, identical to V4.

2. **Forward path with obstacle**: Ship facing destination behind an island. Expected: path curves around island with curvature penalty, ship follows smoothly.

3. **Destination behind ship, close**: Destination 300m behind ship (< turning_radius). Expected: reverse path chosen (shorter than U-turn), ship backs into position.

4. **Destination behind ship, far**: Destination 2000m behind ship (> reverse cap). Expected: forward U-turn path chosen, ship turns around and navigates forward.

5. **Destination behind ship, terrain blocks U-turn**: Ship facing a wall, destination behind. Expected: reverse departure + forward path around terrain.

6. **Stuck near terrain**: Ship pushed against island by collision avoidance. Expected: `compute_path` detects stuck, generates recovery waypoints (reverse + forward turn), ship wiggles free.

7. **Station-keeping**: Ship told to hold position at current location. Expected: NAVIGATING → ARRIVING → SETTLING → HOLDING. Ship corrects heading, then holds still.

8. **Station-keeping, large heading error**: Ship arrives at position facing 150° wrong. Expected: SETTLING detects large error, calls `plan_heading_correction`, drops to NAVIGATING, executes 3-point turn, returns to SETTLING → HOLDING.

9. **CA island cover**: CA behavior returns NavIntent with hold_radius > 0. Expected: ship navigates to cover position, settles into tangential heading, holds position.

10. **BB broadside maneuver**: BB behavior returns NavIntent with broadside heading. Expected: ship arrives at engagement position, achieves broadside heading.

11. **DD torpedo run**: DD behavior returns NavIntent with perpendicular heading. Expected: ship flanks target, achieves beam-on heading for torpedo launch.

12. **Collision avoidance during reverse**: Ship reversing, another ship approaches from behind. Expected: `select_safe_rudder` finds safe maneuver (now called for reverse too, unlike V4).

13. **Torpedo avoidance**: Torpedo approaching ship in any nav state. Expected: torpedo avoidance in `select_safe_rudder` still works identically.

14. **Path recalculation on drift**: Ship pushed off path by avoidance > 2× turning radius. Expected: `check_replan_needed` triggers replan.

15. **Event-driven intent**: Enemy cluster moves 600m. Expected: `_check_intent_events` forces behavior re-query.

### Regression Checks

- No ship should ever get permanently stuck (the recovery path should always produce at least a wiggle-out maneuver)
- No ship should oscillate between PLANNING and NAVIGATING (the replan frame cooldown prevents this)
- CA ships should maintain their island cover heading (no gradient bias fighting it)
- All debug visualizations (nav path, predicted arc, waypoint markers) should still work
- Frame time should not increase (heading-aware A* is the same cost as before; the reverse A* has early termination)