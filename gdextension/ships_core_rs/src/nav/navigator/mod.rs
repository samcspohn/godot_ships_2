use godot::prelude::*;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;

use crate::nav::hpa::HpaGraph;
use crate::nav::map::NavigationMap;
use crate::nav::reach::ReachField;
use crate::nav::ships::{ShipList, ShipRegistry, ShipSnap};
use crate::nav::threat::ThreatRegistry;
use crate::nav::types::{
    ArcPoint, DynamicObstacle, NavState, NavTarget, PathResult, ShipParams,
    ShipState, ThreatCircle, throttle_to_speed_fraction,
};

mod api;
mod arc;
mod path;
mod ships_avoid;
mod steering;
mod update;

pub const PERF_SPIKE_PHASE_COUNT: usize = 6;

/// Seconds between path-failure warnings from one navigator.
pub const PATH_FAIL_WARN_INTERVAL: f32 = 5.0;

// --- Dodge commitment (hysteresis to prevent oscillation) ---
// When threats are active and the ship picks a dodge direction it commits to
// that direction for a minimum time, so symmetric threats cannot cause
// frame-to-frame rudder oscillation between port and starboard.
pub const DODGE_COMMITMENT_DURATION: f32 = 0.5;
pub const DODGE_COMMITMENT_BIAS: f32 = 150.0;

pub const TURN_LATCH_MIN: f32 = std::f32::consts::FRAC_PI_2;
pub const TURN_LATCH_RELEASE: f32 = std::f32::consts::PI / 6.0;
/// Seconds charged to a candidate turning against the latched side.
pub const TURN_LATCH_PENALTY_S: f32 = 20.0;

pub const SOFT_TERRAIN_PENALTY: f32 = 15.0;

/// Preferred stand-off on top of hull clearance. The corridor is searched at
/// the hull's true minimum — padding the *search* does not buy margin, it
/// deletes channels. Sea room is bought here instead, and given back down to
/// the hull minimum where the water is tighter than this.
pub const HUG_CLEARANCE_BUFFER: f32 = 25.0;

// --- Path stickiness (see accept_plan_result) ---
// Scaled off the turning-circle radius so margins mean the same to a destroyer
// and a battleship.
pub const PATH_NEAR_FIELD_TCR: f32 = 10.0;
pub const PATH_COMPARE_SAMPLES: i32 = 24;
pub const SWITCH_MIN_SEP_TCR: f32 = 0.5;
pub const SWITCH_BASE_TCR: f32 = 0.35;
pub const SWITCH_SEPARATION_GAIN: f32 = 1.5;
pub const SWITCH_FORK_TCR: f32 = 2.0;
pub const SWITCH_COMMIT_TCR: f32 = 10.0;
pub const PATH_CLEAR_MAX_SEGMENTS: i32 = 32;

pub const PARKED_SPEED_THRESHOLD: f32 = 10.0;

pub const TORPEDO_VIRTUAL_CALIBER: f32 = 2000.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum DesiredDirection {
    Forward = 0,
    Backward = 1,
}

pub mod path_fail_reason {
    pub const NONE: i32 = 0;
    /// No built NavigationMap / HpaGraph to plan with.
    pub const NO_MAP: i32 = 1;
    /// HPA* found nothing; previous path retained.
    pub const NO_ROUTE_KEPT_PATH: i32 = 2;
    /// HPA* found nothing; clear straight line used instead.
    pub const NO_ROUTE_DIRECT: i32 = 3;
    /// No route; path stops short of the destination.
    pub const NO_ROUTE_TRUNCATED: i32 = 4;
    /// No route and no clear line; steering straight at the destination.
    pub const NO_ROUTE_BLIND: i32 = 5;
}

/// What replays need to re-simulate winning_arc: start rudder/speed/drift, then the
/// arc's commanded rudder and throttle until turn_t, then straight until end_t.
#[derive(Clone, Copy, Default)]
pub struct ArcInputs {
    pub rudder0: f32,
    pub speed0: f32,
    pub lateral0: f32,
    pub rudder: f32,
    pub throttle: i32,
    pub turn_t: f32,
    pub end_t: f32,
}

