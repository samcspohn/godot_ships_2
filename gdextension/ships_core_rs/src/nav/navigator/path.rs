use godot::prelude::*;

use super::{
    ShipNavigator, PATH_CLEAR_MAX_SEGMENTS, PATH_COMPARE_SAMPLES, PATH_NEAR_FIELD_TCR,
    SWITCH_BASE_TCR, SWITCH_COMMIT_TCR, SWITCH_FORK_TCR, SWITCH_MIN_SEP_TCR,
    SWITCH_SEPARATION_GAIN,
};
use crate::nav::types::{angle_difference, clamp_f, waypoint_flags, PathResult};

impl ShipNavigator {
    /// How far ahead stickiness applies. See PATH_NEAR_FIELD_TCR.
    pub(crate) fn get_near_field_range(&self) -> f32 {
        self.params.turning_circle_radius.max(1.0) * PATH_NEAR_FIELD_TCR
    }

    /// The part of `p` the ship has yet to sail, as a bare polyline prefixed
    /// with the ship's own position. Nothing is synthesised onto the end.
    pub(crate) fn remaining_path(&self, p: &PathResult, from_index: i32) -> Vec<Vector2> {
        let mut out = vec![self.state.position];
        let start = from_index.max(0);
        for i in start..p.waypoints.len() as i32 {
            let wp = p.waypoints[i as usize];
            if out.last().unwrap().distance_to(wp) > 1.0 {
                out.push(wp);
            }
        }
        out
    }

    /// `p` clipped to the first `max_len` metres of arclength.
    pub(crate) fn truncate_path(p: &[Vector2], max_len: f32) -> Vec<Vector2> {
        let mut out = Vec::new();
        if p.is_empty() {
            return out;
        }
        out.push(p[0]);
        let mut acc = 0.0f32;
        for i in 0..p.len() - 1 {
            let seg = p[i].distance_to(p[i + 1]);
            if acc + seg >= max_len {
                let t = if seg > 1e-6 { (max_len - acc) / seg } else { 0.0 };
                out.push(p[i].lerp(p[i + 1], clamp_f(t, 0.0, 1.0)));
                return out;
            }
            acc += seg;
            out.push(p[i + 1]);
        }
        out
    }

    /// Resample a polyline to `n` points at uniform arclength fractions, so two
    /// routes of different lengths can be compared point-for-point.
    pub(crate) fn resample_path(p: &[Vector2], n: i32, out: &mut Vec<Vector2>) {
        out.clear();
        if n < 2 {
            return;
        }
        if p.len() < 2 {
            let fill = if p.is_empty() { Vector2::ZERO } else { p[0] };
            out.resize(n as usize, fill);
            return;
        }

        let mut cum = vec![0.0f32; p.len()];
        for i in 1..p.len() {
            cum[i] = cum[i - 1] + p[i - 1].distance_to(p[i]);
        }

        let total = *cum.last().unwrap();
        if total <= 1e-3 {
            out.resize(n as usize, p[0]);
            return;
        }

        out.reserve(n as usize);
        let mut seg: usize = 0;
        for k in 0..n {
            let d = total * k as f32 / (n - 1) as f32;
            while seg + 2 < p.len() && cum[seg + 1] < d {
                seg += 1;
            }
            let seg_len = cum[seg + 1] - cum[seg];
            let t = if seg_len > 1e-6 { (d - cum[seg]) / seg_len } else { 0.0 };
            out.push(p[seg].lerp(p[seg + 1], clamp_f(t, 0.0, 1.0)));
        }
    }

