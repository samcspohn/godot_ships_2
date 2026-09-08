use godot::prelude::*;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;

use crate::nav::map::NavigationMap;

mod astar;
mod build;
mod geom;
mod query;
mod threats;

pub const DEFAULT_CLUSTER_SIZE: i32 = 16;
pub const DEFAULT_SUB_SIZE: i32 = 4;

/// Bisection steps per tangent sweep / relaxation slide. 8 resolves a segment
/// to 1/256 of its length, well below cell resolution.
pub const PULL_BISECT_STEPS: i32 = 8;
/// Relaxation sweeps over the polyline. Converges in 2-3 on ordinary
/// coastlines; the pass exits early once no vertex moves.
pub const PULL_RELAX_ITERS: i32 = 4;
/// Ceiling on vertices so a pathological route cannot make the pull quadratic.
pub const PULL_MAX_VERTS: i32 = 192;

/// Step-cost multiplier for abstract nodes the ship's current route already
/// runs through. At 0.75 a corridor route wins any tie and stays chosen until
/// an alternative is more than a third shorter — enough that replan-to-replan
/// noise can no longer flip which side of an island the route takes.
pub const PATH_BIAS_FACTOR: f32 = 0.75;
pub const PATH_BIAS_MAX_STEPS_PER_SEG: i32 = 512;

/// A node is passable when a *single* one of its cells is navigable, so without
/// this an 800 m step through a one-cell channel prices like open ocean.
/// Charging for how much of a node is actually water restores the ordering.
/// The multiplier is >= 1, so a plain Euclidean heuristic stays admissible.
pub const CONGESTION_GAIN: f32 = 0.75;

#[derive(Clone, Copy, Debug, Default)]
pub struct Cluster {
    pub id: i32,
    pub cx: i32,
    pub cz: i32,
    pub x0: i32,
    pub z0: i32,
    pub x1: i32,
    pub z1: i32,
    pub sub_x0: i32,
    pub sub_z0: i32,
    pub sub_x1: i32,
    pub sub_z1: i32,
    pub max_sdf: f32,
    pub min_sdf: f32,
    pub nav_frac: f32,
    pub wx_center: f32,
    pub wz_center: f32,
    pub navigable: bool,
}

/// Finer-granularity routing primitive (Level 1.5), sized to roughly match the
/// agent's clearance scale. Every macro Cluster contains an integer number of
/// sub-clusters.
#[derive(Clone, Copy, Debug, Default)]
pub struct SubCluster {
    pub id: i32,
    pub parent_cid: i32,
    pub scx: i32,
    pub scz: i32,
    pub x0: i32,
    pub z0: i32,
    pub x1: i32,
    pub z1: i32,
    pub max_sdf: f32,
    pub min_sdf: f32,
    pub nav_frac: f32,
    pub wx_center: f32,
    pub wz_center: f32,
    pub navigable: bool,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct HpaObstacle {
    pub id: i32,
    pub pos: Vector2,
    pub radius: f32,
}

/// The corridor occupied by the route a ship is already following. Stamping the
/// previous route into these masks and charging a discounted step cost inside
/// them makes the search sticky, so only a materially cheaper alternative can
/// move it. Both levels are stamped because which side of an island a route
/// takes is settled at the macro layer for large islands and at the sub layer
/// for ones smaller than a cluster.
#[derive(Clone, Debug, Default)]
pub struct PathBias {
    pub macro_mask: Vec<u8>, // parallel to clusters
    pub sub: Vec<u8>,        // parallel to sub_clusters
    pub active: bool,
}

/// Where a failed query gave up, so a "no route" warning names the stage
/// instead of just the symptom.
pub mod fail_stage {
    pub const FAIL_NONE: i32 = 0;
    pub const FAIL_NOT_BUILT: i32 = 1;
    pub const FAIL_START_SNAP: i32 = 2;
    pub const FAIL_GOAL_SNAP: i32 = 3;
    pub const FAIL_CLUSTER_ASTAR: i32 = 4;
    pub const FAIL_CONNECTOR_ASTAR: i32 = 5;
    pub const FAIL_STRING_PULL: i32 = 6;
    pub const FAIL_SEPARATE_WATER: i32 = 7;
}

#[derive(Clone, Debug)]
pub struct PerfStats {
    pub query_count: u64,
    pub success_count: u64,
    pub failure_count: u64,

