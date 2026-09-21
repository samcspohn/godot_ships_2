use godot::prelude::*;

use super::{HpaGraph, PerfStats};
use crate::nav::types::ThreatCircle;

/// In cost mode, exposure above this (effective distance under half the
/// concealment radius) is a wall; below it is only priced.
pub(crate) const COST_MODE_WALL_EXPOSURE: f32 = 0.5;

// stamp_threats / clear_threats / compute_debug_threat_clusters have no caller
// until ship_navigator lands (M3); it drives all three.
#[allow(dead_code)]
impl HpaGraph {
    /// Tests every navigable cluster: clusters within a threat circle that have
    /// line-of-sight to the threat origin are marked blocked.
    pub(crate) fn stamp_threats(&mut self, threats: &[ThreatCircle]) {
        for b in self.cluster_threat_blocked.iter_mut() {
            *b = 0;
        }
        for c in self.cluster_threat_cost.iter_mut() {
            *c = 0.0;
        }
        self.threat_cost_mode.set(false);
        self.threat_blocked_cids.clear();
        self.threat_blocked_count = 0;
        if threats.is_empty() || self.clusters.is_empty() || self.nav_map.is_none() {
            return;
        }

        let map = self.nav_map.as_ref().unwrap().bind();

        for t in threats {
            if t.radius <= 0.0 {
                continue;
            }

            let mut gx_t = ((t.origin.x - self.min_x) / self.cell_size) as i32;
            let mut gz_t = ((t.origin.y - self.min_z) / self.cell_size) as i32;
            gx_t = gx_t.max(0).min(self.grid_w - 1);
            gz_t = gz_t.max(0).min(self.grid_h - 1);

            let r2 = t.radius * t.radius;

            // Only candidate clusters whose AABB overlaps the threat circle are
            // worth testing — avoids the previous O(clusters × threats) sweep.
            let candidates = self.clusters_in_radius(t.origin, t.radius);
            for cid in candidates {
                let cidx = cid as usize;
                if self.cluster_threat_blocked[cidx] != 0 {
                    continue; // already blocked by another threat
                }
                let c = self.clusters[cidx];
                if !c.navigable {
                    continue;
                }

                // Grid coords of the 4 cluster corner cells.
                // Testing all corners (rather than just the centre) conservatively marks
                // clusters where the threat has line-of-sight to any part of the boundary.
                let corner_gx = [c.x0, c.x1, c.x0, c.x1];
                let corner_gz = [c.z0, c.z0, c.z1, c.z1];

                let mut threatened = false;
                for i in 0..4 {
                    if threatened {
                        break;
                    }
                    let (wx, wz) = self.grid_to_world(corner_gx[i], corner_gz[i]);
                    let dx = wx - t.origin.x;
                    let dz = wz - t.origin.y;
                    if dx * dx + dz * dz > r2 {
                        continue;
                    }

                    if map.line_of_sight(corner_gx[i], corner_gz[i], gx_t, gz_t, 0.0) {
                        threatened = true;
                    }
                }

                if threatened {
                    self.cluster_threat_blocked[cidx] = 1;
                    self.threat_blocked_cids.push(cid);
                }
            }
        }

        self.threat_blocked_count = self.threat_blocked_cids.len() as i32;
    }