/// Output of select_best_steering.
#[derive(Clone, Copy, Debug, Default)]
pub struct SteeringChoice {
    pub rudder: f32,
    pub throttle: i32,
    /// True if any threat was detected.
    pub collision_imminent: bool,
}

/// Torpedo hits along an arc, from score_arc_torpedo_threat; they hard-override navigation.
#[derive(Clone, Copy, Debug)]
pub struct ThreatEval {
    /// Dimensionless: cal_weight for any torpedo intersection.
    pub torpedo_score: f32,
    /// Arc time of the EARLIEST torpedo intersection, `INFINITY` when none.
    /// Under torpedo override this breaks ties between arcs that eat the same
    /// number of torpedoes: later impact is strictly better, because it buys
    /// another decision cycle in which the picture can change.
    pub torpedo_time: f32,
}

impl Default for ThreatEval {
    fn default() -> Self {
        Self { torpedo_score: 0.0, torpedo_time: f32::INFINITY }
    }
}

#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct ShipNavigator {
    base: Base<RefCounted>,

    pub(crate) map: Option<Gd<NavigationMap>>,
    pub(crate) params: ShipParams,
    pub(crate) state: ShipState,
    pub(crate) nav_state: NavState,
    pub(crate) target: NavTarget,

    /// Set by BotControllerV4 from the movement controller.
    pub(crate) grounded: bool,

    pub(crate) emergency_grounding_pos: Vector2,
    pub(crate) emergency_initialized: bool,

    pub(crate) bot_id: i32,

    // --- Path data (SINGLE source of truth) ---
    pub(crate) current_path: PathResult,
    pub(crate) current_wp_index: i32,
    pub(crate) path_valid: bool,

    // --- Path request failure reporting ---
    pub(crate) path_fail_reason: i32,
    pub(crate) path_fail_count: i32,
    pub(crate) path_fail_suppressed: i32,
    pub(crate) path_fail_warn_cooldown: f32,
    pub(crate) path_threat_relaxed: bool,

    pub(crate) hpa_graph: Option<Gd<HpaGraph>>,

    // --- Steering output ---
    pub(crate) out_rudder: f32,
    pub(crate) out_throttle: i32,
    pub(crate) out_collision_imminent: bool,

    // --- Timing ---
    pub(crate) timing_update_us: f32,
    pub(crate) timing_avoidance_us: f32,
    pub(crate) timing_plan_us: f32,
    pub(crate) last_plan_breakdown: VarDictionary,
    pub(crate) last_exposure_us: f32,
    pub(crate) timing_steering_us: f32,
    /// 0 = none (all non-zero codes currently unused).
    pub(crate) timing_replan_reason: i32,
    /// Always 0; kept for GDScript compatibility.
    pub(crate) timing_plan_phase_val: i32,

    // --- Perf instrumentation ---
    pub(crate) perf_frame_count: u64,
    pub(crate) perf_spike_threshold_us: f32,
    pub(crate) perf_report_interval_s: f32,
    pub(crate) perf_report_accum_s: f32,
    pub(crate) perf_tracking_enabled: bool,

    pub(crate) perf_phase_count: [u64; PERF_SPIKE_PHASE_COUNT],
    pub(crate) perf_phase_avg_update_us: [f32; PERF_SPIKE_PHASE_COUNT],
    pub(crate) perf_phase_avg_plan_us: [f32; PERF_SPIKE_PHASE_COUNT],
    pub(crate) perf_phase_avg_avoidance_us: [f32; PERF_SPIKE_PHASE_COUNT],
    pub(crate) perf_phase_avg_steering_us: [f32; PERF_SPIKE_PHASE_COUNT],

    pub(crate) perf_window_frame_count: u64,
    pub(crate) perf_window_update_sum_us: f32,
    pub(crate) perf_window_plan_sum_us: f32,
    pub(crate) perf_window_avoidance_sum_us: f32,
    pub(crate) perf_window_steering_sum_us: f32,

    pub(crate) perf_avg_update_us: f32,
    pub(crate) perf_avg_plan_us: f32,
    pub(crate) perf_avg_avoidance_us: f32,
    pub(crate) perf_avg_steering_us: f32,

    pub(crate) perf_max_update_us: f32,
    pub(crate) perf_max_plan_us: f32,
    pub(crate) perf_max_avoidance_us: f32,
    pub(crate) perf_max_steering_us: f32,

    pub(crate) perf_update_spike_count: u64,
    pub(crate) perf_plan_spike_count: u64,
    pub(crate) perf_avoidance_spike_count: u64,
    pub(crate) perf_steering_spike_count: u64,

    pub(crate) perf_worst_update_spike_us: f32,
    pub(crate) perf_worst_plan_spike_us: f32,
    pub(crate) perf_worst_avoidance_spike_us: f32,
    pub(crate) perf_worst_steering_spike_us: f32,

    pub(crate) perf_last_steering_candidates_total: i32,
    pub(crate) perf_last_steering_candidates_simulated: i32,
    pub(crate) perf_last_steering_terrain_rejects: i32,
    pub(crate) perf_last_steering_short_arc_rejects: i32,
    pub(crate) perf_last_steering_arc_points_simulated: i32,

    /// Debug visualization: the actual simulated arc that won scoring.
    pub(crate) winning_arc: Vec<ArcPoint>,
    pub(crate) winning_arc_inputs: ArcInputs,

    /// BTreeMap, not HashMap: three call sites iterate this and are order-sensitive
    /// (the torpedo-score float sum in score_arc_torpedo_threat, the strict `<`
    /// first-wins tie-break in check_arc_obstacles_detailed, and the output order
    /// of get_debug_torpedo_threat_points). Rust's HashMap randomises iteration
    /// order per process, which would make those non-reproducible run to run;
    /// ordering by id at least makes them deterministic.
    pub(crate) obstacles: BTreeMap<i32, DynamicObstacle>,

    /// When true, check_arc_obstacles_detailed skips non-torpedo obstacles. Set
    /// when the ship is effectively stationary: a parked ship holding position
    /// should not dodge approaching friendlies — the moving ship gives way.
    pub(crate) skip_ship_obstacles: bool,
    pub(crate) ship_source: Option<ShipList>,
    pub(crate) own_ship_id: i64,
    pub(crate) own_team: i32,
    /// Ships near and visible this frame (refresh_ships).
    pub(crate) ships: Vec<ShipSnap>,

    /// 0.0 = dead, 1.0 = full HP.
    pub(crate) health_fraction: f32,

    pub(crate) dodge_committed_rudder: f32,
    pub(crate) dodge_commitment_timer: f32,
    /// Rudder side of a big turn in progress, 0 none.
    pub(crate) turn_latch: f32,
    /// True on the last `select_best_steering` when a torpedo threatened at
    /// least one candidate arc, i.e. navigation was hard-overridden; stance's
    /// throttle cap stands down so it cannot spoil the dodge.
    pub(crate) torpedo_override_active: bool,




    // --- Enemy threat circles (for stealth pathfinding) ---
    pub(crate) threat_registry: Option<Gd<ThreatRegistry>>,
    pub(crate) threat_team: i32,
    pub(crate) threat_radius: f32,
    /// `mutable` in the C++: the const query paths (destination push, debug
    /// clusters) have to see the current picture too, and refreshing is not a
    /// state change anyone outside can observe.
    pub(crate) threats: RefCell<Vec<ThreatCircle>>,
    /// 0 = never synced.
    pub(crate) threat_synced_version: Cell<u64>,
    /// Circles a skill routes around; replace the registry and the field while set.
    pub(crate) manual_threats: Option<Vec<ThreatCircle>>,
    /// Detection field subscription: routes are priced by the team's
    /// detection distance against this ship's concealment radius.
    pub(crate) detect_field: Option<Gd<ReachField>>,
    pub(crate) detect_team: i32,
    pub(crate) detect_radius: f32,
    pub(crate) detect_gain: f32,
    pub(crate) detect_exposure: std::sync::Arc<Vec<f32>>,
    pub(crate) detect_exposure_mean: std::sync::Arc<Vec<f32>>,
    pub(crate) detect_sub_exposure: std::sync::Arc<Vec<f32>>,
    pub(crate) detect_synced_version: i64,

    // --- Path stickiness instrumentation ---
    pub(crate) path_switch_count: i32,
    pub(crate) path_switch_rejected: i32,
    pub(crate) path_last_divergence: f32,
}

