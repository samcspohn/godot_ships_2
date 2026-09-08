use godot::prelude::*;
use std::cmp::{Ordering, Reverse};
use std::collections::BinaryHeap;
use std::f64::consts::{PI, TAU};

/// Forward-simulated ship trajectory point (used by short-range arc prediction).
#[derive(Clone, Copy, Debug)]
pub struct ArcPoint {
    pub position: Vector2, // XZ world position
    pub heading: f32,      // radians, 0 = +Z, PI/2 = +X
    pub speed: f32,        // m/s
    pub time: f32,         // seconds from simulation start
}

impl Default for ArcPoint {
    fn default() -> Self {
        Self { position: Vector2::ZERO, heading: 0.0, speed: 0.0, time: 0.0 }
    }
}

impl ArcPoint {
    pub fn new(position: Vector2, heading: f32, speed: f32, time: f32) -> Self {
        Self { position, heading, speed, time }
    }
}

/// Per-waypoint metadata flags. Bitmask, not an enum.
pub mod waypoint_flags {
    pub const WP_NONE: u8 = 0;
    pub const WP_REVERSE: u8 = 1 << 0; // Ship should reverse through this segment
    pub const WP_REVERSE_SEGMENT: u8 = WP_REVERSE;
    pub const WP_SMOOTHED: u8 = 1 << 1; // Inserted by Catmull-Rom smoothing
    pub const WP_DEPARTURE: u8 = 1 << 2; // Departure/recovery waypoint
}

#[derive(Clone, Debug, Default)]
pub struct PathResult {
    pub waypoints: Vec<Vector2>,
    pub flags: Vec<u8>, // parallel to waypoints
    pub total_distance: f32,
    pub valid: bool,
}

/// Island metadata extracted from the SDF.
#[derive(Clone, Debug)]
pub struct IslandData {
    pub id: i32,
    pub center: Vector2,             // average of all land cells
    pub radius: f32,                 // max distance from center to any land cell
    pub area: f32,                   // land cell count * cell_size^2
    pub max_height: f32,             // tallest terrain Y on the island
    pub edge_points: Vec<Vector2>,   // sampled shoreline points (SDF ~ 0)
}

impl Default for IslandData {
    fn default() -> Self {
        Self {
            id: -1,
            center: Vector2::ZERO,
            radius: 0.0,
            area: 0.0,
            max_height: 0.0,
            edge_points: Vec::new(),
        }
    }
}

impl IslandData {
    pub fn to_dictionary(&self) -> VarDictionary {
        let mut dict = VarDictionary::new();
        dict.set("id", self.id);
        dict.set("center", self.center);
        dict.set("radius", self.radius);
        dict.set("area", self.area);
        dict.set("max_height", self.max_height);
        let mut edges = PackedVector2Array::new();
        for pt in &self.edge_points {
            edges.push(*pt);
        }
        dict.set("edge_points", &edges);
        dict
    }
}

/// Cover zone behind an island relative to a threat direction.
#[derive(Clone, Copy, Debug)]
pub struct CoverZone {
    pub center: Vector2,        // island center
    pub arc_start: f32,         // radians, 0 = +Z
    pub arc_end: f32,
    pub min_radius: f32,        // island edge + clearance
    pub max_radius: f32,
    pub best_position: Vector2,
    pub best_heading: f32,      // broadside to threat
    pub valid: bool,            // false if no viable cover exists
}

impl Default for CoverZone {
    fn default() -> Self {
        Self {
            center: Vector2::ZERO,
            arc_start: 0.0,
            arc_end: 0.0,
            min_radius: 0.0,
            max_radius: 0.0,
            best_position: Vector2::ZERO,
            best_heading: 0.0,
            valid: false,
        }
    }
}

impl CoverZone {
    pub fn to_dictionary(&self) -> VarDictionary {
        let mut dict = VarDictionary::new();
        dict.set("center", self.center);
        dict.set("arc_start_angle", self.arc_start);
        dict.set("arc_end_angle", self.arc_end);
        dict.set("min_radius", self.min_radius);
        dict.set("max_radius", self.max_radius);
        dict.set("best_position", self.best_position);
        dict.set("best_heading", self.best_heading);
        dict.set("valid", self.valid);
        dict
    }
}