    /// True when the macro cluster containing `point` would be marked blocked
    /// by `threats`.
    ///
    /// Pure query, like compute_debug_threat_clusters: it runs stamp_threats'
    /// per-cluster test for the one cluster the point falls in, against the
    /// caller's own threat list, and never reads or writes the shared
    /// `cluster_threat_blocked` array — which belongs to whichever ship stamped
    /// last, not necessarily the one asking.
    ///
    /// Cluster granularity, not a bare point-in-circle test, is deliberate:
    /// the cluster is the unit the router blocks, so a destination whose
    /// cluster is blocked is a goal inside the planner's own wall, and the
    /// strict pass fails there even when the exact point has no line of sight
    /// to any threat.
    pub(crate) fn point_in_threatened_cluster(
        &self,
        point: Vector2,
        threats: &[ThreatCircle],
    ) -> bool {
        if !self.built || threats.is_empty() || self.nav_map.is_none() {
            return false;
        }

        let gx = self.world_to_gx(point.x);
        let gz = self.world_to_gz(point.y);
        let cid = self.cluster_id(self.cell_cx(gx), self.cell_cz(gz));
        if cid < 0 || cid >= self.clusters.len() as i32 {
            return false;
        }
        let c = self.clusters[cid as usize];
        // Mirrors stamp_threats: an unnavigable cluster is never stamped, its
        // terrain is the thing keeping the ship out. The caller tests terrain
        // separately.
        if !c.navigable {
            return false;
        }

        let map = self.nav_map.as_ref().unwrap().bind();

        // Grid coords of the 4 cluster corner cells (mirrors stamp_threats).
        let corner_gx = [c.x0, c.x1, c.x0, c.x1];
        let corner_gz = [c.z0, c.z0, c.z1, c.z1];

        for t in threats {
            if t.radius <= 0.0 {
                continue;
            }

            let mut gx_t = ((t.origin.x - self.min_x) / self.cell_size) as i32;
            let mut gz_t = ((t.origin.y - self.min_z) / self.cell_size) as i32;
            gx_t = gx_t.max(0).min(self.grid_w - 1);
            gz_t = gz_t.max(0).min(self.grid_h - 1);

            let r2 = t.radius * t.radius;

            for i in 0..4 {
                let (wx, wz) = self.grid_to_world(corner_gx[i], corner_gz[i]);
                let dx = wx - t.origin.x;
                let dz = wz - t.origin.y;
                if dx * dx + dz * dz > r2 {
                    continue;
                }
                if map.line_of_sight(corner_gx[i], corner_gz[i], gx_t, gz_t, 0.0) {
                    return true;
                }
            }
        }

        false
    }

    pub(crate) fn clear_threats(&mut self) {
        for b in self.cluster_threat_blocked.iter_mut() {
            *b = 0;
        }
        for c in self.cluster_threat_cost.iter_mut() {
            *c = 0.0;
        }
        self.threat_cost_mode.set(false);
        self.threat_blocked_cids.clear();
        self.threat_blocked_count = 0;
        self.cluster_threat_dir.clear();
        self.sub_threat_dir.clear();
        if self.sub_layer_active.get() {
            for b in self.sub_threat_blocked.iter_mut() {
                *b = 0;
            }
            for c in self.sub_threat_cost.iter_mut() {
                *c = 0.0;
            }
            self.threat_blocked_sids.clear();
            self.sub_layer_active.set(false);
        }
    }

    /// Stamp from the detection field. A finite positive `gain` prices
    /// exposure at `gain * exposure` per step and walls only nodes deeper than
    /// COST_MODE_WALL_EXPOSURE; anything else walls every exposed node as
    /// stamp_threats does. The wall flags are the one thing the search, the
    /// refine legs and the string-puller all read, so they must agree here:
    /// a priced node that the segment test vetoed used to send every leg
    /// through the cell-level A*.
    ///
    /// `macro_mean` prices the abstract search and sets its wall; `sub_max`
    /// does both at sub-cluster resolution for refinement and string-pulling.
    /// `walled` false (the fire price) never flags a node: a shooter count
    /// is a price at any depth.
    pub(crate) fn stamp_threat_costs(&mut self, macro_max: &[f32], macro_mean: &[f32], sub_max: &[f32], gain: f32, walled: bool) {
        self.clear_threats();
        let cost_mode = gain.is_finite() && gain > 0.0;
        self.threat_cost_mode.set(cost_mode);
        let wall_at = if !walled { f32::INFINITY } else if cost_mode { COST_MODE_WALL_EXPOSURE } else { 0.0 };
        let n = self.clusters.len().min(macro_max.len()).min(macro_mean.len());
        for cid in 0..n {
            let (mx, mean) = (macro_max[cid], macro_mean[cid]);
            if mx <= 0.0 || !self.clusters[cid].navigable {
                continue;
            }
            let wall = if !walled { false } else if cost_mode { mean > wall_at } else { true };
            if wall {
                self.cluster_threat_blocked[cid] = 1;
                self.threat_blocked_cids.push(cid as i32);
            }
            if cost_mode {
                self.cluster_threat_cost[cid] = gain * mean;
            }
        }
        let ns = self.sub_clusters.len().min(sub_max.len());
        if ns > 0 {
            for sid in 0..ns {
                let e = sub_max[sid];
                if e <= 0.0 || !self.sub_clusters[sid].navigable {
                    continue;
                }
                if e > wall_at {
                    self.sub_threat_blocked[sid] = 1;
                    self.threat_blocked_sids.push(sid as i32);
                }
                if cost_mode {
                    self.sub_threat_cost[sid] = gain * e;
                }
            }
            self.sub_layer_active.set(true);
        }
        // threat_layer_active keys off this; with the sub layer it is the sub
        // walls that matter.
        self.threat_blocked_count = if ns > 0 {
            self.threat_blocked_sids.len() as i32
        } else {
            self.threat_blocked_cids.len() as i32
        };
    }