    pub last_total_us: f32,
    pub last_connect_us: f32,
    pub last_abstract_us: f32,
    pub last_refine_us: f32,
    pub last_start_connect_us: f32,
    pub last_goal_connect_us: f32,

    pub avg_total_us: f32,
    pub avg_connect_us: f32,
    pub avg_abstract_us: f32,
    pub avg_refine_us: f32,

    pub max_total_us: f32,
    pub max_connect_us: f32,
    pub max_abstract_us: f32,
    pub max_refine_us: f32,

    pub last_connector_los_attempts: i32,
    pub last_connector_los_hits: i32,
    pub last_connector_local_search_runs: i32,
    pub last_connector_local_expansions: i32,
    pub last_connector_portal_candidates: i32,

    pub avg_connector_los_attempts: f32,
    pub avg_connector_los_hits: f32,
    pub avg_connector_local_search_runs: f32,
    pub avg_connector_local_expansions: f32,
    pub avg_connector_portal_candidates: f32,

    pub spike_threshold_us: f32,
    pub spike_count: u64,
    pub worst_spike_us: f32,

    pub report_interval_s: f32,
    pub last_report_wall_us: u64,
    pub window_queries: u64,
    pub window_total_sum_us: f32,
    pub window_connect_sum_us: f32,
    pub window_abstract_sum_us: f32,
    pub window_refine_sum_us: f32,
}

impl Default for PerfStats {
    fn default() -> Self {
        Self {
            query_count: 0,
            success_count: 0,
            failure_count: 0,
            last_total_us: 0.0,
            last_connect_us: 0.0,
            last_abstract_us: 0.0,
            last_refine_us: 0.0,
            last_start_connect_us: 0.0,
            last_goal_connect_us: 0.0,
            avg_total_us: 0.0,
            avg_connect_us: 0.0,
            avg_abstract_us: 0.0,
            avg_refine_us: 0.0,
            max_total_us: 0.0,
            max_connect_us: 0.0,
            max_abstract_us: 0.0,
            max_refine_us: 0.0,
            last_connector_los_attempts: 0,
            last_connector_los_hits: 0,
            last_connector_local_search_runs: 0,
            last_connector_local_expansions: 0,
            last_connector_portal_candidates: 0,
            avg_connector_los_attempts: 0.0,
            avg_connector_los_hits: 0.0,
            avg_connector_local_search_runs: 0.0,
            avg_connector_local_expansions: 0.0,
            avg_connector_portal_candidates: 0.0,
            spike_threshold_us: 2500.0,
            spike_count: 0,
            worst_spike_us: 0.0,
            report_interval_s: 5.0,
            last_report_wall_us: 0,
            window_queries: 0,
            window_total_sum_us: 0.0,
            window_connect_sum_us: 0.0,
            window_abstract_sum_us: 0.0,
            window_refine_sum_us: 0.0,
        }
    }
}

/// Cluster-grid hierarchical navigation graph.
///
/// Level 0: SDF grid cells (in NavigationMap). Level 1: fixed-size rectangular
/// clusters, each storing max_sdf/min_sdf scanned at build time. No portal
/// nodes are precomputed. Dynamic circular obstacles are handled by per-cluster
/// block counts.
#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct HpaGraph {
    base: Base<RefCounted>,

    pub(crate) nav_map: Option<Gd<NavigationMap>>,
    pub(crate) clearance: f32,
    pub(crate) cluster_size: i32,
    pub(crate) sub_size: i32,
    pub(crate) subs_per_macro_side: i32,

    pub(crate) grid_w: i32,
    pub(crate) grid_h: i32,
    pub(crate) ncx: i32,
    pub(crate) ncz: i32,
    pub(crate) nsubx: i32,
    pub(crate) nsubz: i32,
    pub(crate) cell_size: f32,
    pub(crate) min_x: f32,
    pub(crate) min_z: f32,

    pub(crate) clusters: Vec<Cluster>,
    pub(crate) sub_clusters: Vec<SubCluster>,

    /// Per-cluster obstacle block counts (parallel to `clusters`).
    pub(crate) cluster_block_count: Vec<i32>,
    /// Per-cluster threat-arc blocked flags. Separate from block counts so
    /// obstacle and threat blocking clear independently.
    pub(crate) cluster_threat_blocked: Vec<u8>,
    /// Compact list of threat-blocked cluster ids, kept in lock-step with
    /// `cluster_threat_blocked` so clearing iterates only the small subset.
    pub(crate) threat_blocked_cids: Vec<i32>,
    pub(crate) threat_blocked_count: i32,