#[godot_api]
impl IRefCounted for ShipNavigator {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            map: None,
            params: ShipParams::default(),
            state: ShipState::default(),
            nav_state: NavState::Normal,
            target: NavTarget::default(),
            grounded: false,
            emergency_grounding_pos: Vector2::ZERO,
            emergency_initialized: false,
            bot_id: 0,
            current_path: PathResult::default(),
            current_wp_index: 0,
            path_valid: false,
            path_fail_reason: path_fail_reason::NONE,
            path_fail_count: 0,
            path_fail_suppressed: 0,
            path_fail_warn_cooldown: 0.0,
            path_threat_relaxed: false,
            hpa_graph: None,
            out_rudder: 0.0,
            out_throttle: 0,
            out_collision_imminent: false,
            timing_update_us: 0.0,
            timing_avoidance_us: 0.0,
            timing_plan_us: 0.0,
            last_plan_breakdown: VarDictionary::new(),
            last_exposure_us: 0.0,
            timing_steering_us: 0.0,
            timing_replan_reason: 0,
            timing_plan_phase_val: 0,
            perf_frame_count: 0,
            perf_spike_threshold_us: 2500.0,
            perf_report_interval_s: 5.0,
            perf_report_accum_s: 0.0,
            perf_tracking_enabled: false,
            perf_phase_count: [0; PERF_SPIKE_PHASE_COUNT],
            perf_phase_avg_update_us: [0.0; PERF_SPIKE_PHASE_COUNT],
            perf_phase_avg_plan_us: [0.0; PERF_SPIKE_PHASE_COUNT],
            perf_phase_avg_avoidance_us: [0.0; PERF_SPIKE_PHASE_COUNT],
            perf_phase_avg_steering_us: [0.0; PERF_SPIKE_PHASE_COUNT],
            perf_window_frame_count: 0,
            perf_window_update_sum_us: 0.0,
            perf_window_plan_sum_us: 0.0,
            perf_window_avoidance_sum_us: 0.0,
            perf_window_steering_sum_us: 0.0,
            perf_avg_update_us: 0.0,
            perf_avg_plan_us: 0.0,
            perf_avg_avoidance_us: 0.0,
            perf_avg_steering_us: 0.0,
            perf_max_update_us: 0.0,
            perf_max_plan_us: 0.0,
            perf_max_avoidance_us: 0.0,
            perf_max_steering_us: 0.0,
            perf_update_spike_count: 0,
            perf_plan_spike_count: 0,
            perf_avoidance_spike_count: 0,
            perf_steering_spike_count: 0,
            perf_worst_update_spike_us: 0.0,
            perf_worst_plan_spike_us: 0.0,
            perf_worst_avoidance_spike_us: 0.0,
            perf_worst_steering_spike_us: 0.0,
            perf_last_steering_candidates_total: 0,
            perf_last_steering_candidates_simulated: 0,
            perf_last_steering_terrain_rejects: 0,
            perf_last_steering_short_arc_rejects: 0,
            perf_last_steering_arc_points_simulated: 0,
            winning_arc: Vec::new(),
            winning_arc_inputs: ArcInputs::default(),
            obstacles: BTreeMap::new(),
            skip_ship_obstacles: false,
            ship_source: None,
            own_ship_id: 0,
            own_team: -1,
            ships: Vec::new(),
            health_fraction: 1.0,
            dodge_committed_rudder: 0.0,
            dodge_commitment_timer: 0.0,
            turn_latch: 0.0,
            torpedo_override_active: false,
            threat_registry: None,
            threat_team: -1,
            threat_radius: 0.0,
            threats: RefCell::new(Vec::new()),
            threat_synced_version: Cell::new(0),
            manual_threats: None,
            detect_field: None,
            detect_team: -1,
            detect_radius: 0.0,
            detect_gain: 0.0,
            detect_exposure: std::sync::Arc::new(Vec::new()),
            detect_exposure_mean: std::sync::Arc::new(Vec::new()),
            detect_sub_exposure: std::sync::Arc::new(Vec::new()),
            detect_synced_version: -1,
            path_switch_count: 0,
            path_switch_rejected: 0,
            path_last_divergence: 0.0,
        }
    }
}