    /// Per-heading prices on top of stamp_threat_costs: gain x the
    /// presentation-weighted shooter count for a step on each FIRE_HEADINGS.
    pub(crate) fn stamp_threat_dirs(&mut self, macro_dir: &[[f32; 4]], sub_dir: &[[f32; 4]], gain: f32) {
        if !self.threat_cost_mode.get() {
            return;
        }
        let scale = |d: &[f32; 4]| [d[0] * gain, d[1] * gain, d[2] * gain, d[3] * gain];
        let n = self.clusters.len().min(macro_dir.len());
        self.cluster_threat_dir = macro_dir[..n].iter().map(scale).collect();
        let ns = self.sub_clusters.len().min(sub_dir.len());
        self.sub_threat_dir = if self.sub_layer_active.get() { sub_dir[..ns].iter().map(scale).collect() } else { Vec::new() };
    }

    /// Reads the currently-stamped global blocked state.
    pub(crate) fn get_debug_threat_clusters_impl(&self) -> Array<VarDictionary> {
        let mut out: Array<VarDictionary> = Array::new();
        if !self.built {
            return out;
        }
        for cid in 0..self.clusters.len() {
            if self.cluster_threat_blocked[cid] == 0 {
                continue;
            }
            let cl = self.clusters[cid];
            let (wx0, wz0) = self.grid_to_world(cl.x0, cl.z0);
            let (wx1, wz1) = self.grid_to_world(cl.x1, cl.z1);
            let hc = self.cell_size * 0.5;
            let mut d = VarDictionary::new();
            d.set("x0", wx0 - hc);
            d.set("z0", wz0 - hc);
            d.set("x1", wx1 + hc);
            d.set("z1", wz1 + hc);
            out.push(&d);
        }
        out
    }

    /// Pure query: computes blocked clusters for the given threat set without
    /// touching `cluster_threat_blocked`.
    pub(crate) fn compute_debug_threat_clusters(
        &self,
        threats: &[ThreatCircle],
    ) -> Array<VarDictionary> {
        let mut out: Array<VarDictionary> = Array::new();
        if !self.built || threats.is_empty() || self.nav_map.is_none() {
            return out;
        }

        let map = self.nav_map.as_ref().unwrap().bind();

        for c in &self.clusters {
            if !c.navigable {
                continue;
            }

            // Grid coords of the 4 cluster corner cells (mirrors stamp_threats logic).
            let corner_gx = [c.x0, c.x1, c.x0, c.x1];
            let corner_gz = [c.z0, c.z0, c.z1, c.z1];

            let mut blocked = false;
            for t in threats {
                if t.radius <= 0.0 {
                    continue;
                }

                let mut gx_t = ((t.origin.x - self.min_x) / self.cell_size) as i32;
                let mut gz_t = ((t.origin.y - self.min_z) / self.cell_size) as i32;
                gx_t = gx_t.max(0).min(self.grid_w - 1);
                gz_t = gz_t.max(0).min(self.grid_h - 1);

                let r2 = t.radius * t.radius;

                for i in 0..4 {
                    if blocked {
                        break;
                    }
                    let (wx, wz) = self.grid_to_world(corner_gx[i], corner_gz[i]);
                    let dx = wx - t.origin.x;
                    let dz = wz - t.origin.y;
                    if dx * dx + dz * dz > r2 {
                        continue;
                    }

                    if map.line_of_sight(corner_gx[i], corner_gz[i], gx_t, gz_t, 0.0) {
                        blocked = true;
                    }
                }

                if blocked {
                    break;
                }
            }
            if !blocked {
                continue;
            }

            let (wx0, wz0) = self.grid_to_world(c.x0, c.z0);
            let (wx1, wz1) = self.grid_to_world(c.x1, c.z1);
            let hc = self.cell_size * 0.5;
            let mut d = VarDictionary::new();
            d.set("x0", wx0 - hc);
            d.set("z0", wz0 - hc);
            d.set("x1", wx1 + hc);
            d.set("z1", wz1 + hc);
            out.push(&d);
        }
        out
    }