    pub(crate) cardinal_step_cost: f32,
    pub(crate) diagonal_step_cost: f32,

    pub(crate) obstacles: HashMap<i32, HpaObstacle>,

    pub(crate) built: bool,

    /// `mutable` in the C++ so queries can stay `const`; interior mutability is
    /// the faithful equivalent and keeps every query taking `&self`.
    pub(crate) perf: RefCell<PerfStats>,
    pub(crate) perf_tracking_enabled: bool,

    // Per-query state (single-threaded; the graph is stamped per query).
    pub(crate) threats_muted: Cell<bool>,
    pub(crate) last_query_ignored_threats: Cell<bool>,
    pub(crate) last_fail_stage: Cell<i32>,
}

#[godot_api]
impl IRefCounted for HpaGraph {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            nav_map: None,
            clearance: 0.0,
            cluster_size: DEFAULT_CLUSTER_SIZE,
            sub_size: DEFAULT_SUB_SIZE,
            subs_per_macro_side: DEFAULT_CLUSTER_SIZE / DEFAULT_SUB_SIZE,
            grid_w: 0,
            grid_h: 0,
            ncx: 0,
            ncz: 0,
            nsubx: 0,
            nsubz: 0,
            cell_size: 1.0,
            min_x: 0.0,
            min_z: 0.0,
            clusters: Vec::new(),
            sub_clusters: Vec::new(),
            cluster_block_count: Vec::new(),
            cluster_threat_blocked: Vec::new(),
            threat_blocked_cids: Vec::new(),
            threat_blocked_count: 0,
            cardinal_step_cost: 0.0,
            diagonal_step_cost: 0.0,
            obstacles: HashMap::new(),
            built: false,
            perf: RefCell::new(PerfStats::default()),
            perf_tracking_enabled: false,
            threats_muted: Cell::new(false),
            last_query_ignored_threats: Cell::new(false),
            last_fail_stage: Cell::new(fail_stage::FAIL_NONE),
        }
    }
}

// --- Inline coordinate / cost helpers ---

impl HpaGraph {
    pub(crate) fn cluster_id(&self, cx: i32, cz: i32) -> i32 {
        cz * self.ncx + cx
    }

    pub(crate) fn cell_cx(&self, gx: i32) -> i32 {
        (gx / self.cluster_size).min(self.ncx - 1)
    }

    pub(crate) fn cell_cz(&self, gz: i32) -> i32 {
        (gz / self.cluster_size).min(self.ncz - 1)
    }

    pub(crate) fn sub_id(&self, scx: i32, scz: i32) -> i32 {
        scz * self.nsubx + scx
    }

    pub(crate) fn cell_scx(&self, gx: i32) -> i32 {
        (gx / self.sub_size).min(self.nsubx - 1)
    }

    pub(crate) fn cell_scz(&self, gz: i32) -> i32 {
        (gz / self.sub_size).min(self.nsubz - 1)
    }

    pub(crate) fn grid_to_world(&self, gx: i32, gz: i32) -> (f32, f32) {
        (
            self.min_x + (gx as f32 + 0.5) * self.cell_size,
            self.min_z + (gz as f32 + 0.5) * self.cell_size,
        )
    }

    /// Step-cost multiplier for a node, from how much of it is actually water.
    /// Always >= 1, so the Euclidean heuristic stays a lower bound.
    pub(crate) fn cluster_cost_mul(&self, cid: i32) -> f32 {
        1.0 + CONGESTION_GAIN * (1.0 - self.clusters[cid as usize].nav_frac)
    }

    pub(crate) fn sub_cost_mul(&self, sid: i32) -> f32 {
        1.0 + CONGESTION_GAIN * (1.0 - self.sub_clusters[sid as usize].nav_frac)
    }

    pub(crate) fn cluster_blocked(&self, cid: i32) -> bool {
        if cid < 0 || cid >= self.cluster_block_count.len() as i32 {
            return false;
        }
        if self.cluster_block_count[cid as usize] > 0 {
            return true;
        }
        // threats_muted is set for the relaxed retry in find_path().
        !self.threats_muted.get() && self.cluster_threat_blocked[cid as usize] != 0
    }

