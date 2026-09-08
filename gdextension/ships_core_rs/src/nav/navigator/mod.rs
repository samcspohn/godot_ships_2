use godot::prelude::*;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;

use crate::nav::hpa::HpaGraph;
use crate::nav::map::NavigationMap;
use crate::nav::threat::ThreatRegistry;
use crate::nav::types::{
    ArcPoint, DynamicObstacle, IncomingShell, NavState, NavTarget, PathResult, ShipParams,
    ShipState, ThreatCircle,
};

mod api;
mod arc;
mod path;
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

// --- Two-pass threat budgets, in navigation-seconds: how much extra travel
// time we accept to improve the threat score. Shells nudge heading; torpedoes
// justify a major detour.
pub const SHELL_NAV_BUDGET: f32 = 50.0;
pub const TORPEDO_NAV_BUDGET: f32 = 500.0;
pub const SHELL_TIME_TOLERANCE: f32 = 2.0;
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

// --- Stuck / bow-in detection ---
pub const STUCK_TCR_FACTOR: f32 = 0.25;
pub const STUCK_MIN_SECS: f32 = 5.0;
pub const STUCK_OVERRIDE_FACTOR: f32 = 0.20;
pub const STUCK_OVERRIDE_MIN: f32 = 4.0;

pub const ALIGN_BOUNCE_RADIUS_DEFAULT: f32 = 30.0;
pub const PARKED_SPEED_THRESHOLD: f32 = 10.0;

pub const TORPEDO_VIRTUAL_CALIBER: f32 = 2000.0;
pub const GRAZE_MIN_FACTOR: f32 = 0.15;
pub const BOW_STERN_CLIP_START: f32 = 0.80;
pub const PURE_PURSUIT_MIN_IMPROVEMENT: f32 = 0.15;

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

/// Output of select_best_steering.
#[derive(Clone, Copy, Debug, Default)]
pub struct SteeringChoice {
    pub rudder: f32,
    pub throttle: i32,
    /// True if any threat was detected.
    pub collision_imminent: bool,
}

/// Two-pass threat score returned by score_arc_shell_threat. Shell and torpedo
/// scores stay separate so the caller can apply different budgets and suppress
/// shells when the stuck override is active.
#[derive(Clone, Copy, Debug, Default)]
pub struct ThreatEval {
    /// Dimensionless: sum of cal_weight * angle_factor for hitting shells.
    pub shell_score: f32,
    /// Dimensionless: cal_weight for any torpedo intersection.
    pub torpedo_score: f32,
}

impl ThreatEval {
    pub fn combined(&self) -> f32 {
        self.shell_score + self.torpedo_score
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

    /// BTreeMap, not HashMap: three call sites iterate this and are order-sensitive
    /// (the torpedo-score float sum in score_arc_shell_threat, the strict `<`
    /// first-wins tie-break in check_arc_obstacles_detailed, and the output order
    /// of get_debug_torpedo_threat_points). Rust's HashMap randomises iteration
    /// order per process, which would make those non-reproducible run to run;
    /// ordering by id at least makes them deterministic.
    pub(crate) obstacles: BTreeMap<i32, DynamicObstacle>,

    /// When true, check_arc_obstacles_detailed skips non-torpedo obstacles. Set
    /// when the ship is effectively stationary: a parked ship holding position
    /// should not dodge approaching friendlies — the moving ship gives way.
    pub(crate) skip_ship_obstacles: bool,

    /// 0.0 = dead, 1.0 = full HP.
    pub(crate) health_fraction: f32,

    pub(crate) dodge_committed_rudder: f32,
    pub(crate) dodge_commitment_timer: f32,

    pub(crate) direction_conflict_timer: f32,
    pub(crate) stuck_override_active: bool,
    pub(crate) stuck_override_timer: f32,

    pub(crate) align_committed_dir: DesiredDirection,
    pub(crate) align_commit_pos: Vector2,
    pub(crate) align_commit_active: bool,

    pub(crate) incoming_shells: Vec<IncomingShell>,

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
            obstacles: BTreeMap::new(),
            skip_ship_obstacles: false,
            health_fraction: 1.0,
            dodge_committed_rudder: 0.0,
            dodge_commitment_timer: 0.0,
            direction_conflict_timer: 0.0,
            stuck_override_active: false,
            stuck_override_timer: 0.0,
            align_committed_dir: DesiredDirection::Forward,
            align_commit_pos: Vector2::ZERO,
            align_commit_active: false,
            incoming_shells: Vec::new(),
            threat_registry: None,
            threat_team: -1,
            threat_radius: 0.0,
            threats: RefCell::new(Vec::new()),
            threat_synced_version: Cell::new(0),
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
    ) {
        self.navigate_to_impl(
            target,
            heading,
            hold_radius,
            heading_tolerance,
            heading_weight,
            prefer_reverse,
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

    #[func]
    fn clear_incoming_shells(&mut self) {
        self.incoming_shells.clear();
    }

    #[func]
    fn add_incoming_shell(
        &mut self,
        id: i64,
        landing_pos: Vector2,
        time_remaining: f32,
        caliber: f32,
        landing_dir: Vector2,
        threat_half_len: f32,
    ) {
        self.incoming_shells.push(IncomingShell::new(
            id as i32,
            landing_pos,
            time_remaining,
            caliber,
            landing_dir,
            threat_half_len,
        ));
    }

    #[func]
    fn set_threat_source(&mut self, registry: Option<Gd<ThreatRegistry>>, team_id: i32, effective_radius: f32) {
        self.set_threat_source_impl(registry, team_id, effective_radius);
    }

    #[func]
    fn clear_threat_source(&mut self) {
        self.clear_threat_source_impl();
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

    #[func]
    fn get_debug_torpedo_threat_points(&self) -> VarArray {
        self.get_debug_torpedo_threat_points_impl()
    }

    #[func]
    fn get_threat_circle_count(&self) -> i32 {
        self.get_threat_circle_count_impl()
    }

    #[func]
    fn debug_stamp_threats(&mut self) {
        self.debug_stamp_threats_impl();
    }

    #[func]
    fn adjust_destination_for_threats(&self, ship_pos: Vector2, dest: Vector2) -> VarDictionary {
        self.adjust_destination_for_threats_impl(ship_pos, dest)
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
