use godot::prelude::*;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use super::{fail_stage::*, HpaGraph, PathBias, PATH_BIAS_FACTOR};
use crate::nav::types::{waypoint_flags::WP_NONE, PathResult};

/// The C++ keeps these as locals captured by a `[&]` closure. Rust cannot both
/// mutate the locals and call a closure borrowing them, so they are lifted into
/// a struct passed explicitly. Names kept for GDScript perf-metrics compat.
#[derive(Default)]
struct QueryMetrics {
    connect_us: f32,
    abstract_us: f32,
    refine_us: f32,
    start_connect_us: f32,
    goal_connect_us: f32,
    los_attempts: i32,
    los_hits: i32,
    local_search_runs: i32,
    local_expansions: i32,  // unused, kept for metric compat
    portal_candidates: i32, // unused, kept for metric compat
}

/// Everything `restore_endpoints` captured in the C++ closure.
struct RestoreCtx {
    true_from: Vector2,
    true_to: Vector2,
    start_snapped: bool,
    goal_snapped: bool,
    q_cl: f32,
    hug_cl: f32,
    threat_layer_active: bool,
}

fn micros_since(t0: Instant) -> f32 {
    t0.elapsed().as_secs_f64() as f32 * 1.0e6
}

impl HpaGraph {
    pub(crate) fn find_path(
        &self,
        from: Vector2,
        to: Vector2,
        query_clearance: f32,
        hug_clearance: f32,
        bias_path: Option<&Vec<Vector2>>,
    ) -> PathResult {
        self.last_query_ignored_threats.set(false);

        let mut bias = PathBias::default();
        if let Some(p) = bias_path {
            self.build_path_bias(p, &mut bias);
        }

        let r = self.find_path_query(from, to, query_clearance, hug_clearance, &bias);
        if r.valid || self.threat_blocked_count == 0 {
            return r;
        }

        // Strict pass failed with a threat layer stamped. Threat circles are a
        // routing preference, not terrain: a ship sitting inside enemy
        // detection coverage would otherwise be walled in by its own threat
        // bubble and keep following a stale path. Retry with threats muted so
        // it can at least move; the caller can inspect
        // did_last_query_ignore_threats().
        self.threats_muted.set(true);
        let r = self.find_path_query(from, to, query_clearance, hug_clearance, &bias);
        self.threats_muted.set(false);

        self.last_query_ignored_threats.set(r.valid);
        r
    }

    fn finalize_query(&self, r: PathResult, m: &QueryMetrics, t0: Instant) -> PathResult {
        if !self.perf_tracking_enabled {
            return r;
        }

        let total_us = micros_since(t0);
        let mut perf = self.perf.borrow_mut();

        perf.query_count += 1;
        if r.valid {
            perf.success_count += 1;
        } else {
            perf.failure_count += 1;
        }

        perf.last_total_us = total_us;
        perf.last_connect_us = m.connect_us;
        perf.last_abstract_us = m.abstract_us;
        perf.last_refine_us = m.refine_us;
        perf.last_start_connect_us = m.start_connect_us;
        perf.last_goal_connect_us = m.goal_connect_us;

        perf.last_connector_los_attempts = m.los_attempts;
        perf.last_connector_los_hits = m.los_hits;
        perf.last_connector_local_search_runs = m.local_search_runs;
        perf.last_connector_local_expansions = m.local_expansions;
        perf.last_connector_portal_candidates = m.portal_candidates;

        let first = perf.query_count <= 1;
        let ema = |ema: f32, sample: f32| if first { sample } else { ema * 0.9 + sample * 0.1 };
        perf.avg_total_us = ema(perf.avg_total_us, total_us);
        perf.avg_connect_us = ema(perf.avg_connect_us, m.connect_us);
        perf.avg_abstract_us = ema(perf.avg_abstract_us, m.abstract_us);
        perf.avg_refine_us = ema(perf.avg_refine_us, m.refine_us);
        perf.avg_connector_los_attempts = ema(perf.avg_connector_los_attempts, m.los_attempts as f32);
        perf.avg_connector_los_hits = ema(perf.avg_connector_los_hits, m.los_hits as f32);
        perf.avg_connector_local_search_runs =
            ema(perf.avg_connector_local_search_runs, m.local_search_runs as f32);
        perf.avg_connector_local_expansions =
            ema(perf.avg_connector_local_expansions, m.local_expansions as f32);
        perf.avg_connector_portal_candidates =
            ema(perf.avg_connector_portal_candidates, m.portal_candidates as f32);

        perf.max_total_us = perf.max_total_us.max(total_us);
        perf.max_connect_us = perf.max_connect_us.max(m.connect_us);
        perf.max_abstract_us = perf.max_abstract_us.max(m.abstract_us);
        perf.max_refine_us = perf.max_refine_us.max(m.refine_us);

        perf.window_queries += 1;
        perf.window_total_sum_us += total_us;
        perf.window_connect_sum_us += m.connect_us;
        perf.window_abstract_sum_us += m.abstract_us;
        perf.window_refine_sum_us += m.refine_us;

        if total_us >= perf.spike_threshold_us {
            perf.spike_count += 1;
            perf.worst_spike_us = perf.worst_spike_us.max(total_us);
            godot_print!(
                "[HpaGraph][SPIKE] total_us={} abstract_us={} refine_us={} los={}/{} local_paths={} spikes={}",
                total_us,
                m.abstract_us,
                m.refine_us,
                m.los_hits,
                m.los_attempts,
                m.local_search_runs,
                perf.spike_count as i64
            );
        }

        let now_wall_us = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_micros() as u64)
            .unwrap_or(0);
        if perf.last_report_wall_us == 0 {
            perf.last_report_wall_us = now_wall_us;
        }