impl ShipNavigator {
    pub(crate) fn path_fail_reason_name(reason: i32) -> &'static str {
        use path_fail_reason::*;
        match reason {
            NO_MAP => "no built navigation map / HPA graph",
            NO_ROUTE_KEPT_PATH => "no route found, keeping previous path",
            NO_ROUTE_DIRECT => "no route found, using straight line to destination",
            NO_ROUTE_TRUNCATED => "no route found, path truncated short of destination",
            NO_ROUTE_BLIND => "no route found, steering blind at destination",
            _ => "none",
        }
    }
}

// --- Bound API ---
//
// The C++ additionally binds get_bot_id, get_grounded, get_distance_to_destination,
// get_path_divergence, get_path_switch_count, get_path_switch_rejected_count and
// get_timing_steering_us; none has a caller anywhere in the project.

#[godot_api]
impl ShipNavigator {
    #[func]
    fn set_map(&mut self, map: Option<Gd<NavigationMap>>) {
        self.map = map;
    }

    #[func]
    fn set_hpa_graph(&mut self, graph: Option<Gd<HpaGraph>>) {
        self.hpa_graph = graph;
    }

    #[func]
    fn get_clearance(&self) -> f32 {
        self.get_ship_clearance()
    }

    /// Builds the graph's water regions for this hull's clearance now, at
    /// load, instead of inside its first plan. Needs the graph and ship params.
    #[func]
    fn prepare_regions(&self) {
        if let Some(g) = &self.hpa_graph {
            let g = g.bind();
            if g.is_built() {
                g.region_labels(self.get_ship_clearance());
            }
        }
    }

