# Ship Navigator — GDExtension Design Document

## 1. Overview

The Ship Navigator is a high-performance C++ GDExtension that replaces Godot's built-in NavigationServer / NavMesh system for ship AI pathfinding and steering. It is purpose-built for large vessels that have significant turning circles, rudder response lag, acceleration/deceleration curves, and hull clearance requirements.

The system provides four navigation modes:
- **Position navigation** — move to a world position
- **Angle navigation** — acquire a specific heading
- **Pose navigation** — arrive at a position facing a specific direction
- **Station-keeping** — hold position within a zone at a preferred heading

All modes share a common arc-prediction and SDF collision-avoidance core. The system outputs raw `rudder ∈ [-1.0, 1.0]` and `throttle ∈ [-1, 4]` commands that feed directly into `ShipMovementV4.set_movement_input()`.

### 1.1 Goals

| Goal | Detail |
|------|--------|
| Eliminate grounding | Forward-simulate the ship's actual turning arc against an SDF; never command a turn that clips land |
| Physics-aware steering | Account for turning circle radius, rudder response time, acceleration/deceleration, and ship dimensions |
| Angle navigation | First-class support for acquiring a specific heading (broadside presentation, torpedo runs, angling) |
| Island cover without death spirals | Station-keeping zones instead of single-point destinations; approach-lane planning with deceleration awareness |
| High performance | O(1) SDF lookups replace per-frame physics raycasts; all heavy math in C++ |
| Drop-in replacement | GDScript behaviors keep their tactical logic; only the navigation interface changes |
| Pathfinding around islands | C++ handles full A-to-B routing using SDF-aware pathfinding, replacing the NavMesh proxy system entirely |

### 1.2 What This System Does NOT Do

- It does not make tactical decisions (target selection, ammo choice, engagement range). Those remain in GDScript behaviors (`BBBehavior`, `CABehavior`, `DDBehavior`).
- It does not replace `ShipMovementV4` physics. It produces steering commands that `ShipMovementV4` executes.
- It does not handle ship-to-ship collision avoidance directly, though it provides the infrastructure for it (other ships can be registered as dynamic obstacles).

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ GDScript Layer                                               │
│                                                              │
│  bot_controller_v4.gd          BotBehavior subclasses        │
│  ┌────────────────────┐        ┌─────────────────────┐      │
│  │ Per-frame:          │        │ BBBehavior           │      │
│  │  get nav intent     │◄───────│ CABehavior           │      │
│  │  from behavior      │        │ DDBehavior           │      │
│  │                     │        │                     │      │
│  │  call navigator     │        │ Returns NavIntent:  │      │
│  │  read rudder/throt  │        │  mode, target_pos,  │      │
│  │  send to movement   │        │  target_heading,    │      │
│  └────────┬───────────┘        │  zone_center/radius │      │
│           │                     └─────────────────────┘      │
│           │ navigate_to_pose(pos, heading)                   │
│           │ station_keep(center, radius, heading)            │
│           ▼                                                  │
├──────────────────────────────────────────────────────────────┤
│ C++ GDExtension Layer                                        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ ShipNavigator (one per bot ship)                     │    │
│  │                                                      │    │
│  │  Ship params:                                        │    │
│  │    turning_radius, rudder_response_time,             │    │
│  │    acceleration_time, deceleration_time,             │    │
│  │    max_speed, ship_length, ship_beam                 │    │
│  │                                                      │    │
│  │  Live state (updated each frame):                    │    │
│  │    position, velocity, heading, angular_velocity,    │    │
│  │    current_rudder, current_throttle, current_speed   │    │
│  │                                                      │    │
│  │  Core algorithms:                                    │    │
│  │    arc_predict()          — forward simulate arc     │    │
│  │    find_path()            — SDF-aware pathfinding    │    │
│  │    compute_steering()     — pick rudder + throttle   │    │
│  │    check_trajectory()     — collision test on arc    │    │
│  │                                                      │    │
│  │  Navigation modes:                                   │    │
│  │    navigate_to_position(target)                      │    │
│  │    navigate_to_angle(heading)                        │    │
│  │    navigate_to_pose(target, heading)                 │    │
│  │    station_keep(center, radius, heading)             │    │
│  │                                                      │    │
│  │  Output:                                             │    │
│  │    get_rudder() → float [-1, 1]                      │    │
│  │    get_throttle() → int [-1, 4]                      │    │
│  │    get_predicted_path() → PackedVector3Array         │    │
│  │    get_nav_state() → int (enum)                      │    │
│  └──────────────────┬──────────────────────────────────┘    │
│                     │                                        │
│                     │ SDF queries                            │
│                     ▼                                        │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ NavigationMap (singleton, shared by all navigators)  │    │
│  │                                                      │    │
│  │  SDF grid:                                           │    │
│  │    2D float array, one distance value per cell       │    │
│  │    Positive = water, Negative = land                 │    │
│  │    Bilinear interpolated lookups                     │    │
│  │                                                      │    │
│  │  Queries:                                            │    │
│  │    get_distance(x, z) → float                        │    │
│  │    get_gradient(x, z) → Vector2                      │    │
│  │    is_navigable(x, z, clearance) → bool              │    │
│  │    raycast(from, to, clearance) → RayResult          │    │
│  │    find_path(from, to, clearance) → Vector2[]        │    │
│  │                                                      │    │
│  │  Island data:                                        │    │
│  │    island centers, approximate radii                 │    │
│  │    cover zone computation                            │    │
│  │                                                      │    │
│  │  Build:                                              │    │
│  │    build_from_collision_shapes(shapes[])             │    │
│  │    build_from_heightmap(image)                       │    │
│  │    set_map_bounds(min, max)                          │    │
│  │    set_cell_size(float)                              │    │
│  └─────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. NavigationMap