    pub(crate) fn get_perf_metrics_impl(&self) -> VarDictionary {
        let perf = self.perf.borrow();
        let mut d = VarDictionary::new();
        d.set("query_count", perf.query_count as i64);
        d.set("success_count", perf.success_count as i64);
        d.set("failure_count", perf.failure_count as i64);

        d.set("last_total_us", perf.last_total_us);
        d.set("last_connect_us", perf.last_connect_us);
        d.set("last_abstract_us", perf.last_abstract_us);
        d.set("last_refine_us", perf.last_refine_us);
        d.set("last_start_connect_us", perf.last_start_connect_us);
        d.set("last_goal_connect_us", perf.last_goal_connect_us);

        d.set("avg_total_us", perf.avg_total_us);
        d.set("avg_connect_us", perf.avg_connect_us);
        d.set("avg_abstract_us", perf.avg_abstract_us);
        d.set("avg_refine_us", perf.avg_refine_us);

        d.set("max_total_us", perf.max_total_us);
        d.set("max_connect_us", perf.max_connect_us);
        d.set("max_abstract_us", perf.max_abstract_us);
        d.set("max_refine_us", perf.max_refine_us);

        d.set("last_connector_los_attempts", perf.last_connector_los_attempts);
        d.set("last_connector_los_hits", perf.last_connector_los_hits);
        d.set(
            "last_connector_local_search_runs",
            perf.last_connector_local_search_runs,
        );
        d.set(
            "last_connector_local_expansions",
            perf.last_connector_local_expansions,
        );
        d.set(
            "last_connector_portal_candidates",
            perf.last_connector_portal_candidates,
        );

        d.set("avg_connector_los_attempts", perf.avg_connector_los_attempts);
        d.set("avg_connector_los_hits", perf.avg_connector_los_hits);
        d.set(
            "avg_connector_local_search_runs",
            perf.avg_connector_local_search_runs,
        );
        d.set(
            "avg_connector_local_expansions",
            perf.avg_connector_local_expansions,
        );
        d.set(
            "avg_connector_portal_candidates",
            perf.avg_connector_portal_candidates,
        );

        d.set("grid_fallbacks", perf.grid_fallbacks as i64);
        d.set("spike_threshold_us", perf.spike_threshold_us);
        d.set("spike_count", perf.spike_count as i64);
        d.set("worst_spike_us", perf.worst_spike_us);

        let inv: f32 = if perf.window_queries > 0 {
            1.0 / (perf.window_queries as f32)
        } else {
            0.0
        };
        if inv > 0.0 {
            d.set("window_avg_total_us", perf.window_total_sum_us * inv);
            d.set("window_avg_connect_us", perf.window_connect_sum_us * inv);
            d.set("window_avg_abstract_us", perf.window_abstract_sum_us * inv);
            d.set("window_avg_refine_us", perf.window_refine_sum_us * inv);
        } else {
            d.set("window_avg_total_us", 0.0f32);
            d.set("window_avg_connect_us", 0.0f32);
            d.set("window_avg_abstract_us", 0.0f32);
            d.set("window_avg_refine_us", 0.0f32);
        }
        d
    }

    pub(crate) fn reset_perf_metrics_impl(&mut self) {
        let perf = self.perf.get_mut();
        let threshold = perf.spike_threshold_us;
        let report_interval = perf.report_interval_s;
        *perf = PerfStats::default();
        perf.spike_threshold_us = threshold;
        perf.report_interval_s = report_interval;
    }
}