    #[func]
    fn get_hpa_graph(&self) -> Option<Gd<HpaGraph>> {
        self.hpa_graph.clone()
    }

    #[func]
    /// C++ takes `int`; Godot marshals the 64-bit Variant into it with silent
    /// truncation, and callers pass `get_instance_id()`, which does not fit in
    /// i32. Taking i64 and truncating reproduces the C++ exactly — a bare i32
    /// parameter makes gdext reject the call instead.
    fn set_bot_id(&mut self, id: i64) {
        self.bot_id = id as i32;
    }

    #[func]
    fn set_grounded(&mut self, grounded: bool) {
        self.grounded = grounded;
    }

    #[func]
    fn get_rudder(&self) -> f32 {
        self.out_rudder
    }

    #[func]
    fn get_throttle(&self) -> i32 {
        self.out_throttle
    }

    #[func]
    fn get_nav_state(&self) -> i32 {
        self.nav_state as i32
    }

    /// See `torpedo_override_active`.
    #[func]
    fn is_torpedo_override_active(&self) -> bool {
        self.torpedo_override_active
    }

    #[func]
    fn is_collision_imminent(&self) -> bool {
        self.out_collision_imminent
    }

    #[func]
    fn is_path_threat_relaxed(&self) -> bool {
        self.path_threat_relaxed
    }

    #[func]
    fn get_path_failure_count(&self) -> i32 {
        self.path_fail_count
    }

    #[func]
    fn get_last_path_failure_reason(&self) -> i32 {
        self.path_fail_reason
    }

    #[func]
    fn get_last_path_failure_reason_name(&self) -> GString {
        GString::from(Self::path_fail_reason_name(self.path_fail_reason))
    }