    /// Polyline length plus the initial heading error charged at the turning
    /// circle radius. Cluster A* has no idea which way the ship is pointing, so
    /// a shorter route that demands a 180 is not the cheaper one.
    pub(crate) fn path_travel_cost(&self, p: &[Vector2]) -> f32 {
        if p.len() < 2 {
            return 0.0;
        }

        let mut cost = 0.0f32;
        for i in 0..p.len() - 1 {
            cost += p[i].distance_to(p[i + 1]);
        }

        // Bearing off the first point that is far enough away to define one.  The
        // leg to the very next waypoint can be a metre long when the ship is on top
        // of it, and a bearing taken from that is noise — which would make this
        // cost jitter between replans and reintroduce exactly the churn the
        // switching margin exists to damp.
        let bearing_min_leg = self.get_ship_clearance().max(1.0);
        for i in 1..p.len() {
            let ahead = p[i] - p[0];
            if ahead.length() < bearing_min_leg && i + 1 < p.len() {
                continue;
            }
            if ahead.length_squared() <= 1e-6 {
                break;
            }
            let bearing = ahead.x.atan2(ahead.y);
            cost += angle_difference(self.state.heading, bearing).abs()
                * self.params.turning_circle_radius;
            break;
        }
        cost
    }

    /// True when every leg of `p` clears terrain at the hull clearance. Terrain
    /// only, deliberately: threats and dynamic obstacles move every frame, and
    /// letting them expire a route here would reintroduce the churn this
    /// mechanism exists to remove.
    pub(crate) fn is_path_terrain_clear(&self, p: &[Vector2]) -> bool {
        let map = match self.map.as_ref() {
            Some(m) => m,
            None => return true, // nothing to check against
        };
        let map = map.bind();
        if !map.is_built() {
            return true;
        }

        let n = p.len() as i32 - 1; // segment count
        if n < 1 {
            return true;
        }

        let cl = self.get_ship_clearance();

        // Final leg first, then the capped forward walk.  Ordering it this way
        // keeps the segment cap from silently skipping the approach to the
        // destination on a long route, which is the leg terrain is most likely to
        // have invalidated.
        if map
            .raycast_internal(p[(n - 1) as usize], p[n as usize], cl)
            .hit
        {
            return false;
        }

        let segments = (n - 1).min(PATH_CLEAR_MAX_SEGMENTS);
        for i in 0..segments {
            if map
                .raycast_internal(p[i as usize], p[(i + 1) as usize], cl)
                .hit
            {
                return false;
            }
        }
        true
    }