    pub(crate) fn fail_stage_name(stage: i32) -> &'static str {
        use fail_stage::*;
        match stage {
            FAIL_NOT_BUILT => "graph not built",
            FAIL_START_SNAP => "start not navigable at query clearance",
            FAIL_GOAL_SNAP => "goal not navigable at query clearance",
            FAIL_CLUSTER_ASTAR => "cluster A* found no corridor",
            FAIL_CONNECTOR_ASTAR => "connector could not bridge a guide segment",
            FAIL_STRING_PULL => "assembled path collapsed",
            FAIL_SEPARATE_WATER => "goal is in a water region the ship cannot reach",
            _ => "none",
        }
    }
}

// --- Bound API ---
//
// Only the surface that is actually reachable is bound. The C++ additionally
// binds get_debug_nodes/edges/clusters/sub_clusters, get_last_fail_stage,
// set/get_perf_spike_threshold_us and is_perf_tracking_enabled, none of which
// has a caller anywhere in the project.

#[godot_api]
impl HpaGraph {
    #[func]
    pub(crate) fn build(
        &mut self,
        nav_map: Option<Gd<NavigationMap>>,
        clearance: f32,
        #[opt(default = DEFAULT_CLUSTER_SIZE)] cluster_size: i32,
    ) {
        self.build_impl(nav_map, clearance, cluster_size);
    }

    #[func]
    pub(crate) fn is_built(&self) -> bool {
        self.built
    }

    #[func]
    pub(crate) fn find_path_packed(
        &self,
        from: Vector2,
        to: Vector2,
        #[opt(default = -1.0)] query_clearance: f32,
        #[opt(default = -1.0)] hug_clearance: f32,
    ) -> PackedVector2Array {
        let r = self.find_path(from, to, query_clearance, hug_clearance, None);
        let mut out = PackedVector2Array::new();
        for wp in &r.waypoints {
            out.push(*wp);
        }
        out
    }

    #[func]
    pub(crate) fn find_path_biased_packed(
        &self,
        from: Vector2,
        to: Vector2,
        query_clearance: f32,
        hug_clearance: f32,
        bias_path: PackedVector2Array,
    ) -> PackedVector2Array {
        let bias: Vec<Vector2> = bias_path.as_slice().to_vec();
        let r = self.find_path(from, to, query_clearance, hug_clearance, Some(&bias));
        let mut out = PackedVector2Array::new();
        for wp in &r.waypoints {
            out.push(*wp);
        }
        out
    }

    #[func]
    fn add_obstacle(&mut self, id: i64, pos: Vector2, radius: f32) {
        self.add_obstacle_impl(id as i32, pos, radius);
    }

    #[func]
    fn remove_obstacle(&mut self, id: i64) {
        self.remove_obstacle_impl(id as i32);
    }

    #[func]
    pub(crate) fn clear_obstacles(&mut self) {
        self.clear_obstacles_impl();
    }

    #[func]
    pub(crate) fn get_last_fail_stage_name(&self) -> GString {
        GString::from(Self::fail_stage_name(self.last_fail_stage.get()))
    }

    #[func]
    pub(crate) fn did_last_query_ignore_threats(&self) -> bool {
        self.last_query_ignored_threats.get()
    }

    /// No portal nodes in this design; returns 0 for backward compatibility.
    #[func]
    pub(crate) fn get_node_count(&self) -> i32 {
        0
    }

    #[func]
    pub(crate) fn get_cluster_count(&self) -> i32 {
        self.clusters.len() as i32
    }

    #[func]
    pub(crate) fn get_sub_cluster_count(&self) -> i32 {
        self.sub_clusters.len() as i32
    }

    #[func]
    pub(crate) fn get_debug_threat_clusters(&self) -> Array<VarDictionary> {
        self.get_debug_threat_clusters_impl()
    }

    #[func]
    pub(crate) fn get_perf_metrics(&self) -> VarDictionary {
        self.get_perf_metrics_impl()
    }

    #[func]
    pub(crate) fn reset_perf_metrics(&mut self) {
        self.reset_perf_metrics_impl();
    }

    #[func]
    fn set_perf_tracking_enabled(&mut self, enabled: bool) {
        self.perf_tracking_enabled = enabled;
    }
}