    #[func]
    fn get_clearance_radius(&self) -> f32 {
        self.get_ship_clearance()
    }

    #[func]
    fn get_soft_clearance_radius(&self) -> f32 {
        self.get_soft_clearance()
    }

    #[func]
    fn get_timing_update_us(&self) -> f32 {
        self.timing_update_us
    }

    #[func]
    fn get_timing_avoidance_us(&self) -> f32 {
        self.timing_avoidance_us
    }

    #[func]
    fn get_timing_plan_us(&self) -> f32 {
        self.timing_plan_us
    }

    /// Where the last navigate_to's time went.
    #[func]
    fn get_last_plan_breakdown(&self) -> VarDictionary {
        self.last_plan_breakdown.clone()
    }

    #[func]
    fn get_timing_replan_reason(&self) -> i32 {
        self.timing_replan_reason
    }

    #[func]
    fn get_timing_plan_phase(&self) -> i32 {
        self.timing_plan_phase_val
    }

    #[func]
    fn get_perf_spike_threshold_us(&self) -> f32 {
        self.perf_spike_threshold_us
    }

    #[func]
    fn set_perf_spike_threshold_us(&mut self, threshold_us: f32) {
        self.set_perf_spike_threshold_us_impl(threshold_us);
    }

    #[func]
    fn is_perf_tracking_enabled(&self) -> bool {
        self.perf_tracking_enabled
    }

    #[func]
    fn set_perf_tracking_enabled(&mut self, enabled: bool) {
        self.set_perf_tracking_enabled_impl(enabled);
    }

    #[func]
    fn set_ship_params(
        &mut self,
        turning_circle_radius: f32,
        rudder_response_time: f32,
        acceleration_time: f32,
        deceleration_time: f32,
        max_speed: f32,
        reverse_speed_ratio: f32,
        ship_length: f32,
        ship_beam: f32,
        turn_speed_loss: f32,
        linear_drag: f32,
    ) {
        self.set_ship_params_impl(
            turning_circle_radius,
            rudder_response_time,
            acceleration_time,
            deceleration_time,
            max_speed,
            reverse_speed_ratio,
            ship_length,
            ship_beam,
            turn_speed_loss,
            linear_drag,
        );
    }

    #[func]
    fn set_state(
        &mut self,
        position: Vector3,
        velocity: Vector3,
        heading: f32,
        angular_velocity_y: f32,
        current_rudder: f32,
        current_speed: f32,
        delta: f32,
    ) {
        self.set_state_impl(
            position,
            velocity,
            heading,
            angular_velocity_y,
            current_rudder,
            current_speed,
            delta,
        );
    }

    #[func]
    fn navigate_to(
        &mut self,
        target: Vector3,
        heading: f32,
        #[opt(default = 0.0)] hold_radius: f32,
        #[opt(default = 0.2618)] heading_tolerance: f32,
        #[opt(default = 0.0)] heading_weight: f32,
        #[opt(default = false)] prefer_reverse: bool,
        #[opt(default = false)] forbid_reverse: bool,
    ) {
        self.navigate_to_impl(
            target,
            heading,
            hold_radius,
            heading_tolerance,
            heading_weight,
            prefer_reverse,
            forbid_reverse,
        );
    }

    #[func]
    fn stop(&mut self) {
        self.stop_impl();
    }

    #[func]
    fn set_health_fraction(&mut self, fraction: f32) {
        self.set_health_fraction_impl(fraction);
    }

    #[func]
    /// See set_bot_id: BotControllerV4 passes `ship.get_instance_id()` here.
    fn register_obstacle(
        &mut self,
        id: i64,
        position: Vector2,
        velocity: Vector2,
        radius: f32,
        length: f32,
    ) {
        self.register_obstacle_impl(id as i32, position, velocity, radius, length);
    }

    #[func]
    fn update_obstacle(&mut self, id: i64, position: Vector2, velocity: Vector2) {
        self.update_obstacle_impl(id as i32, position, velocity);
    }