    pub(crate) fn accept_plan_result(&mut self, forward_result: &PathResult) {
        if forward_result.valid && !forward_result.waypoints.is_empty() {
            // The plan's first waypoint is usually the ship's own position; start
            // on the second when so, or the follower spends a frame steering at
            // where it already is.
            let mut new_wp_idx: i32 = 0;
            if forward_result.waypoints.len() > 1
                && self
                    .state
                    .position
                    .distance_to(forward_result.waypoints[0])
                    < self.params.turning_circle_radius * 0.25
            {
                new_wp_idx = 1;
            }

            let mut should_accept = true;

            // An incumbent is only a candidate while it still ends where the ship is
            // currently being sent.  Once the destination has moved, the stored
            // route goes somewhere else, and the follower consumes its waypoints
            // before it ever looks at target.position — so keeping it would sail
            // the ship to the old point.  There is nothing to repair here: the
            // fresh plan already routes to the new destination, string-pulled, and
            // the near-field bias has already made it stick to the corridor the
            // incumbent was defending.  Take it.
            let incumbent_on_target = self.path_valid
                && !self.current_path.waypoints.is_empty()
                && self
                    .current_path
                    .waypoints
                    .last()
                    .unwrap()
                    .distance_to(self.target.position)
                    <= self.get_reach_radius();

            if incumbent_on_target
                && self.current_path.waypoints.len() >= 2
                && forward_result.waypoints.len() >= 2
                && self.current_wp_index < self.current_path.waypoints.len() as i32
            {
                let old_rem = self.remaining_path(&self.current_path, self.current_wp_index);
                let new_rem = self.remaining_path(forward_result, new_wp_idx);

                // A route that no longer clears terrain is not a route.  Skipping
                // the comparison entirely in that case is what keeps every margin
                // below from being able to strand the ship.
                if old_rem.len() >= 2 && new_rem.len() >= 2 && self.is_path_terrain_clear(&old_rem)
                {
                    // Divergence is measured over the near field only, the same
                    // window the search bias runs in.  Two routes that agree for
                    // the next few turning circles and part company 8 km out
                    // demand identical steering now, and switching between them
                    // costs nothing — rejecting on a difference the ship will
                    // replan long before reaching it only keeps a worse route.
                    let near_range = self.get_near_field_range();
                    let old_near = ShipNavigator::truncate_path(&old_rem, near_range);
                    let new_near = ShipNavigator::truncate_path(&new_rem, near_range);

                    let mut a = Vec::new();
                    let mut b = Vec::new();
                    ShipNavigator::resample_path(&old_near, PATH_COMPARE_SAMPLES, &mut a);
                    ShipNavigator::resample_path(&new_near, PATH_COMPARE_SAMPLES, &mut b);

                    // Mean separation answers "how different is this route", and
                    // the first sample that exceeds a couple of hull widths says
                    // where along the old route the two part company.  Comparing
                    // at equal arclength fractions rather than by waypoint index
                    // is what makes this work at all: the two plans have no
                    // waypoints in common and rarely even the same count.
                    let fork_eps = self.get_ship_clearance() * 2.0;
                    let mut sep_sum = 0.0f32;
                    let mut fork_frac = 1.0f32;
                    let mut forked = false;
                    for i in 0..PATH_COMPARE_SAMPLES as usize {
                        let d = a[i].distance_to(b[i]);
                        sep_sum += d;
                        if !forked && d > fork_eps {
                            fork_frac = i as f32 / (PATH_COMPARE_SAMPLES - 1) as f32;
                            forked = true;
                        }
                    }
                    let separation = sep_sum / PATH_COMPARE_SAMPLES as f32;
                    self.path_last_divergence = separation;

                    let tcr = self.params.turning_circle_radius.max(1.0);

                    if separation >= tcr * SWITCH_MIN_SEP_TCR {
                        // Genuinely a different route.  Charge the switch and make
                        // it win on the merits.  Below the threshold it is the same
                        // route replanned, and taking it is free: identical
                        // steering, fresher obstacle and threat data.
                        //
                        // fork_frac indexes the near-field window the samples were
                        // taken over, so the distance to the split is a fraction of
                        // that window, not of the whole route.
                        let mut near_len = 0.0f32;
                        for i in 0..old_near.len() - 1 {
                            near_len += old_near[i].distance_to(old_near[i + 1]);
                        }
                        let fork_dist = fork_frac * near_len;

                        let mut switch_cost =
                            tcr * SWITCH_BASE_TCR + separation * SWITCH_SEPARATION_GAIN;

                        // A fork closer than a couple of turning radii is one the
                        // ship is already inside: it cannot reach the other branch
                        // from here without first sailing past the split, so
                        // switching now only points the bow between the two.  This
                        // is a steep price rather than a veto, so a route that is
                        // genuinely kilometres better can still buy its way out
                        // instead of the ship being pinned to a bad commitment.
                        if fork_dist < tcr * SWITCH_FORK_TCR {
                            switch_cost += tcr * SWITCH_COMMIT_TCR;
                        }

                        // Cost is weighed over the whole route, not the window: both
                        // end at the same destination (incumbent_on_target), so the
                        // totals are directly comparable, and a near-field detour
                        // that pays for itself further out should still win.
                        should_accept = self.path_travel_cost(&new_rem) + switch_cost
                            < self.path_travel_cost(&old_rem);
                    }
                }
            }

            if should_accept {
                self.current_path = forward_result.clone();
                self.path_valid = true;
                self.current_wp_index = new_wp_idx;
                self.path_switch_count += 1;
            } else {
                // The incumbent is kept exactly as it stands.  It only reached this
                // branch by already ending at the live destination, so there is no
                // stale tail to repair and nothing to synthesise onto it.
                self.path_switch_rejected += 1;
            }
        } else {
            // Path planning came back invalid (no route found or D* Lite not yet
            // converged to a solution).  Prefer keeping the previous path — the
            // ship can continue following a stale-but-valid route while the search
            // retries next frame.  Only fall back to the direct destination line
            // when there is no prior path at all (e.g. very first navigation call).
            if !self.path_valid || self.current_path.waypoints.is_empty() {
                let mut cp = PathResult::default();
                cp.waypoints.push(self.state.position);
                cp.waypoints.push(self.target.position);
                cp.flags.push(waypoint_flags::WP_NONE);
                cp.flags.push(waypoint_flags::WP_NONE);
                cp.valid = true;
                cp.total_distance = self.state.position.distance_to(self.target.position);
                self.current_path = cp;
                self.path_valid = true;
                self.current_wp_index = 1;
            }
            // else: keep current_path and path_valid unchanged
        }
    }