/// SDF ray march result.
#[derive(Clone, Copy, Debug)]
pub struct RayResult {
    pub hit: bool,
    pub position: Vector2, // world XZ of first violation
    pub distance: f32,     // distance along ray to violation
    pub penetration: f32,  // how far into the unsafe zone
}

impl Default for RayResult {
    fn default() -> Self {
        Self { hit: false, position: Vector2::ZERO, distance: 0.0, penetration: 0.0 }
    }
}

/// Ship kinematic parameters (set once from ShipMovementV4).
#[derive(Clone, Copy, Debug)]
pub struct ShipParams {
    pub turning_circle_radius: f32, // meters, at full speed + full rudder
    pub rudder_response_time: f32,  // seconds, center to full rudder
    pub acceleration_time: f32,     // seconds, 0 to full speed
    pub deceleration_time: f32,     // seconds, full speed to 0
    pub max_speed: f32,             // m/s (already converted from knots)
    pub reverse_speed_ratio: f32,   // fraction of max_speed when reversing
    pub ship_length: f32,
    pub ship_beam: f32,
    pub turn_speed_loss: f32,       // fraction of speed lost while turning
    pub linear_drag: f32,
}

impl Default for ShipParams {
    fn default() -> Self {
        Self {
            turning_circle_radius: 300.0,
            rudder_response_time: 5.0,
            acceleration_time: 20.0,
            deceleration_time: 10.0,
            max_speed: 15.0,
            reverse_speed_ratio: 0.5,
            ship_length: 200.0,
            ship_beam: 25.0,
            turn_speed_loss: 0.2,
            linear_drag: 0.3,
        }
    }
}

/// Live ship state (updated every physics frame).
#[derive(Clone, Copy, Debug)]
pub struct ShipState {
    pub position: Vector2,
    pub velocity: Vector2,
    pub heading: f32,            // radians, 0 = +Z, PI/2 = +X
    pub angular_velocity_y: f32, // yaw rate (rad/s)
    pub current_rudder: f32,     // [-1, 1]
    pub current_speed: f32,      // signed; negative = reversing
}