    #[func]
    fn remove_obstacle(&mut self, id: i64) {
        self.remove_obstacle_impl(id as i32);
    }

    #[func]
    fn clear_obstacles(&mut self) {
        self.clear_obstacles_impl();
    }

    /// Every ship in the match; this navigator avoids those near it, friendly or spotted.
    #[func]
    fn set_ship_registry(&mut self, registry: Option<Gd<ShipRegistry>>, own_id: i64, team: i32) {
        self.ship_source = registry.map(|r| r.bind().ships.clone());
        self.own_ship_id = own_id;
        self.own_team = team;
    }

    #[func]
    fn set_threat_source(&mut self, registry: Option<Gd<ThreatRegistry>>, team_id: i32, effective_radius: f32) {
        self.set_threat_source_impl(registry, team_id, effective_radius);
    }

    #[func]
    fn clear_threat_source(&mut self) {
        self.clear_threat_source_impl();
    }

    /// Walls the route out of these circles (with line of sight to their
    /// centre) until cleared; the registry and field sources stand aside.
    #[func]
    fn set_threat_circles(&mut self, origins: PackedVector2Array, radii: PackedFloat32Array) {
        let circles: Vec<ThreatCircle> = origins.as_slice().iter().zip(radii.as_slice())
            .filter(|(_, &r)| r > 0.0)
            .enumerate()
            .map(|(i, (&o, &r))| ThreatCircle::new(i as i32, o, r))
            .collect();
        *self.threats.borrow_mut() = circles.clone();
        self.manual_threats = Some(circles);
    }

    #[func]
    fn clear_threat_circles(&mut self) {
        if self.manual_threats.take().is_some() {
            self.threats.borrow_mut().clear();
            self.threat_synced_version.set(0);
        }
    }

    /// Route against `field`'s detection grid for `team_id`, spotted below
    /// `radius`. `gain` prices a threatened cluster step (0 or INF walls it).
    #[func]
    fn set_detection_source(&mut self, field: Option<Gd<ReachField>>, team_id: i32, radius: f32, gain: f32) {
        self.detect_field = field;
        self.detect_team = team_id;
        self.detect_radius = radius;
        self.detect_gain = gain;
        self.detect_synced_version = -1;
    }

    #[func]
    fn clear_detection_source(&mut self) {
        self.detect_field = None;
        self.detect_team = -1;
        self.detect_synced_version = -1;
        self.detect_exposure = std::sync::Arc::new(Vec::new());
        self.detect_exposure_mean = std::sync::Arc::new(Vec::new());
        self.detect_sub_exposure = std::sync::Arc::new(Vec::new());
    }

    #[func]
    fn clear_path_failures(&mut self) {
        self.clear_path_failures_impl();
    }

    #[func]
    fn get_current_path(&self) -> PackedVector3Array {
        self.get_current_path_impl()
    }

    #[func]
    fn get_predicted_trajectory(&self) -> PackedVector3Array {
        self.get_predicted_trajectory_impl()
    }

    #[func]
    fn get_current_waypoint(&self) -> Vector3 {
        self.get_current_waypoint_impl()
    }

    #[func]
    fn get_desired_heading(&self) -> f32 {
        self.get_desired_heading_impl()
    }

    #[func]
    fn is_arrived(&self) -> bool {
        self.is_arrived_impl()
    }

    #[func]
    fn get_debug_threat_clusters(&self) -> Array<VarDictionary> {
        self.get_debug_threat_clusters_impl()
    }

    /// Ship params then ArcInputs, for simulate_debug_arc.
    #[func]
    fn get_debug_arc_inputs(&self) -> PackedFloat32Array {
        let (p, a) = (&self.params, &self.winning_arc_inputs);
        PackedFloat32Array::from(&[
            p.turning_circle_radius, p.rudder_response_time, p.acceleration_time, p.max_speed,
            p.reverse_speed_ratio, p.ship_length, p.ship_beam, p.turn_speed_loss,
            a.rudder0, a.speed0, a.lateral0, a.rudder, a.throttle as f32, a.turn_t, a.end_t,
        ][..])
    }