### 3.1 Signed Distance Field (SDF)

The NavigationMap stores a 2D grid of signed distance values covering the entire playable area.

**Coordinate system**: The SDF operates in Godot's XZ plane (Y is up/ignored). Cell `(i, j)` maps to world coordinates:
```
world_x = map_min_x + i * cell_size
world_z = map_min_z + j * cell_size
```

**Sign convention**:
- Positive values = distance to nearest land (open water)
- Negative values = inside land
- Zero = shoreline

**Current map parameters** (from `map.tscn` analysis):
- Map bounds: `[-17500, -17500]` to `[17500, 17500]` (35 km × 35 km)
- Map boundary constant: `MAP_BOUNDARY = 17500.0`

**Default configuration**:
| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `cell_size` | 50.0 m | Matches existing nav mesh cell_size; sufficient for ship-scale navigation |
| Grid dimensions | 700 × 700 | 35000 / 50 = 700 cells per axis |
| Memory | ~1.96 MB | 700 × 700 × 4 bytes (float32) |

The cell size is configurable. For higher fidelity near islands, a two-level approach could be used (coarse grid + fine grid near shorelines), but the single-level 50m grid is sufficient for the initial implementation given that the smallest ship beam is ~15m (Shimakaze) and clearance margins will be at least 100m.

### 3.2 SDF Construction

The SDF is built once at map load time. Two build methods are supported:

#### Method A: From Collision Shapes (Primary)

```cpp
void NavigationMap::build_from_collision_shapes(TypedArray<Node3D> island_bodies)
```

1. Initialize all cells to `+MAX_DISTANCE` (open water)
2. For each island `StaticBody3D`:
   a. Iterate its `CollisionShape3D` children
   b. For `ConcavePolygonShape3D` (the common case for map islands): extract triangle faces, rasterize them onto the grid, marking cells as land (negative distance)
   c. For `BoxShape3D`, `SphereShape3D`, `CylinderShape3D`: use analytical signed distance
3. Compute exact signed distances using a jump-flood or brute-force sweep:
   - For each land cell, propagate distance outward
   - For each water cell near land, compute exact Euclidean distance to nearest land cell
4. Store island metadata: center position (average of land cells), approximate radius (max distance from center to any land cell of that island)

This leverages the existing `islands` array on the `Map` class, which already references all `StaticBody3D` nodes in the `"island"` group.

#### Method B: From Raycast Scan (Fallback)

```cpp
void NavigationMap::build_from_raycast_scan(PhysicsDirectSpaceState3D *space_state, int collision_mask)
```

1. For each grid cell, cast a vertical ray from `(x, 10000, z)` down to `(x, -1, z)` with `collision_mask = 1` (terrain layer)
2. If ray hits above water level → land cell
3. If no hit → water cell
4. Run distance transform to produce signed distances

This is slower but works with any collision geometry without parsing shape types.

### 3.3 SDF Queries

All queries use bilinear interpolation for sub-cell accuracy.

```cpp
// Core distance query — returns signed distance to nearest land
// Positive = open water, Negative = inside land
float get_distance(float x, float z) const;

// Gradient of the distance field — points away from nearest land
// Useful for "push away from shore" forces
Vector2 get_gradient(float x, float z) const;

// Can a circle of given radius navigate here without touching land?
bool is_navigable(float x, float z, float clearance) const;
// Equivalent to: get_distance(x, z) >= clearance

// March along a line segment, testing clearance at each step
// Returns hit info if clearance is violated
struct RayResult {
    bool hit;
    Vector2 position;    // world XZ of first violation
    float distance;      // distance along ray to violation
    float penetration;   // how far into the unsafe zone
};
RayResult raycast(Vector2 from, Vector2 to, float clearance, float step_size = -1.0f) const;
// Default step_size = cell_size * 0.5
```

### 3.4 Pathfinding

The NavigationMap provides a full pathfinder that replaces Godot's NavigationServer.

```cpp
// Find a path from 'from' to 'to' that maintains 'clearance' from all land
// Returns an array of waypoints in world XZ coordinates
PackedVector2Array find_path(Vector2 from, Vector2 to, float clearance) const;
```

#### Algorithm: Theta* on the SDF Grid