impl Default for ShipState {
    fn default() -> Self {
        Self {
            position: Vector2::ZERO,
            velocity: Vector2::ZERO,
            heading: 0.0,
            angular_velocity_y: 0.0,
            current_rudder: 0.0,
            current_speed: 0.0,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct SteeringResult {
    pub rudder: f32,             // [-1, 1]
    pub throttle: i32,           // [-1, 4]
    pub collision_imminent: bool,
    pub time_to_collision: f32,  // INF if none
}

impl Default for SteeringResult {
    fn default() -> Self {
        Self {
            rudder: 0.0,
            throttle: 0,
            collision_imminent: false,
            time_to_collision: f32::INFINITY,
        }
    }
}

/// Torpedoes are identified by two criteria that must both hold: an ID below
/// this threshold, and zero length. Both guards together prevent a false
/// positive if a ship somehow gets a low instance ID.
pub const TORPEDO_ID_THRESHOLD: i32 = -1000;

/// Dynamic obstacle (other ships or torpedoes).
#[derive(Clone, Copy, Debug)]
pub struct DynamicObstacle {
    pub id: i32,
    pub position: Vector2,
    pub velocity: Vector2,
    pub radius: f32,  // half-beam; used as circular radius for torpedoes
    pub length: f32,  // full ship length; 0 = torpedo
    pub heading: f32, // bow direction, forward = (sin h, cos h)
}

impl Default for DynamicObstacle {
    fn default() -> Self {
        Self {
            id: -1,
            position: Vector2::ZERO,
            velocity: Vector2::ZERO,
            radius: 0.0,
            length: 0.0,
            heading: 0.0,
        }
    }
}

impl DynamicObstacle {
    pub fn new(id: i32, position: Vector2, velocity: Vector2, radius: f32, length: f32) -> Self {
        let vlen = (velocity.x * velocity.x + velocity.y * velocity.y).sqrt();
        let heading = if vlen > 0.5 { velocity.x.atan2(velocity.y) } else { 0.0 };
        Self { id, position, velocity, radius, length, heading }
    }

    pub fn is_torpedo(&self) -> bool {
        self.id < TORPEDO_ID_THRESHOLD && self.length == 0.0
    }
}

/// Result of an obstacle collision check.
#[derive(Clone, Copy, Debug)]
pub struct ObstacleCollisionInfo {
    pub has_collision: bool,
    pub time_to_collision: f32,   // time along arc to first collision
    pub obstacle_id: i32,
    pub relative_bearing: f32,    // radians relative to our heading, + = starboard
    pub obstacle_length: f32,     // for size priority
    pub obstacle_position: Vector2,
    pub obstacle_velocity: Vector2,
    pub is_torpedo: bool,
}

impl Default for ObstacleCollisionInfo {
    fn default() -> Self {
        Self {
            has_collision: false,
            time_to_collision: f32::INFINITY,
            obstacle_id: -1,
            relative_bearing: 0.0,
            obstacle_length: 0.0,
            obstacle_position: Vector2::ZERO,
            obstacle_velocity: Vector2::ZERO,
            is_torpedo: false,
        }
    }
}

/// Incoming shell threat data (for shell dodging/angling).
#[derive(Clone, Copy, Debug)]
pub struct IncomingShell {
    pub id: i32,
    pub landing_pos: Vector2,   // predicted XZ impact point
    pub landing_dir: Vector2,   // normalized XZ travel direction at impact
    pub threat_half_len: f32,   // steeper = shorter
    pub time_remaining: f32,    // real seconds until impact
    pub caliber: f32,           // mm, for damage-weight prioritisation
}

impl Default for IncomingShell {
    fn default() -> Self {
        Self {
            id: -1,
            landing_pos: Vector2::ZERO,
            landing_dir: Vector2::new(1.0, 0.0),
            threat_half_len: 15.0,
            time_remaining: 0.0,
            caliber: 0.0,
        }
    }
}

impl IncomingShell {
    pub fn new(
        id: i32,
        landing_pos: Vector2,
        time_remaining: f32,
        caliber: f32,
        landing_dir: Vector2,
        threat_half_len: f32,
    ) -> Self {
        Self { id, landing_pos, landing_dir, threat_half_len, time_remaining, caliber }
    }
}

/// Navigation state machine — simplified two-state design.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum NavState {
    Normal = 0,    // Path following + weighted avoidance blending
    Emergency = 1, // Grounded or critical — SDF gradient escape
}

/// Navigation target — the single struct replacing scattered target fields.
#[derive(Clone, Copy, Debug)]
pub struct NavTarget {
    pub position: Vector2,
    pub heading: f32,           // desired heading on arrival (radians)
    pub hold_radius: f32,       // 0 = arrive and stop, >0 = station-keep
    pub heading_tolerance: f32, // radians
    pub heading_weight: f32,    // 0 = normal nav, 1 = purely pursue this heading
    pub prefer_reverse: bool,
}

impl Default for NavTarget {
    fn default() -> Self {
        Self {
            position: Vector2::ZERO,
            heading: 0.0,
            hold_radius: 0.0,
            heading_tolerance: 0.2618,
            heading_weight: 0.0,
            prefer_reverse: false,
        }
    }
}

/// Per-enemy circular threat zone. `radius` is already the effective value
/// (bin_radius * decay), ready to use.
#[derive(Clone, Copy, Debug)]
pub struct ThreatCircle {
    pub enemy_id: i32, // ship instance ID; -1 = unidentified
    pub origin: Vector2,
    pub radius: f32,   // effective detection radius in world metres
}

impl Default for ThreatCircle {
    fn default() -> Self {
        Self { enemy_id: -1, origin: Vector2::ZERO, radius: 0.0 }
    }
}

impl ThreatCircle {
    pub fn new(enemy_id: i32, origin: Vector2, radius: f32) -> Self {
        Self { enemy_id, origin, radius }
    }
}

// --- Math utilities ---
//
// PI/TAU are `double` in godot-cpp, so these float expressions promote to f64
// and narrow back on assignment. Keeping that shape matters for bit-exactness.

pub fn normalize_angle(angle: f32) -> f32 {
    let mut angle = angle;
    while (angle as f64) > PI {
        angle = (angle as f64 - TAU) as f32;
    }
    while (angle as f64) < -PI {
        angle = (angle as f64 + TAU) as f32;
    }
    angle
}

pub fn angle_difference(from: f32, to: f32) -> f32 {
    normalize_angle(to - from)
}

pub fn move_toward_f(current: f32, target: f32, max_delta: f32) -> f32 {
    if (target - current).abs() <= max_delta {
        return target;
    }
    current + if target > current { max_delta } else { -max_delta }
}

pub fn lerp_f(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

pub fn clamp_f(value: f32, min_val: f32, max_val: f32) -> f32 {
    if value < min_val {
        return min_val;
    }
    if value > max_val {
        return max_val;
    }
    value
}

/// Throttle level [-1, 4] to speed fraction [0, 1] (negative for reverse).
/// Matches ShipMovementV4 throttle_settings: [-0.5, 0.0, 0.25, 0.5, 0.75, 1.0].
pub fn throttle_to_speed_fraction(throttle: i32) -> f32 {
    match throttle {
        -1 => -0.5,
        0 => 0.0,
        1 => 0.25,
        2 => 0.5,
        3 => 0.75,
        4 => 1.0,
        _ => 0.0,
    }
}

/// A* open-set entry.
///
/// The C++ uses `priority_queue<pair<float,int>, ..., greater<>>`, whose
/// comparator is lexicographic over (f_score, cell_index). That is a total
/// order, so pop order is fully determined — ties are broken by cell index on
/// both sides and no ordering ambiguity survives translation.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PqEntry(pub f32, pub i32);

impl Eq for PqEntry {}

impl Ord for PqEntry {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.total_cmp(&other.0).then(self.1.cmp(&other.1))
    }
}

impl PartialOrd for PqEntry {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// Resumable A* search state — one per ship for async pathfinding.
/// Buffers are allocated once (matching grid size) and reused via generation
/// counters.
pub struct PathSearch {
    pub g_cost: Vec<f32>,
    pub parent: Vec<i32>,
    pub parent_dir: Vec<i8>,
    pub open_gen: Vec<u32>,
    pub closed_gen: Vec<u32>,
    pub current_gen: u32,

    /// `Reverse` turns Rust's max-heap into the C++ min-heap.
    pub open_set: BinaryHeap<Reverse<PqEntry>>,

    // Search parameters (set by begin_path_search)
    pub sx: i32,
    pub sz: i32,
    pub ex: i32,
    pub ez: i32,
    pub start_idx: i32,
    pub end_idx: i32,
    pub grid_width: i32,
    pub grid_height: i32,
    pub clearance_world: f32,
    pub turning_radius: f32,
    pub cell_size: f32,

    // World coords for path reconstruction
    pub from: Vector2,
    pub to: Vector2,
    pub clearance: f32, // original clearance param (for post-processing)

    // Progress tracking
    pub iterations: i32,
    pub max_iterations: i32,
    pub found: bool,
    pub active: bool,
    pub complete: bool,

    /// Set by begin if a LOS path was found.
    pub result: PathResult,
}

impl Default for PathSearch {
    fn default() -> Self {
        Self {
            g_cost: Vec::new(),
            parent: Vec::new(),
            parent_dir: Vec::new(),
            open_gen: Vec::new(),
            closed_gen: Vec::new(),
            current_gen: 0,
            open_set: BinaryHeap::new(),
            sx: 0,
            sz: 0,
            ex: 0,
            ez: 0,
            start_idx: 0,
            end_idx: 0,
            grid_width: 0,
            grid_height: 0,
            clearance_world: 0.0,
            turning_radius: 0.0,
            cell_size: 50.0,
            from: Vector2::ZERO,
            to: Vector2::ZERO,
            clearance: 0.0,
            iterations: 0,
            max_iterations: 200000,
            found: false,
            active: false,
            complete: false,
            result: PathResult::default(),
        }
    }
}

impl PathSearch {
    pub fn allocate(&mut self, total_cells: i32) {
        if self.g_cost.len() == total_cells as usize {
            return;
        }
        let n = total_cells as usize;
        self.g_cost.resize(n, 0.0);
        self.parent.resize(n, 0);
        self.parent_dir.resize(n, 0);
        self.open_gen.resize(n, 0);
        self.closed_gen.resize(n, 0);
        self.current_gen = 0;
    }

    pub fn reset(&mut self) {
        self.open_set.clear();
        self.iterations = 0;
        self.found = false;
        self.active = false;
        self.complete = false;
        self.result = PathResult::default();
    }
}