    /// Rebuilds get_predicted_trajectory from get_debug_arc_inputs at a given pose.
    #[func]
    fn simulate_debug_arc(inputs: PackedFloat32Array, position: Vector3, heading: f32) -> PackedVector3Array {
        let mut out = PackedVector3Array::new();
        let v = inputs.as_slice();
        if v.len() < 15 || v[14] <= 0.0 {
            return out;
        }
        let p = ShipParams {
            turning_circle_radius: v[0], rudder_response_time: v[1], acceleration_time: v[2], max_speed: v[3],
            reverse_speed_ratio: v[4], ship_length: v[5], ship_beam: v[6], turn_speed_loss: v[7],
            ..ShipParams::default()
        };
        let throttle = v[12] as i32;
        let fraction = throttle_to_speed_fraction(throttle);
        let target_speed = if fraction < 0.0 { fraction * p.max_speed * p.reverse_speed_ratio } else { fraction * p.max_speed };
        let start = arc::ArcStart {
            position: Vector2::new(position.x, position.z), heading, speed: v[9], lateral_speed: v[10], rudder: v[8],
        };
        let clearance = (p.ship_length as f64 / 2.0 + p.ship_beam as f64) as f32;
        let arc = arc::integrate_arc(&p, start, v[11], target_speed, clearance, f32::MAX, v[13]);
        for pt in &arc {
            out.push(Vector3::new(pt.position.x, 0.0, pt.position.y));
        }
        if let Some(last) = arc.last().copied() {
            let fwd = Vector2::new(last.heading.sin(), last.heading.cos());
            let mut t = last.time;
            while t + ships_avoid::EXTEND_DT <= v[14] + 1e-3 {
                t += ships_avoid::EXTEND_DT;
                let q = last.position + fwd * (last.speed * (t - last.time));
                out.push(Vector3::new(q.x, 0.0, q.y));
            }
        }
        out
    }

    #[func]
    fn get_debug_torpedo_threat_points(&self) -> VarArray {
        self.get_debug_torpedo_threat_points_impl()
    }

    #[func]
    fn get_threat_circle_count(&self) -> i32 {
        self.get_threat_circle_count_impl()
    }

    #[func]
    fn get_threat_circles(&self) -> PackedVector3Array {
        self.get_threat_circles_impl()
    }

    #[func]
    fn debug_stamp_threats(&mut self) {
        self.debug_stamp_threats_impl();
    }

    #[func]
    fn adjust_destination_for_threats(&self, ship_pos: Vector2, dest: Vector2) -> VarDictionary {
        self.adjust_destination_for_threats_impl(ship_pos, dest)
    }

    /// True when `point` is unusable as a destination: inside terrain at
    /// `clearance` (the hull clearance when 0), or inside a cluster this
    /// navigator's threat layer blocks. Off-map points read as terrain.
    #[func]
    fn is_point_blocked(&self, point: Vector2, #[opt(default = 0.0)] clearance: f32) -> bool {
        let (in_terrain, threatened) = self.point_blocking_impl(point, clearance);
        in_terrain || threatened
    }

    /// is_point_blocked with the reason kept apart:
    /// `{in_terrain, threatened, blocked}`.
    #[func]
    fn get_point_blocking(
        &self,
        point: Vector2,
        #[opt(default = 0.0)] clearance: f32,
    ) -> VarDictionary {
        let (in_terrain, threatened) = self.point_blocking_impl(point, clearance);
        let mut d = VarDictionary::new();
        d.set("in_terrain", in_terrain);
        d.set("threatened", threatened);
        d.set("blocked", in_terrain || threatened);
        d
    }

    #[func]
    fn get_perf_metrics(&self) -> VarDictionary {
        self.get_perf_metrics_impl()
    }

    #[func]
    fn reset_perf_metrics(&mut self) {
        self.reset_perf_metrics_impl();
    }

    /// Backward-compatible stub.
    #[func]
    fn get_simulated_path(&self) -> PackedVector3Array {
        self.get_simulated_path_impl()
    }
}