        let mut report_interval_us = (perf.report_interval_s * 1000000.0) as u64;
        if report_interval_us == 0 {
            report_interval_us = 5000000;
        }

        if now_wall_us - perf.last_report_wall_us >= report_interval_us {
            let inv = if perf.window_queries > 0 { 1.0 / perf.window_queries as f32 } else { 0.0 };
            let mut elapsed_s = (now_wall_us - perf.last_report_wall_us) as f32 / 1000000.0;
            if elapsed_s <= 0.0 {
                elapsed_s = perf.report_interval_s;
            }
            let qps = perf.window_queries as f32 / elapsed_s;
            godot_print!(
                "[HpaGraph][AVG 5s] queries={} qps={} avg_total_us={} avg_abstract_us={} avg_refine_us={} max_total_us={} spike_count={}",
                perf.window_queries as i64,
                qps,
                perf.window_total_sum_us * inv,
                perf.window_abstract_sum_us * inv,
                perf.window_refine_sum_us * inv,
                perf.max_total_us,
                perf.spike_count as i64
            );
            perf.window_queries = 0;
            perf.window_total_sum_us = 0.0;
            perf.window_connect_sum_us = 0.0;
            perf.window_abstract_sum_us = 0.0;
            perf.window_refine_sum_us = 0.0;
            perf.last_report_wall_us = now_wall_us;
        }
        r
    }

    fn world_to_gx(&self, wx: f32) -> i32 {
        0.max((((wx - self.min_x) / self.cell_size) as i32).min(self.grid_w - 1))
    }

    fn world_to_gz(&self, wz: f32) -> i32 {
        0.max((((wz - self.min_z) / self.cell_size) as i32).min(self.grid_h - 1))
    }

    /// Snap an endpoint to the nearest cell navigable at `q_cl`.
    ///
    /// find_nearest_navigable validates in NavigationMap's index convention,
    /// where index i samples world (min + i*cell). HpaGraph's own
    /// grid_to_world() is cell-centred (min + (i+0.5)*cell), so converting the
    /// returned index with it lands half a cell away from the cell that was
    /// actually checked — at the hull minimum that is most of the margin, and
    /// the "snapped" endpoint comes back less navigable than the one rejected.
    /// Convert the way the validating side counts.
    fn snap_endpoint(&self, gx: &mut i32, gz: &mut i32, out: &mut Vector2, q_cl: f32) -> bool {
        let map = self.nav_map.as_ref().unwrap().bind();
        let (wx, wz) = self.grid_to_world(*gx, *gz);
        if map.get_distance_impl(wx, wz) >= q_cl {
            return true; // already clear
        }
        let (mut sx, mut sz) = (*gx, *gz);
        if !map.find_nearest_navigable(&mut sx, &mut sz, q_cl) {
            return false;
        }
        *gx = sx;
        *gz = sz;
        *out = Vector2::new(
            self.min_x + sx as f32 * self.cell_size,
            self.min_z + sz as f32 * self.cell_size,
        );
        true
    }

    /// Re-attach the caller's endpoints around a route planned between the
    /// snapped ones. Both extra legs are short and point away from land by
    /// construction (the snap walks up the SDF gradient).
    fn restore_endpoints(&self, mut r: PathResult, c: &RestoreCtx) -> PathResult {
        if !r.valid || r.waypoints.is_empty() {
            return r;
        }
        if r.flags.len() != r.waypoints.len() {
            r.flags = vec![WP_NONE; r.waypoints.len()];
        }
        let mut spliced = false;
        if c.start_snapped && r.waypoints[0].distance_to(c.true_from) > 1.0 {
            r.waypoints.insert(0, c.true_from);
            r.flags.insert(0, WP_NONE);
            spliced = true;
        }
        if c.goal_snapped && r.waypoints[r.waypoints.len() - 1].distance_to(c.true_to) > 1.0 {
            r.waypoints.push(c.true_to);
            r.flags.push(WP_NONE);
            spliced = true;
        }
        if spliced && r.waypoints.len() >= 3 {
            // The spliced legs never went through the pull, so the join between
            // a true endpoint and the planned route keeps whatever corner the
            // snap left there. Re-pull the whole polyline; the pass preserves
            // its endpoints and copies vertices verbatim where an endpoint sits
            // too close to land to see anything.
            let repulled =
                self.hug_string_pull(&r.waypoints, c.q_cl, c.hug_cl, c.threat_layer_active);
            if repulled.len() >= 2 {
                r.waypoints = repulled;
                r.flags = vec![WP_NONE; r.waypoints.len()];
            }
        }
        r.total_distance = 0.0;
        for i in 0..r.waypoints.len().saturating_sub(1) {
            r.total_distance += r.waypoints[i].distance_to(r.waypoints[i + 1]);
        }
        r
    }

    fn is_cluster_open(&self, cid: i32, q_cl: f32) -> bool {
        cid >= 0
            && cid < self.clusters.len() as i32
            && self.clusters[cid as usize].min_sdf >= q_cl
    }

    fn is_sub_open(&self, sid: i32, q_cl: f32) -> bool {
        sid >= 0
            && sid < self.sub_clusters.len() as i32
            && self.sub_clusters[sid as usize].min_sdf >= q_cl
    }

    /// Pick the open sub-cluster inside `cid` whose centre is closest to the
    /// chord prev_g -> next_g. Returns -1 if no open sub exists.
    fn best_open_sub_near_chord(
        &self,
        cid: i32,
        prev_g: Vector2,
        next_g: Vector2,
        q_cl: f32,
    ) -> i32 {
        let c = self.clusters[cid as usize];
        let mut best = -1i32;
        let mut best_d2 = f32::INFINITY;
        let dir = next_g - prev_g;
        let l2 = dir.x * dir.x + dir.y * dir.y;
        for scz in c.sub_z0..=c.sub_z1 {
            for scx in c.sub_x0..=c.sub_x1 {
                if scx >= self.nsubx || scz >= self.nsubz {
                    continue;
                }
                let sid = self.sub_id(scx, scz);
                if !self.is_sub_open(sid, q_cl) {
                    continue;
                }
                let s = self.sub_clusters[sid as usize];
                let p = Vector2::new(s.wx_center, s.wz_center);
                let d2 = if l2 > 1e-6 {
                    let dp = p - prev_g;
                    let t = (dp.x * dir.x + dp.y * dir.y) / l2;
                    let proj = prev_g + dir * t;
                    let e = p - proj;
                    e.x * e.x + e.y * e.y
                } else {
                    let e = p - prev_g;
                    e.x * e.x + e.y * e.y
                };
                if d2 < best_d2 {
                    best_d2 = d2;
                    best = sid;
                }
            }
        }
        best
    }

    pub(crate) fn find_path_query(
        &self,
        from: Vector2,
        to: Vector2,
        query_clearance: f32,
        hug_clearance: f32,
        bias: &PathBias,
    ) -> PathResult {
        let query_t0 = Instant::now();
        self.last_fail_stage.set(FAIL_NONE);

        let mut m = QueryMetrics::default();
        let no_path = PathResult::default();

        if !self.built {
            self.last_fail_stage.set(FAIL_NOT_BUILT);
            return self.finalize_query(no_path, &m, query_t0);
        }

        // Ship's actual clearance when provided; build-time default otherwise.
        let q_cl = if query_clearance > 0.0 { query_clearance } else { self.clearance };

        // Preferred stand-off for the string pull. Deliberately NOT clamped
        // against q_cl: the two are independent questions. q_cl decides which
        // channels exist at all; hug_cl decides where in a channel the route
        // sits, and is free to sit above or below it.
        let hug_cl = if hug_clearance > 0.0 { hug_clearance } else { q_cl };

        let mut from_gx = self.world_to_gx(from.x);
        let mut from_gz = self.world_to_gz(from.y);
        let mut to_gx = self.world_to_gx(to.x);
        let mut to_gz = self.world_to_gz(to.y);

        // Callers validate endpoints against the hull clearance, but we plan at
        // a larger margin. A start hugging a shoreline, or a goal inside that
        // margin, has no cell navigable at q_cl — cluster A* would treat its
        // own goal cluster as impassable. Snap each endpoint to the nearest
        // cell that *is* navigable at q_cl; the true endpoints are restored as
        // the first and last waypoints below.
        let mut plan_from = from;
        let mut plan_to = to;

        if !self.snap_endpoint(&mut from_gx, &mut from_gz, &mut plan_from, q_cl) {
            self.last_fail_stage.set(FAIL_START_SNAP);
            return self.finalize_query(no_path, &m, query_t0);
        }
        if !self.snap_endpoint(&mut to_gx, &mut to_gz, &mut plan_to, q_cl) {
            self.last_fail_stage.set(FAIL_GOAL_SNAP);
            return self.finalize_query(no_path, &m, query_t0);
        }

        let true_from = from;
        let true_to = to;
        let start_snapped = true_from.distance_to(plan_from) > 1.0;
        let goal_snapped = true_to.distance_to(plan_to) > 1.0;
        let from = plan_from;
        let to = plan_to;

        // threats_muted is set by the relaxed retry in find_path(); it has to
        // disable LOS rejection too, not just cluster blocking, or the retry
        // would still be walled in by the same threat circles.
        let threat_layer_active = self.threat_blocked_count > 0 && !self.threats_muted.get();

        let rctx = RestoreCtx {
            true_from,
            true_to,
            start_snapped,
            goal_snapped,
            q_cl,
            hug_cl,
            threat_layer_active,
        };

        let from_cid = self.cluster_id(self.cell_cx(from_gx), self.cell_cz(from_gz));
        let to_cid = self.cluster_id(self.cell_cx(to_gx), self.cell_cz(to_gz));

        // Step 1: direct LOS shortcut.
        m.los_attempts += 1;
        if self.los_clear(from, to, q_cl) && self.segment_threat_clear(from, to, threat_layer_active)
        {
            m.los_hits += 1;
            let mut r = PathResult::default();
            r.waypoints = vec![from, to];
            r.flags = vec![WP_NONE, WP_NONE];
            r.total_distance = from.distance_to(to);
            r.valid = true;
            let r = self.restore_endpoints(r, &rctx);
            return self.finalize_query(r, &m, query_t0);
        }

        // Step 2: build the guide-point sequence. Same macro -> sub A* within
        // from_cid; cross macro -> macro A* corridor plus per-macro sub
        // picking. Either way the result ends in `to` and feeds Step 5.
        // Only "open" intermediate centres are emitted; coastal stretches are
        // bridged by LOS / sub A* / cell A* in the connector.
        let from_sid = self.sub_id(self.cell_scx(from_gx), self.cell_scz(from_gz));
        let to_sid = self.sub_id(self.cell_scx(to_gx), self.cell_scz(to_gz));

        let mut guide: Vec<Vector2> = Vec::with_capacity(8);
        guide.push(from);

        // Per-macro 0/1 mask used by sub_cluster_astar to constrain corridor
        // searches. Sized once and shared by both branches below.
        let mut allowed_macros = vec![0u8; self.clusters.len()];

        // Corridor stickiness (see PathBias). None when the caller passed no
        // existing route, leaving every search below at its unbiased cost.
        let macro_bias: Option<&[u8]> = if bias.active { Some(&bias.macro_mask) } else { None };
        let sub_bias: Option<&[u8]> = if bias.active { Some(&bias.sub) } else { None };

        if from_cid == to_cid {
            // (a) Same macro — sub A* over this single macro, no corridor.
            allowed_macros[from_cid as usize] = 1;

            if from_sid != to_sid {
                let t_abs0 = Instant::now();
                let sub_path = self.sub_cluster_astar(
                    from_sid,
                    to_sid,
                    q_cl,
                    Some(&allowed_macros),
                    sub_bias,
                    PATH_BIAS_FACTOR,
                );
                m.abstract_us += micros_since(t_abs0);

                if sub_path.is_empty() {
                    let t0 = Instant::now();
                    let mut local = self.constrained_cell_astar(from, to, q_cl, &allowed_macros);
                    let mut reachable = true;
                    if !local.valid || local.waypoints.len() < 2 {
                        // Single macro, but no channel within it — search the
                        // full grid rather than declaring it unreachable.
                        let map = self.nav_map.as_ref().unwrap().bind();
                        reachable = map.is_reachable_impl(from, to, q_cl);
                        if reachable {
                            local = map.find_path_internal(from, to, q_cl, 0.0);
                        }
                    }
                    // Same treatment the cross-macro route gets:
                    // constrained_cell_astar greedily simplifies, so this
                    // arrives LOS-taut but never subdivided or relaxed, and
                    // would otherwise keep its raw cell-grid corners.
                    if local.valid && local.waypoints.len() >= 3 {
                        let pulled_local = self.hug_string_pull(
                            &local.waypoints,
                            q_cl,
                            hug_cl,
                            threat_layer_active,
                        );
                        if pulled_local.len() >= 2 {
                            local.waypoints = pulled_local;
                            local.flags = vec![WP_NONE; local.waypoints.len()];
                            local.total_distance = 0.0;
                            for k in 0..local.waypoints.len().saturating_sub(1) {
                                local.total_distance +=
                                    local.waypoints[k].distance_to(local.waypoints[k + 1]);
                            }
                        }
                    }
                    m.refine_us = micros_since(t0);
                    m.local_search_runs += 1;
                    if !local.valid {
                        self.last_fail_stage.set(if reachable {
                            FAIL_CONNECTOR_ASTAR
                        } else {
                            FAIL_SEPARATE_WATER
                        });
                    }
                    let r = self.restore_endpoints(local, &rctx);
                    return self.finalize_query(r, &m, query_t0);
                }

                for i in 1..sub_path.len().saturating_sub(1) {
                    let sid = sub_path[i];
                    if self.is_sub_open(sid, q_cl) {
                        let s = self.sub_clusters[sid as usize];
                        guide.push(Vector2::new(s.wx_center, s.wz_center));
                    }
                }
            }
            guide.push(to);
        } else {
            // (b) Cross macro — macro A* then sub-aware guide selection.
            let t_abs0 = Instant::now();
            let cluster_path =
                self.cluster_astar(from_cid, to_cid, q_cl, macro_bias, PATH_BIAS_FACTOR);
            m.abstract_us = micros_since(t_abs0);

            if cluster_path.is_empty() {
                self.last_fail_stage.set(FAIL_CLUSTER_ASTAR);
                return self.finalize_query(no_path, &m, query_t0);
            }

            // Corridor mask: every macro on the abstract path plus its 8
            // neighbours, giving the per-pair sub A* room to detour around
            // in-corridor terrain without ballooning into a global search.
            for &cid in &cluster_path {
                let cc = self.clusters[cid as usize];
                for dz in -1..=1 {
                    for dx in -1..=1 {
                        let nx = cc.cx + dx;
                        let nz = cc.cz + dz;
                        if nx < 0 || nx >= self.ncx || nz < 0 || nz >= self.ncz {
                            continue;
                        }
                        allowed_macros[self.cluster_id(nx, nz) as usize] = 1;
                    }
                }
            }

            for i in 1..cluster_path.len().saturating_sub(1) {
                let cid = cluster_path[i];
                if self.is_cluster_open(cid, q_cl) {
                    let c = self.clusters[cid as usize];
                    guide.push(Vector2::new(c.wx_center, c.wz_center));
                } else {
                    // Partly-coastal macro — promote its best open sub to a
                    // guide rather than skipping it. If no sub is open, fall
                    // back to skipping; the connector will bridge it.
                    let prev_g = *guide.last().unwrap();
                    // The C++ guards this with `i + 1 < cluster_path.size()`,
                    // which is the loop's own condition — its `next_g = to`
                    // fallback is unreachable, so it is not reproduced.
                    let nc = self.clusters[cluster_path[i + 1] as usize];
                    let next_g = Vector2::new(nc.wx_center, nc.wz_center);
                    let best_sid = self.best_open_sub_near_chord(cid, prev_g, next_g, q_cl);
                    if best_sid >= 0 {
                        let s = self.sub_clusters[best_sid as usize];
                        guide.push(Vector2::new(s.wx_center, s.wz_center));
                    }
                }
            }
            guide.push(to);
        }

        // Step 5: connect guide points. Per consecutive (A,B) pair:
        //   1. LOS at q_cl (+ threat) — cheapest.
        //   2. Sub A* in the corridor; emit its open intermediate sub centres.
        //   3. Cell A* — last resort, mostly when the route threads terrain.
        let t_ref0 = Instant::now();

        let mut waypoints: Vec<Vector2> = Vec::with_capacity(guide.len() * 4);
        waypoints.push(guide[0]);

        let merge_eps = self.cell_size * 0.1;

        for i in 1..guide.len() {
            let a = *waypoints.last().unwrap();
            let b = guide[i];

            let ax = self.world_to_gx(a.x);
            let az = self.world_to_gz(a.y);
            let bx = self.world_to_gx(b.x);
            let bz = self.world_to_gz(b.y);

            m.los_attempts += 1;
            let mut los_ok = self.los_clear(a, b, q_cl);
            if los_ok && threat_layer_active {
                los_ok = self.segment_threat_clear(a, b, threat_layer_active);
            }

            if los_ok {
                m.los_hits += 1;
                waypoints.push(b);
                continue;
            }

            // LOS failed — try sub A* across the corridor.
            let a_sid = self.sub_id(self.cell_scx(ax), self.cell_scz(az));
            let b_sid = self.sub_id(self.cell_scx(bx), self.cell_scz(bz));
            let mut sub_helped = false;

            if a_sid != b_sid {
                let sub_path = self.sub_cluster_astar(
                    a_sid,
                    b_sid,
                    q_cl,
                    Some(&allowed_macros),
                    sub_bias,
                    PATH_BIAS_FACTOR,
                );

                // Only worth using if the sub layer produced at least one open
                // detour point; otherwise the route is genuinely
                // terrain-threading and cell A* is the right tool.
                let mut open_intermediates = 0;
                for j in 1..sub_path.len().saturating_sub(1) {
                    if self.is_sub_open(sub_path[j], q_cl) {
                        open_intermediates += 1;
                    }
                }

                if !sub_path.is_empty() && open_intermediates > 0 {
                    let mut chain: Vec<Vector2> = Vec::with_capacity(sub_path.len());
                    for j in 1..sub_path.len().saturating_sub(1) {
                        let sid = sub_path[j];
                        if !self.is_sub_open(sid, q_cl) {
                            continue;
                        }
                        let s = self.sub_clusters[sid as usize];
                        let p = Vector2::new(s.wx_center, s.wz_center);
                        let prev = if chain.is_empty() { a } else { *chain.last().unwrap() };
                        if prev.distance_to(p) > merge_eps {
                            chain.push(p);
                        }
                    }
                    if chain.is_empty() || chain.last().unwrap().distance_to(b) > merge_eps {
                        chain.push(b);
                    }

                    // Non-open subs were skipped, so consecutive survivors are
                    // not necessarily adjacent: the straight line between two
                    // of them cuts across whatever the skipped sub contained,
                    // and a sub is "not open" precisely because it holds land.
                    // These centres are emitted as final waypoints, not
                    // advisory guides, so nothing downstream would catch it —
                    // the route would simply cross the island. Verify every
                    // link before committing; one failure drops the whole chain
                    // to the cell A* below, which is exact.
                    let mut chain_ok = true;
                    let mut prev = a;
                    for &p in &chain {
                        m.los_attempts += 1;
                        if !self.los_clear(prev, p, q_cl)
                            || !self.segment_threat_clear(prev, p, threat_layer_active)
                        {
                            chain_ok = false;
                            break;
                        }
                        m.los_hits += 1;
                        prev = p;
                    }

                    if chain_ok {
                        for &p in &chain {
                            waypoints.push(p);
                        }
                        sub_helped = true;
                    }
                }
            }

            if sub_helped {
                continue;
            }

            // Sub A* couldn't help — cell A* constrained to the HPA corridor.
            m.local_search_runs += 1;
            let mut local = self.constrained_cell_astar(a, b, q_cl, &allowed_macros);

            let mut segment_reachable = true;
            if !local.valid || local.waypoints.len() < 2 {
                // The corridor has no channel this ship fits through. Cluster
                // A* links two clusters when each merely *contains* a navigable
                // cell, so it happily bridges an isthmus no cell-level route
                // can cross. Retry the segment on the full grid before giving
                // up: a longer real route beats no route. The region test gates
                // the expensive search and stays silent when the two really are
                // separate bodies of water.
                let map = self.nav_map.as_ref().unwrap().bind();
                segment_reachable = map.is_reachable_impl(a, b, q_cl);
                if segment_reachable {
                    m.local_search_runs += 1;
                    local = map.find_path_internal(a, b, q_cl, 0.0);
                }
            }

            if local.valid && local.waypoints.len() >= 2 {
                for j in 1..local.waypoints.len() {
                    if waypoints.last().unwrap().distance_to(local.waypoints[j]) > merge_eps {
                        waypoints.push(local.waypoints[j]);
                    }
                }
            } else if i + 1 < guide.len() {
                // B is an intermediate guide point. The guide is advisory — a
                // sub centre picked near the chord can land on the far side of
                // an island — so drop it and let the next iteration route from
                // A to the following guide point instead.
                continue;
            } else {
                self.last_fail_stage.set(if segment_reachable {
                    FAIL_CONNECTOR_ASTAR
                } else {
                    FAIL_SEPARATE_WATER
                });
                return self.finalize_query(no_path, &m, query_t0);
            }
        }

        // Snap the exact destination.
        if !waypoints.is_empty() {
            let last = waypoints.len() - 1;
            if waypoints[last].distance_to(to) < merge_eps {
                waypoints[last] = to;
            } else if waypoints[last].distance_to(to) > merge_eps {
                waypoints.push(to);
            }
        }

        // Step 6: coastline-hugging pull at hug_cl. Unlike plain greedy LOS
        // simplification this may introduce waypoints that were not in the
        // assembled route, so corners come from the terrain rather than from
        // cluster centres.
        let pulled = self.hug_string_pull(&waypoints, q_cl, hug_cl, threat_layer_active);

        m.refine_us = micros_since(t_ref0);
        m.connect_us = m.start_connect_us + m.goal_connect_us; // 0 in new design

        if pulled.len() < 2 {
            self.last_fail_stage.set(FAIL_STRING_PULL);
            return self.finalize_query(no_path, &m, query_t0);
        }

        let mut result = PathResult::default();
        result.flags = vec![WP_NONE; pulled.len()];
        for i in 0..pulled.len().saturating_sub(1) {
            result.total_distance += pulled[i].distance_to(pulled[i + 1]);
        }
        result.waypoints = pulled;
        result.valid = true;

        let r = self.restore_endpoints(result, &rctx);
        self.finalize_query(r, &m, query_t0)
    }
}