[Theta*](http://idm-lab.org/bib/abstracts/papers/aaai07a.pdf) is chosen over standard A* because:
- It produces **any-angle paths** (not restricted to grid directions), which is critical for ships that turn in smooth arcs
- It naturally avoids the jagged staircase paths that grid-based A* produces
- It's simple to implement on a 2D grid with SDF clearance checks

**Implementation**:
1. Start and goal are snapped to the nearest navigable grid cells
2. Neighbor expansion: 8-connected grid (cardinal + diagonal)
3. Cost function: Euclidean distance
4. **Theta* line-of-sight check**: Before accepting a path through a neighbor, check if the grandparent has line-of-sight to the neighbor using `raycast(grandparent, neighbor, clearance)`. If yes, connect directly to grandparent (skipping the parent), producing a shorter, smoother path.
5. Heuristic: Euclidean distance to goal (admissible, consistent)
6. A cell is considered blocked if `sdf[cell] < clearance`

**Path simplification**:
After Theta* produces waypoints, a greedy simplification pass removes redundant intermediate points:
- For each waypoint, check if a direct `raycast` from the previous kept waypoint to the *next* waypoint clears. If yes, remove the current waypoint.
- This produces minimal waypoint paths that only turn at necessary corners around islands.

**Clearance parameter**:
The clearance passed to `find_path` should be at least `ship_beam / 2 + safety_margin`. Recommended: `ship_beam / 2 + turning_circle_radius * 0.25`. This ensures the path gives the ship enough room to execute turns without clipping land.

**Performance budget**:
- Grid is 700×700 = 490,000 cells
- Typical ocean maps have <5% land cells
- A* with a good heuristic explores ~1-5% of the grid for a cross-map path
- Expected: < 0.5ms per pathfind on modern hardware
- Paths are recalculated only when destination changes significantly (> `turning_circle_radius * 0.5`)

### 3.5 Island Data and Cover Zones

The NavigationMap stores metadata for each island detected during SDF construction.

```cpp
struct IslandData {
    int id;
    Vector2 center;        // average of all land cells belonging to this island
    float radius;          // max distance from center to any land cell (approximate)
    float area;            // number of land cells × cell_size²
    PackedVector2Array edge_points;  // sampled shoreline points (SDF ≈ 0)
};

// Get all islands
TypedArray<Dictionary> get_islands() const;

// Get island nearest to a position
Dictionary get_nearest_island(Vector2 position) const;

// Compute a cover zone behind an island relative to a threat direction
// Returns the arc of navigable water on the far side of the island from the threat
struct CoverZone {
    Vector2 center;           // island center
    float arc_start_angle;    // start of safe arc (radians, 0 = +Z)
    float arc_end_angle;      // end of safe arc
    float min_radius;         // minimum distance from island center (island edge + clearance)
    float max_radius;         // maximum useful distance
    Vector2 best_position;    // recommended position within zone
    float best_heading;       // recommended heading (broadside to threat)
    bool valid;               // false if no viable cover exists
};
CoverZone compute_cover_zone(
    int island_id,
    Vector2 threat_direction,    // unit vector from island toward threat
    float ship_clearance,        // minimum distance from land
    float min_engagement_range,  // must be able to shoot over island
    float max_engagement_range   // must be within gun range of threat
) const;
```

**Cover zone computation**:
1. From the island center, sweep angles in the hemisphere opposite the threat direction
2. For each angle, march outward from `island_radius + ship_clearance` to `max_engagement_range`
3. Check `is_navigable(point, ship_clearance)` at each step
4. The valid arc is the contiguous range of angles where navigable water exists at acceptable engagement distances
5. `best_position` is the point within the arc that maximizes distance from the threat while staying within gun range
6. `best_heading` is perpendicular to the threat bearing (broadside)

---

## 4. ShipNavigator

One `ShipNavigator` instance per bot-controlled ship. It references a shared `NavigationMap`.

### 4.1 Ship Parameters

Set once at initialization (from `ShipMovementV4` exported properties):

```cpp
struct ShipParams {
    float turning_circle_radius;   // meters, at full speed + full rudder
    float rudder_response_time;    // seconds, center to full rudder
    float acceleration_time;       // seconds, 0 to full speed
    float deceleration_time;       // seconds, full speed to 0
    float max_speed;               // m/s (already converted from knots by ShipMovementV4)
    float reverse_speed_ratio;     // fraction of max_speed when reversing
    float ship_length;             // meters
    float ship_beam;               // meters (width)
    float turn_speed_loss;         // fraction of speed lost while turning
};
```

**Reference values from existing ships**:

| Ship | Class | Turning Radius | Rudder Response | Accel Time | Max Speed (knots) | Length | Nav Size |
|------|-------|---------------|-----------------|------------|-------------------|--------|----------|
| Shimakaze | DD | 250 m | 3.5 s | 9.0 s | 41.0 | ~120 m | Light |
| Des Moines | CA | 300 m | 8.0 s | 20.0 s | 33.0 | ~218 m | Medium |
| Bismarck | BB | 400 m | 10.0 s | 40.0 s | 30.5 | ~251 m | Heavy |
| H44 | BB | 600 m | 14.0 s | 40.0 s | 30.0 | ~300 m | Ultra-Heavy |

### 4.2 Live State

Updated every physics frame by the bot controller before calling navigation:

```cpp
void set_state(
    Vector3 position,           // ship world position
    Vector3 velocity,           // ship linear velocity
    float heading,              // current heading in radians (0 = +Z, π/2 = +X)
    float angular_velocity_y,   // current yaw rate (rad/s)
    float current_rudder,       // current rudder position [-1, 1]
    float current_speed         // signed forward speed (negative = reversing)
);
```

### 4.3 Navigation Modes

#### 4.3.1 `navigate_to_position(Vector3 target)`

Move to a world position. The system:
1. Computes a path from current position to target using `NavigationMap::find_path()`
2. Selects the next waypoint along the path
3. Computes steering to reach that waypoint using arc prediction
4. Outputs rudder and throttle

**Waypoint advancement**: A waypoint is considered "reached" when the ship is within `turning_circle_radius * 0.5` of it, OR when the waypoint is behind the ship (dot product of forward vector and to-waypoint vector is negative and distance < `turning_circle_radius`).

#### 4.3.2 `navigate_to_angle(float target_heading)`

Acquire a specific heading without a position target. Used for:
- Presenting broadside to a target
- Angling armor against incoming fire
- Turning to a torpedo launch heading

The system:
1. Computes the angular difference between current heading and target
2. Determines the optimal turn direction (shortest arc that doesn't clip land)
3. Accounts for rudder lag: begins reducing rudder before reaching target heading so the ship doesn't overshoot
4. Computes the **rudder lead angle**: given current angular velocity and rudder response time, how far before the target heading to start centering the rudder

**Rudder lead calculation**:
```
// Angular velocity at current rudder
omega_current = angular_velocity_y

// Time to center rudder from current position
t_rudder = abs(current_rudder) * rudder_response_time

// Angle that will be swept during rudder centering (approximate)
// The ship continues turning as the rudder moves to center
lead_angle = omega_current * t_rudder * 0.5  // triangle approximation

// Begin centering rudder when remaining angle <= lead_angle
remaining = normalize_angle(target_heading - heading)
if abs(remaining) <= abs(lead_angle):
    command rudder toward center
else:
    command full rudder in turn direction
```

**Throttle during angle navigation**: Maintains current throttle setting by default. If the turn is large (> 90°), reduces to 1/2 throttle to tighten the turn. The behavior can override throttle via a parameter.

#### 4.3.3 `navigate_to_pose(Vector3 target, float target_heading)`

Arrive at a position facing a specific direction. This is the most complex mode, used for:
- Torpedo attack runs (arrive at launch position facing the target)
- Island cover positioning (arrive behind island facing broadside)
- Precise tactical positioning

**Algorithm — Two-phase approach**:

**Phase 1: Approach**
- Find path to target using `find_path()`
- Follow path until within `approach_radius` of target
- `approach_radius = max(turning_circle_radius * 2.0, stopping_distance * 1.5)`

**Phase 2: Terminal maneuver**
- Compute the desired arrival arc: a circular arc that ends at `target` with heading `target_heading`
- The arc center is offset from target by `turning_circle_radius` perpendicular to `target_heading`
- Two possible arcs (left turn / right turn to arrive); pick the one reachable from current position
- Follow the arc, decelerating as the ship approaches
- Transition to `navigate_to_angle` for final heading correction if position is acceptable but heading is off

**Deceleration planning**:
```
stopping_distance = current_speed² / (2.0 * max_deceleration)
max_deceleration = max_speed / deceleration_time  // approximate

// Begin decelerating when:
distance_to_target <= stopping_distance + safety_margin
```

#### 4.3.4 `station_keep(Vector3 center, float radius, float preferred_heading)`

Hold position within a circular zone, oriented toward a preferred heading. This is the **key mode for island cover** that eliminates death spirals.

**State machine**:

```
                    ┌──────────────┐
                    │   APPROACH   │
                    │              │
                    │ navigate to  │
                    │ zone edge    │
         ┌─────────┤ using pose   │
         │         │ navigation   │
         │         └──────┬───────┘
         │                │ inside zone
         │                ▼
         │         ┌──────────────┐
         │         │    SETTLE    │
         │         │              │
         │         │ reduce speed │
         │         │ align heading│
         │         └──────┬───────┘
         │                │ speed < threshold
         │                │ AND heading within tolerance
         │                ▼
         │         ┌──────────────┐
         │         │   HOLDING    │
         │         │              │
         │         │ minimal      │
         │         │ corrections  │
         │         └──────┬───────┘
         │                │ drifted outside zone
         │                ▼
         │         ┌──────────────┐
         └─────────│   RECOVER    │
                   │              │
                   │ gentle turn  │
                   │ back to zone │
                   └──────────────┘
```

**APPROACH**: Ship is outside the zone. Use `navigate_to_pose(entry_point, preferred_heading)` where `entry_point` is the nearest point on the zone boundary that is navigable and approachable from the current position without clipping land. The approach heading is chosen to align with `preferred_heading` at arrival.

**SETTLE**: Ship is inside the zone but still moving fast or misaligned.
- Throttle: Set to 0 (coast to stop) or 1 (minimum steerage) if heading needs correction
- Rudder: Gentle corrections toward `preferred_heading`, using the angle navigation lead calculation at reduced authority

**HOLDING**: Ship is inside the zone, roughly stationary, roughly aligned.
- Throttle: 0
- Rudder: Micro-corrections only (rudder authority capped at 0.3)
- **Accept any heading within ±15° of preferred** — don't chase perfection

**RECOVER**: Ship has drifted outside the zone (due to current, collision, or enemy pushing).
- Throttle: 1-2 (low speed)
- Navigate back toward zone center
- Do NOT use full speed; this prevents the oscillation/death-spiral pattern

**Key anti-death-spiral properties**:
1. **Zone tolerance**: Any position inside the radius is acceptable. No single point to overshoot.
2. **Heading tolerance**: ±15° is acceptable in HOLDING. Don't chase exact heading.
3. **Speed caps**: SETTLE and RECOVER use low throttle. The ship never approaches the zone at full speed.
4. **No re-planning on minor drift**: HOLDING accepts small deviations without re-entering APPROACH.
5. **Entry point is on the zone boundary, not the center**: The ship targets the edge, so it naturally ends up inside rather than trying to reach the far side and overshooting.

### 4.4 Arc Prediction (Core Algorithm)

The arc predictor is the heart of collision avoidance. It forward-simulates the ship's trajectory for a given rudder and throttle command.

```cpp
struct ArcPoint {
    Vector2 position;    // XZ world position
    float heading;       // heading at this point
    float speed;         // speed at this point
    float time;          // time from now
};

// Simulate trajectory for given commands
// Returns array of predicted positions
std::vector<ArcPoint> predict_arc(
    float commanded_rudder,     // [-1, 1]
    float commanded_throttle,   // [-1, 4]
    float lookahead_time,       // seconds to simulate
    float time_step             // simulation step (default 0.25s)
) const;
```

**Simulation model**:

The predictor uses a simplified kinematic model derived from `ShipMovementV4`'s force model. It doesn't need to be perfectly accurate — it needs to be conservative (predict slightly wider turns than reality).

```
// Per time step:

// 1. Rudder moves toward commanded position
rudder = move_toward(rudder, commanded_rudder, dt / rudder_response_time)

// 2. Speed changes toward target
target_speed = throttle_to_speed(commanded_throttle)
if target_speed > current_speed:
    speed = move_toward(speed, target_speed, dt * max_speed / acceleration_time)
else:
    speed = move_toward(speed, target_speed, dt * max_speed / deceleration_time)

// 3. Apply turn speed loss
effective_speed = speed * (1.0 - turn_speed_loss * abs(rudder))

// 4. Compute turn rate from speed and turning circle
// omega = v / R at full rudder; scale by rudder fraction
omega = (effective_speed / turning_circle_radius) * rudder

// 5. Integrate
heading += omega * dt
position.x += sin(heading) * effective_speed * dt
position.z += cos(heading) * effective_speed * dt
```

**Conservative margin**: The predicted arc is tested against the SDF with a clearance of `ship_beam * 0.5 + safety_margin` where `safety_margin` is `max(50.0, ship_beam * 0.25)`. This means the prediction is conservative — the ship will start avoiding terrain earlier than strictly necessary.

### 4.5 Steering Computation

The steering algorithm selects the best `(rudder, throttle)` pair to achieve the current navigation goal while avoiding collisions.

```cpp
struct SteeringResult {
    float rudder;           // [-1, 1]
    int throttle;           // [-1, 4]
    bool collision_imminent; // true if evasive action was taken
    float time_to_collision; // seconds until predicted collision (INF if none)
};

SteeringResult compute_steering() const;
```

**Algorithm**:

1. **Compute desired rudder** from the current navigation mode:
   - Position nav: rudder toward next waypoint, proportional to angle error
   - Angle nav: rudder toward target heading with lead compensation
   - Pose nav: blend of position and angle based on phase
   - Station keep: depends on sub-state (APPROACH/SETTLE/HOLDING/RECOVER)

2. **Check desired trajectory for collision**:
   - Run `predict_arc(desired_rudder, desired_throttle, lookahead_time)` where `lookahead_time` scales with speed: `max(5.0, current_speed / max_deceleration * 2.0)`
   - Test each arc point against SDF: `is_navigable(point.x, point.z, clearance)`

3. **If collision detected on desired trajectory**:
   - **Try alternative rudders**: Sample rudder values in both directions from desired: `[desired ± 0.25, desired ± 0.5, desired ± 0.75, ±1.0]`
   - For each candidate, predict arc and check collision
   - Select the collision-free candidate closest to the desired rudder
   - If no collision-free rudder exists at current speed:
     a. Reduce throttle and retry
     b. If still no solution, command reverse + rudder away from nearest land (emergency)

4. **Throttle modulation**:
   - If approaching a waypoint turn: reduce throttle based on angle of turn and distance
   - If approaching destination: decelerate per stopping distance calculation
   - If collision avoidance is active: cap throttle at 2 (half speed)
   - If emergency avoidance: throttle = -1 (reverse)

5. **SDF gradient push**:
   - If the ship is within `clearance * 1.5` of land, apply a heading bias away from land using `get_gradient()`
   - This provides a soft "repulsion" layer before hard collision avoidance kicks in
   - Bias strength: `rudder_bias = gradient_direction * (1.0 - distance / (clearance * 1.5)) * 0.3`

### 4.6 Dynamic Obstacles (Ship Avoidance)

Other ships are registered as moving obstacles for prediction purposes.

```cpp
void register_obstacle(int id, Vector2 position, Vector2 velocity, float radius);
void remove_obstacle(int id);
void update_obstacle(int id, Vector2 position, Vector2 velocity);
```

During arc prediction, each arc point is also tested against predicted positions of other ships:
```
obstacle_pos_at_time = obstacle.position + obstacle.velocity * arc_point.time
if distance(arc_point.position, obstacle_pos_at_time) < clearance + obstacle.radius:
    collision detected
```

This is lighter-weight than a full ORCA/RVO system but sufficient for the sparse ship environment. The behavior layer can also use this to request heading changes for formation keeping.

### 4.7 Map Boundary Handling

The navigator enforces the existing `MAP_BOUNDARY = 17500.0` constraint. The SDF grid is bounded to this region, and cells outside the map are treated as walls (distance = 0), preventing ships from pathing outside the playable area.

---

## 5. Bot Controller V4 (GDScript)

`bot_controller_v4.gd` replaces `bot_controller_v3.gd`. It uses `ShipNavigator` instead of `NavigationAgent3D` + proxy + raycasts.

### 5.1 Structure

```gdscript
extends Node
class_name BotControllerV4

var _ship: Ship
var navigator: ShipNavigator      # C++ instance
var behavior: BotBehavior          # unchanged — BB/CA/DD behaviors
var server_node: GameServer
var movement: ShipMovementV4

var target: Ship
var destination: Vector3

# Debug
var debug_draw: bool = true
```

### 5.2 Initialization

```gdscript
func _ready():
    navigator = ShipNavigator.new()
    navigator.set_map(NavigationMapManager.get_map())  # shared singleton
    navigator.set_ship_params(
        movement.turning_circle_radius,
        movement.rudder_response_time,
        movement.acceleration_time,
        movement.deceleration_time,
        movement.max_speed,
        movement.reverse_speed_ratio,
        movement.ship_length,
        movement.ship_beam,
        movement.turn_speed_loss
    )
```

No `NavigationAgent3D`, no `Node3D` proxy, no assignment to nav regions by size class.

### 5.3 Per-Frame Update

```gdscript
func _physics_process(delta):
    # 1. Update navigator state from physics
    navigator.set_state(
        _ship.global_position,
        _ship.linear_velocity,
        get_ship_heading(),
        _ship.angular_velocity.y,
        movement.rudder_input,
        get_current_speed()
    )

    # 2. Register nearby ships as obstacles
    _update_obstacles()

    # 3. Get navigation intent from behavior
    var intent = behavior.get_nav_intent(target, _ship, server_node)

    # 4. Execute navigation intent
    match intent.mode:
        NavIntent.POSITION:
            navigator.navigate_to_position(intent.target_position)
        NavIntent.ANGLE:
            navigator.navigate_to_angle(intent.target_heading)
        NavIntent.POSE:
            navigator.navigate_to_pose(intent.target_position, intent.target_heading)
        NavIntent.STATION_KEEP:
            navigator.station_keep(intent.zone_center, intent.zone_radius, intent.preferred_heading)

    # 5. Read steering output
    var rudder = navigator.get_rudder()
    var throttle = navigator.get_throttle()

    # 6. Apply behavior speed modifier (DD evasion etc.)
    throttle = int(throttle * behavior.get_speed_multiplier())

    # 7. Send to movement controller
    movement.set_movement_input([throttle, rudder])

    # 8. Behavior tick (target scanning, firing, consumables)
    _tick_behavior(delta)
```

### 5.4 NavIntent Structure

A lightweight struct returned by behaviors to describe what navigation mode and target to use.

```gdscript
class NavIntent:
    enum Mode { POSITION, ANGLE, POSE, STATION_KEEP }

    var mode: Mode
    var target_position: Vector3    # for POSITION, POSE, STATION_KEEP
    var target_heading: float       # for ANGLE, POSE, STATION_KEEP
    var zone_radius: float          # for STATION_KEEP
    var zone_center: Vector3        # for STATION_KEEP
```

### 5.5 Behavior Changes

The existing behaviors (`BBBehavior`, `CABehavior`, `DDBehavior`) need minimal changes. Their `get_desired_position()` methods are replaced with `get_nav_intent()` that returns a `NavIntent` instead of a raw `Vector3`.

**BBBehavior**:
```gdscript
func get_nav_intent(target, ship, server) -> NavIntent:
    var position = _calculate_engagement_position(...)
    var heading = _calculate_broadside_heading(target)
    return NavIntent.new(NavIntent.POSE, position, heading)
```

**CABehavior** (island cover):
```gdscript
func get_nav_intent(target, ship, server) -> NavIntent:
    var island = _find_best_island(...)
    if island != null:
        var cover = navigator_map.compute_cover_zone(island.id, threat_dir, clearance, ...)
        if cover.valid:
            return NavIntent.new(NavIntent.STATION_KEEP,
                cover.best_position, cover.zone_radius, cover.best_heading)

    # Fallback to kiting
    var position = _calculate_kite_position(...)
    var heading = _calculate_angled_heading(target)
    return NavIntent.new(NavIntent.POSE, position, heading)
```

**DDBehavior**:
```gdscript
func get_nav_intent(target, ship, server) -> NavIntent:
    if _preparing_torpedo_run():
        var launch_pos = _calculate_torpedo_launch_position(target)
        var launch_heading = _calculate_torpedo_heading(target)
        return NavIntent.new(NavIntent.POSE, launch_pos, launch_heading)
    elif _retreating():
        return NavIntent.new(NavIntent.POSITION, _calculate_retreat_position())
    else:
        return NavIntent.new(NavIntent.POSITION, _calculate_flank_position(target))
```

### 5.6 What Gets Removed

The following systems become unnecessary with the new navigator:

| Removed | Reason |
|---------|--------|
| `NavigationAgent3D` per bot | Replaced by `ShipNavigator` |
| `Node3D` navigation proxy | No proxy needed |
| `assign_nav_agent()` / nav region assignment by size class | SDF uses clearance parameter instead of per-class meshes |
| `light_nav`, `medium_nav`, `heavy_nav`, `superheavy_nav`, `ultraheavy_nav` nodes in `map.tscn` | SDF replaces all nav meshes |
| `get_threat_vector()` with 16 raycasts | Arc prediction + SDF replaces reactive raycasting |
| Grounded recovery state machine in `BotControllerV3` | Navigator prevents grounding proactively |
| `_get_valid_nav_point()` / `NavigationServer3D.map_get_closest_point()` calls in behaviors | `NavigationMap.find_path()` handles this |
| `Map.preprocess_islands()` / `Map.find_island_edge_points()` | `NavigationMap` builds island data from collision shapes directly |

---

## 6. NavigationMapManager (Singleton)

A GDScript autoload or static access point that manages the shared `NavigationMap` instance.

```gdscript
# NavigationMapManager.gd (autoload)
extends Node

var _map: NavigationMap = null

func build_map(island_bodies: Array[StaticBody3D], map_bounds: Rect2):
    _map = NavigationMap.new()
    _map.set_bounds(map_bounds.position.x, map_bounds.position.y,
                    map_bounds.end.x, map_bounds.end.y)
    _map.set_cell_size(50.0)
    _map.build_from_collision_shapes(island_bodies)

func get_map() -> NavigationMap:
    return _map
```

Called once from `server.gd` or `game_world.gd` after the map loads:

```gdscript
# In server.gd, after map is loaded:
var map_node = get_node("GameWorld/Env").get_child(0) as Map
NavigationMapManager.build_map(map_node.islands,
    Rect2(-17500, -17500, 35000, 35000))
```

---

## 7. C++ Implementation Plan

### 7.1 File Structure

All files go in `gdextension/ships_core/src/`:

```
navigation_map.h          — NavigationMap class declaration
navigation_map.cpp        — SDF construction, queries, pathfinding, island analysis

ship_navigator.h          — ShipNavigator class declaration
ship_navigator.cpp         — Arc prediction, steering, navigation modes, state machine

nav_types.h               — Shared structs (ArcPoint, RayResult, CoverZone, IslandData, SteeringResult)

register_types.cpp        — Add GDREGISTER_CLASS for new classes (modify existing)
```

### 7.2 Class Registration

Add to existing `register_types.cpp`:

```cpp
#include "navigation_map.h"
#include "ship_navigator.h"

// In initialize_ships_core_module():
GDREGISTER_CLASS(NavigationMap);
GDREGISTER_CLASS(ShipNavigator);
```

### 7.3 GDExtension API Surface

#### NavigationMap

```cpp
class NavigationMap : public RefCounted {
    GDCLASS(NavigationMap, RefCounted);

protected:
    static void _bind_methods();

public:
    // Construction
    void set_bounds(float min_x, float min_z, float max_x, float max_z);
    void set_cell_size(float size);
    void build_from_collision_shapes(TypedArray<Node3D> island_bodies);

    // Core SDF queries
    float get_distance(float x, float z) const;
    Vector2 get_gradient(float x, float z) const;
    bool is_navigable(float x, float z, float clearance) const;

    // Raycasting
    Dictionary raycast(Vector2 from, Vector2 to, float clearance) const;

    // Pathfinding
    PackedVector2Array find_path(Vector2 from, Vector2 to, float clearance) const;

    // Island data
    TypedArray<Dictionary> get_islands() const;
    Dictionary get_nearest_island(Vector2 position) const;
    Dictionary compute_cover_zone(
        int island_id,
        Vector2 threat_direction,
        float ship_clearance,
        float min_engagement_range,
        float max_engagement_range
    ) const;

    // Debug
    PackedFloat32Array get_sdf_data() const;  // raw grid for visualization
    int get_grid_width() const;
    int get_grid_height() const;
};
```

#### ShipNavigator

```cpp
class ShipNavigator : public RefCounted {
    GDCLASS(ShipNavigator, RefCounted);

protected:
    static void _bind_methods();

public:
    // Setup
    void set_map(Ref<NavigationMap> map);
    void set_ship_params(
        float turning_circle_radius,
        float rudder_response_time,
        float acceleration_time,
        float deceleration_time,
        float max_speed,
        float reverse_speed_ratio,
        float ship_length,
        float ship_beam,
        float turn_speed_loss
    );

    // Per-frame state update
    void set_state(
        Vector3 position,
        Vector3 velocity,
        float heading,
        float angular_velocity_y,
        float current_rudder,
        float current_speed
    );

    // Navigation commands
    void navigate_to_position(Vector3 target);
    void navigate_to_angle(float target_heading);
    void navigate_to_pose(Vector3 target, float target_heading);
    void station_keep(Vector3 center, float radius, float preferred_heading);
    void stop();  // cancel navigation, coast to stop

    // Output (read after calling a navigation command)
    float get_rudder() const;
    int get_throttle() const;
    int get_nav_state() const;     // enum: IDLE, NAVIGATING, ARRIVING, HOLDING, AVOIDING, EMERGENCY
    bool is_collision_imminent() const;
    float get_time_to_collision() const;

    // Dynamic obstacles
    void register_obstacle(int id, Vector2 position, Vector2 velocity, float radius);
    void update_obstacle(int id, Vector2 position, Vector2 velocity);
    void remove_obstacle(int id);
    void clear_obstacles();

    // Path info
    PackedVector3Array get_current_path() const;       // current planned path
    PackedVector3Array get_predicted_trajectory() const; // predicted arc from current steering
    Vector3 get_current_waypoint() const;              // current target waypoint

    // Debug
    float get_desired_heading() const;
    float get_distance_to_destination() const;
    String get_debug_info() const;
};
```

### 7.4 Internal Data Structures

```cpp
// nav_types.h

struct ArcPoint {
    Vector2 position;
    float heading;
    float speed;
    float time;
};

struct PathResult {
    std::vector<Vector2> waypoints;
    float total_distance;
    bool valid;
};

struct IslandData {
    int id;
    Vector2 center;
    float radius;
    float area;
    std::vector<Vector2> edge_points;
};

struct CoverZone {
    Vector2 center;
    float arc_start;
    float arc_end;
    float min_radius;
    float max_radius;
    Vector2 best_position;
    float best_heading;
    bool valid;
};

enum class NavState {
    IDLE,
    NAVIGATING,       // following path to waypoint
    ARRIVING,         // decelerating near destination
    TURNING,          // executing angle-only navigation
    STATION_APPROACH, // heading to station-keep zone
    STATION_SETTLE,   // slowing down inside zone
    STATION_HOLDING,  // maintaining position in zone
    STATION_RECOVER,  // drifted out of zone, returning
    AVOIDING,         // collision avoidance override active
    EMERGENCY,        // emergency reverse/evasion
};

enum class NavMode {
    NONE,
    POSITION,
    ANGLE,
    POSE,
    STATION_KEEP,
};
```

---

## 8. Debug Visualization

The system provides data for debug visualization rendered from GDScript (consistent with existing debug drawing in the bot controller).

### 8.1 Available Debug Data

| Method | Returns | Visualization |
|--------|---------|---------------|
| `get_predicted_trajectory()` | PackedVector3Array | Green line showing predicted ship path |
| `get_current_path()` | PackedVector3Array | Blue line showing planned path waypoints |
| `get_current_waypoint()` | Vector3 | Yellow sphere at current waypoint |
| `get_desired_heading()` | float | Arrow showing desired heading direction |
| `get_nav_state()` | int | Text label showing current state name |
| `NavigationMap.get_sdf_data()` | PackedFloat32Array | Heatmap overlay showing SDF distances |
| `NavigationMap.get_islands()` | Array[Dictionary] | Circle overlays showing island bounds |
| `is_collision_imminent()` | bool | Red flash when avoidance is active |

### 8.2 Minimap Integration

The SDF data can be rendered as a texture on the minimap to show navigable water vs land, replacing the static map background. This also helps verify SDF accuracy visually.

---

## 9. Performance Analysis

### 9.1 Per-Frame Costs

| Operation | Frequency | Cost | Notes |
|-----------|-----------|------|-------|
| `set_state()` | Every frame, per bot | O(1) | Copies ~6 floats |
| `predict_arc()` | Every frame, per bot | O(N) | N = lookahead_time / time_step ≈ 20-40 samples |
| SDF lookup per arc point | 20-40 per bot per frame | O(1) each | Bilinear interpolation = 4 lookups + 2 lerps |
| `find_path()` | On destination change only | O(V log V) | Theta* on 700×700 grid; typically < 0.5ms |
| Obstacle checks | Per arc point × num obstacles | O(N × M) | N = arc points, M = nearby obstacles |
| `compute_cover_zone()` | On island selection change | O(K) | K = angular sweep samples ≈ 36 |

**Total per-bot per-frame**: ~50-100 SDF lookups + simple math ≈ **< 0.05 ms** per bot.

For 18 bots (typical match): **< 1 ms** total per physics frame.

### 9.2 Comparison with Current System

| Metric | Current (NavMesh + Raycasts) | New (SDF + Arc Prediction) |
|--------|------------------------------|----------------------------|
| Terrain collision queries | 16 physics raycasts / bot / ~4 frames | 20-40 SDF lookups / bot / frame (no physics engine) |
| Pathfinding | NavServer recalc on destination change | Theta* on destination change |
| Memory | ~5 NavMesh regions × vertex data | ~2 MB SDF grid |
| Grounding prevention | Reactive (detect + recover) | Proactive (predict + avoid) |
| Island cover | Single-point destination | Zone-based station keeping |
| Code complexity | ~1800 lines GDScript (bot_controller.gd) | ~800 lines GDScript + ~2500 lines C++ |

### 9.3 Memory Budget

| Data | Size | Lifetime |
|------|------|----------|
| SDF grid (700×700 float) | 1.96 MB | Map lifetime (shared) |
| Island metadata (~20 islands) | ~50 KB | Map lifetime (shared) |
| Per-navigator state | ~500 bytes | Per bot |
| Per-navigator path cache | ~2 KB typical | Per bot |
| Per-navigator arc buffer | ~1 KB | Per bot, reused each frame |
| Obstacle registry | ~100 bytes/obstacle | Per bot |

**Total for 18 bots on one map**: ~2.1 MB shared + ~70 KB per-bot = **~3.4 MB**

---

## 10. Testing Strategy

### 10.1 Unit Tests (C++)

- SDF construction: verify distances match analytical solutions for simple shapes (circle island, square island)
- SDF queries: bilinear interpolation accuracy
- Pathfinding: known obstacle configurations with expected paths
- Arc prediction: verify predicted positions match `ShipMovementV4` physics within tolerance
- Cover zone: verify zones are computed on the correct side of islands

### 10.2 Integration Tests (GDScript)

- Spawn a bot, give it a destination behind an island, verify it navigates around without grounding
- Spawn a bot, command station_keep at an island cover position, verify it settles without death-spiraling
- Spawn a bot in a narrow channel between two islands, verify it navigates through
- Spawn a bot, command navigate_to_angle for broadside, verify it achieves the heading within tolerance
- Spawn a bot near land, verify collision avoidance activates before grounding

### 10.3 Regression: Compare with V3

- Run a full match with all bots using V4; count grounding events (should be 0)
- Measure frame time with 18 bots; should be lower than V3
- Visually verify bots using island cover no longer spiral

---

## 11. Migration Path

### Phase 1: Build NavigationMap + ShipNavigator (C++)
- Implement core SDF, pathfinding, arc prediction
- Register in GDExtension
- Test standalone with hardcoded scenarios

### Phase 2: Create bot_controller_v4.gd
- Implement per-frame loop using ShipNavigator
- Add NavIntent interface
- Test with a single bot class (BB — simplest behavior)

### Phase 3: Migrate Behaviors
- Add `get_nav_intent()` to BotBehavior base class
- Migrate BBBehavior → verify engagement positioning + broadside angle
- Migrate CABehavior → verify island cover with station_keep
- Migrate DDBehavior → verify torpedo runs with pose navigation

### Phase 4: Integrate and Clean Up
- Switch `server.gd` to instantiate `bot_controller_v4.tscn`
- Build NavigationMap in `server.gd` at map load
- Remove NavMesh regions from `map.tscn`
- Remove `bot_controller_v3.gd` and `bot_controller.gd`
- Remove `Map.preprocess_islands()` and related code
- Update debug visualization

### Phase 5: Polish
- Tune parameters per ship class
- Add minimap SDF overlay
- Performance profiling and optimization
- Edge case handling (map boundaries, all-land, spawn positions near islands)

---

## 12. Open Questions / Future Considerations

1. **Multi-resolution SDF**: For very large maps or maps with narrow straits, a two-level SDF (coarse + fine near shorelines) could improve accuracy without increasing memory. Deferred unless needed.

2. **Current / wind forces**: If environmental forces are added later, the arc predictor can incorporate them by adding a drift term to the integration step.

3. **Formation navigation**: Multiple ships maintaining relative positions. The obstacle registration system provides the foundation; a formation layer on top of NavIntent could be added later.

4. **Player ship assistance**: The navigator could optionally provide collision warnings or auto-avoidance for player-controlled ships (configurable).

5. **Dynamic map changes**: If destructible terrain is added, the SDF would need partial rebuilds. The grid structure supports efficient local updates.

6. **Reverse navigation**: Some tight situations may require the ship to reverse out. The current emergency mode handles this reactively. A more sophisticated planner could use reverse arcs proactively, but this is low priority since ocean environments rarely require tight maneuvering.