    pub(crate) fn advance_waypoint(&mut self) {
        if !self.path_valid || self.current_path.waypoints.is_empty() {
            return;
        }

        while self.current_wp_index < self.current_path.waypoints.len() as i32 {
            let wp = self.current_path.waypoints[self.current_wp_index as usize];
            if self.is_waypoint_reached(wp) {
                self.current_wp_index += 1;
            } else {
                break;
            }
        }

        let last_wp = self.current_path.waypoints.len() as i32 - 1;
        while self.current_wp_index < last_wp {
            let wp = self.current_path.waypoints[self.current_wp_index as usize];
            if self.is_waypoint_in_turning_dead_zone(wp) {
                self.current_wp_index += 1;
            } else {
                break;
            }
        }

        // Don't clamp back — let path_exhausted detect that all waypoints are consumed
    }

    pub(crate) fn is_waypoint_reached(&self, waypoint: Vector2) -> bool {
        let to_wp = waypoint - self.state.position;
        let dist = to_wp.length();

        let reach_radius = self.get_reach_radius();

        if dist < reach_radius {
            return true;
        }

        let forward = Vector2::new(self.state.heading.sin(), self.state.heading.cos());
        let along_track = to_wp.x * forward.x + to_wp.y * forward.y;

        // "Passed" check: waypoint is behind the ship AND we passed close to it.
        // The cross-track distance (perpendicular offset from the ship's track line)
        // must also be within reach_radius.  Without this guard, a waypoint that is
        // far away but almost perpendicular (barely behind the ship's equator) would
        // be wrongly marked as reached — causing the path to be consumed prematurely
        // and leaving the ship with no waypoints to steer toward.
        if along_track < 0.0 && dist < reach_radius * 2.0 {
            // cross_track = perpendicular distance from waypoint to ship's heading line
            let cross_track = (to_wp.x * forward.y - to_wp.y * forward.x).abs();
            return cross_track < reach_radius;
        }

        false
    }

    pub(crate) fn is_waypoint_in_turning_dead_zone(&self, waypoint: Vector2) -> bool {
        let r = self.params.turning_circle_radius;
        if r < 1.0 {
            return false;
        }

        let perp_x = self.state.heading.cos();
        let perp_z = -self.state.heading.sin();

        let center_starboard = Vector2::new(
            self.state.position.x + perp_x * r,
            self.state.position.y + perp_z * r,
        );
        let center_port = Vector2::new(
            self.state.position.x - perp_x * r,
            self.state.position.y - perp_z * r,
        );

        let dist_starboard = waypoint.distance_to(center_starboard);
        let dist_port = waypoint.distance_to(center_port);

        let threshold = r * 0.9;

        dist_starboard < threshold || dist_port < threshold
    }
}
