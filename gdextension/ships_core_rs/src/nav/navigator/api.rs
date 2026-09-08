use godot::prelude::*;

use super::{ShipNavigator, PERF_SPIKE_PHASE_COUNT, TORPEDO_VIRTUAL_CALIBER};
use crate::nav::threat::ThreatRegistry;
use crate::nav::types::{clamp_f, throttle_to_speed_fraction, DynamicObstacle};

impl ShipNavigator {
    pub(crate) fn set_ship_params_impl(
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
        self.params.turning_circle_radius = turning_circle_radius;
        self.params.rudder_response_time = rudder_response_time;
        self.params.acceleration_time = acceleration_time;
        self.params.deceleration_time = deceleration_time;
        self.params.max_speed = max_speed;
        self.params.reverse_speed_ratio = reverse_speed_ratio;
        self.params.ship_length = ship_length;
        self.params.ship_beam = ship_beam;
        self.params.turn_speed_loss = turn_speed_loss;
        self.params.linear_drag = linear_drag;
    }

    pub(crate) fn set_state_impl(
        &mut self,
        position: Vector3,
        velocity: Vector3,
        heading: f32,
        angular_velocity_y: f32,
        current_rudder: f32,
        current_speed: f32,
        delta: f32,
    ) {
        self.state.position = Vector2::new(position.x, position.z);
        self.state.velocity = Vector2::new(velocity.x, velocity.z);
        self.state.heading = heading;
        self.state.angular_velocity_y = angular_velocity_y;
        self.state.current_rudder = current_rudder;
        self.state.current_speed = current_speed;

        // Run state machine
        self.update(delta);
    }

    pub(crate) fn navigate_to_impl(
        &mut self,
        target: Vector3,
        heading: f32,
        hold_radius: f32,
        heading_tolerance: f32,
        heading_weight: f32,
        prefer_reverse: bool,
    ) {
        let new_pos = Vector2::new(target.x, target.z);
        self.target.position = new_pos;
        self.target.heading = heading;
        self.target.hold_radius = hold_radius;
        self.target.heading_tolerance = heading_tolerance;
        self.target.heading_weight = clamp_f(heading_weight, 0.0, 1.0);
        self.target.prefer_reverse = prefer_reverse;

        // navigate_to() is the synchronous planning trigger.
        self.run_plan_sync();
    }

    pub(crate) fn stop_impl(&mut self) {
        self.target.position = self.state.position;
        self.target.heading = self.state.heading;
        self.target.hold_radius = 0.0;
        self.path_valid = false;
        self.set_steering_output(0.0, 0, false);
    }

    pub(crate) fn set_health_fraction_impl(&mut self, fraction: f32) {
        // C++ uses std::max(0.0, std::min(f, 1.0)), which yields 0.0 for NaN;
        // clamp_f would pass NaN through. Keep the C++ shape.
        self.health_fraction = 0.0f32.max(fraction.min(1.0));
    }

    pub(crate) fn register_obstacle_impl(
        &mut self,
        id: i32,
        position: Vector2,
        velocity: Vector2,
        radius: f32,
        length: f32,
    ) {
        self.obstacles
            .insert(id, DynamicObstacle::new(id, position, velocity, radius, length));
        // Forward circular obstacle to HPA* for cluster-level blocking.
        // Use only ship_beam as the padding margin (not full ship clearance) since
        // HPA* is a high-level planner and fine-grained avoidance is handled by
        // the arc simulation.  Over-inflating the radius here causes ships to route
        // excessively far around other ships.
        let built = self.hpa_graph.as_ref().map_or(false, |g| g.bind().built);
        if built {
            let effective_radius = radius.max(length * 0.5) + self.params.ship_beam;
            self.hpa_graph
                .as_mut()
                .unwrap()
                .bind_mut()
                .add_obstacle_impl(id, position, effective_radius);
        }
    }

    pub(crate) fn update_obstacle_impl(&mut self, id: i32, position: Vector2, velocity: Vector2) {
        if let Some(obs) = self.obstacles.get_mut(&id) {
            obs.position = position;
            obs.velocity = velocity;
            // Keep heading updated from velocity; retain last known heading when parked.
            let vlen = (velocity.x * velocity.x + velocity.y * velocity.y).sqrt();
            if vlen > 0.5 {
                obs.heading = velocity.x.atan2(velocity.y);
            }
        }
        // Re-register obstacle at new position in HPA*
        let built = self.hpa_graph.as_ref().map_or(false, |g| g.bind().built);
        if built {
            // Find the original radius/length for this obstacle
            if let Some(obs) = self.obstacles.get(&id) {
                let effective_radius = obs.radius.max(obs.length * 0.5) + self.params.ship_beam;
                self.hpa_graph
                    .as_mut()
                    .unwrap()
                    .bind_mut()
                    .add_obstacle_impl(id, position, effective_radius);
            }
        }
    }

    pub(crate) fn remove_obstacle_impl(&mut self, id: i32) {
        self.obstacles.remove(&id);
        let built = self.hpa_graph.as_ref().map_or(false, |g| g.bind().built);
        if built {
            self.hpa_graph.as_mut().unwrap().bind_mut().remove_obstacle_impl(id);
        }
    }

    pub(crate) fn clear_obstacles_impl(&mut self) {
        self.obstacles.clear();
        let built = self.hpa_graph.as_ref().map_or(false, |g| g.bind().built);
        if built {
            self.hpa_graph.as_mut().unwrap().bind_mut().clear_obstacles_impl();
        }
    }

    pub(crate) fn set_threat_source_impl(
        &mut self,
        registry: Gd<ThreatRegistry>,
        team_id: i32,
        effective_radius: f32,
    ) {
        // `Gd<ThreatRegistry>` cannot be null the way `Ref<>` can in C++, so the
        // `registry.is_valid()` ternaries in the source always take the "valid"
        // branch here.
        let same_registry = match &self.threat_registry {
            Some(r) => *r == registry,
            None => false,
        };
        if same_registry
            && team_id == self.threat_team
            && (effective_radius - self.threat_radius).abs() < 0.01
        {
            return; // nothing about the subscription changed
        }
        self.threat_registry = Some(registry);
        self.threat_team = team_id;
        self.threat_radius = effective_radius;
        self.threats.borrow_mut().clear();
        self.threat_synced_version.set(0); // force a rebuild on next use
    }

    pub(crate) fn clear_threat_source_impl(&mut self) {
        self.threat_registry = None;
        self.threat_team = -1;
        self.threat_radius = 0.0;
        self.threats.borrow_mut().clear();
        self.threat_synced_version.set(0);
        // Clear the HPA* cluster-level threat layer immediately so paths are
        // no longer routed around the now-removed detection zones.
        let built = self.hpa_graph.as_ref().map_or(false, |g| g.bind().built);
        if built {
            self.hpa_graph.as_mut().unwrap().bind_mut().clear_threats();
        }
    }

    pub(crate) fn get_current_path_impl(&self) -> PackedVector3Array {
        let mut result = PackedVector3Array::new();
        if !self.path_valid || self.current_path.waypoints.is_empty() {
            return result;
        }

        let n = self.current_path.waypoints.len() as i32;
        let mut i = self.current_wp_index;
        while i < n {
            let wp = self.current_path.waypoints[i as usize];
            let mut flag_y: f32 = 0.0;
            if (i as usize) < self.current_path.flags.len() {
                flag_y = self.current_path.flags[i as usize] as f32;
            }
            result.push(Vector3::new(wp.x, flag_y, wp.y));
            i += 1;
        }
        result
    }

    pub(crate) fn get_predicted_trajectory_impl(&self) -> PackedVector3Array {
        let mut result = PackedVector3Array::new();
        for pt in &self.winning_arc {
            result.push(Vector3::new(pt.position.x, 0.0, pt.position.y));
        }
        result
    }

    pub(crate) fn get_current_waypoint_impl(&self) -> Vector3 {
        if self.path_valid && (self.current_wp_index as usize) < self.current_path.waypoints.len()
        {
            let wp = self.current_path.waypoints[self.current_wp_index as usize];
            return Vector3::new(wp.x, 0.0, wp.y);
        }
        Vector3::new(self.target.position.x, 0.0, self.target.position.y)
    }

    pub(crate) fn get_desired_heading_impl(&self) -> f32 {
        self.target.heading
    }

    pub(crate) fn is_arrived_impl(&self) -> bool {
        // Use the final waypoint in the path (always target.position after planning)
        // so arrival tracking is consistent with path state.  Falls back to
        // target.position if no path has been planned yet.
        let final_node = if self.path_valid && !self.current_path.waypoints.is_empty() {
            *self.current_path.waypoints.last().unwrap()
        } else {
            self.target.position
        };
        let arrived_radius = self.params.turning_circle_radius;
        self.state.position.distance_to(final_node) < arrived_radius
    }

    pub(crate) fn get_simulated_path_impl(&self) -> PackedVector3Array {
        self.get_predicted_trajectory_impl()
    }

    pub(crate) fn get_debug_torpedo_threat_points_impl(&self) -> VarArray {
        let mut result = VarArray::new();

        for obs in self.obstacles.values() {
            if !obs.is_torpedo() {
                continue;
            }

            let torp_speed = obs.velocity.length();
            if torp_speed < 1.0 {
                continue;
            }

            let torp_dir = obs.velocity / torp_speed;

            // Line emitted from torpedo nose for debug visualization (3000 m lookahead)
            const TORP_VIS_DIST: f32 = 3000.0;
            let line_start = obs.position;
            let line_end = obs.position + torp_dir * TORP_VIS_DIST;
            let line_center = obs.position + torp_dir * (TORP_VIS_DIST * 0.5);

            // Time until torpedo reaches closest point to ship
            let to_ship = self.state.position - obs.position;
            let mut t_closest = to_ship.dot(torp_dir) / torp_speed;
            if t_closest < 0.0 {
                t_closest = 0.0;
            }

            let mut d = VarDictionary::new();
            d.set("landing_x", line_center.x);
            d.set("landing_z", line_center.y);
            d.set("time_remaining", t_closest);
            d.set("caliber", TORPEDO_VIRTUAL_CALIBER);
            d.set("line_start_x", line_start.x);
            d.set("line_start_z", line_start.y);
            d.set("line_end_x", line_end.x);
            d.set("line_end_z", line_end.y);
            d.set("line_dir_x", torp_dir.x);
            d.set("line_dir_z", torp_dir.y);
            d.set("line_half_len", TORP_VIS_DIST * 0.5);
            d.set("is_torpedo", true);
            result.push(&d.to_variant());
        }

        result
    }

    pub(crate) fn get_debug_threat_clusters_impl(&self) -> Array<VarDictionary> {
        let built = self.hpa_graph.as_ref().map_or(false, |g| g.bind().built);
        if !built {
            return Array::new();
        }
        // Use the pure-query path so we always see THIS navigator's threat bin,
        // not whatever ship last stamped the shared cluster_threat_blocked_ array.
        self.refresh_threats();
        let threats = self.threats.borrow();
        if threats.is_empty() {
            return Array::new();
        }
        self.hpa_graph
            .as_ref()
            .unwrap()
            .bind()
            .compute_debug_threat_clusters(&threats)
    }

    pub(crate) fn get_threat_circle_count_impl(&self) -> i32 {
        self.refresh_threats();
        self.threats.borrow().len() as i32
    }

    pub(crate) fn debug_stamp_threats_impl(&mut self) {
        self.refresh_threats();
        let built = self.hpa_graph.as_ref().map_or(false, |g| g.bind().built);
        if !built {
            return;
        }
        let empty = self.threats.borrow().is_empty();
        if empty {
            self.hpa_graph.as_mut().unwrap().bind_mut().clear_threats();
            return;
        }
        let threats = self.threats.borrow().clone();
        self.hpa_graph.as_mut().unwrap().bind_mut().stamp_threats(&threats);
    }

    /// Pull this ship's circle list up to date with the registry. Cheap and
    /// idempotent: a version compare, and O(enemies) only when it moved.
    pub(crate) fn refresh_threats(&self) {
        if self.threat_registry.is_none() || self.threat_team < 0 || self.threat_radius <= 0.0 {
            if !self.threats.borrow().is_empty() {
                self.threats.borrow_mut().clear();
            }
            self.threat_synced_version.set(0);
            return;
        }
        let registry = self.threat_registry.as_ref().unwrap();
        let v = registry.bind().get_team_version(self.threat_team);
        if v == self.threat_synced_version.get() {
            return;
        }
        {
            let mut threats = self.threats.borrow_mut();
            registry
                .bind()
                .build_threats(self.threat_team, self.threat_radius, &mut threats);
        }
        self.threat_synced_version.set(v);
    }

    pub(crate) fn adjust_destination_for_threats_impl(
        &self,
        ship_pos: Vector2,
        dest: Vector2,
    ) -> VarDictionary {
        let mut out = VarDictionary::new();
        out.set("position", dest);
        out.set("adjusted", false);
        self.refresh_threats();
        if self.threats.borrow().is_empty() {
            return out;
        }
        let map_built = self.map.as_ref().map_or(false, |m| m.bind().is_built());
        if !map_built {
            return out;
        }
        let map = self.map.as_ref().unwrap();

        let mut adjusted = dest;
        let mut changed = false;

        // Iterative push: run up to 4 passes so a destination surrounded by
        // multiple overlapping threat circles eventually escapes.
        for _pass in 0..4 {
            let mut pushed = false;
            let threats = self.threats.borrow();
            for t in threats.iter() {
                if t.radius <= 0.0 {
                    continue;
                }
                let dx = adjusted.x - t.origin.x;
                let dz = adjusted.y - t.origin.y;
                let dist_sq = dx * dx + dz * dz;
                if dist_sq >= t.radius * t.radius {
                    continue;
                }
                // If terrain blocks LOS to this threat, the position is already hidden.
                let ray = map.bind().raycast_internal(adjusted, t.origin, 0.0);
                if ray.hit {
                    continue;
                }
                // Push the destination to just outside this threat circle.
                let dist = dist_sq.sqrt();
                let nx = if dist > 0.001 { dx / dist } else { 1.0 };
                let nz = if dist > 0.001 { dz / dist } else { 0.0 };
                adjusted = Vector2::new(
                    t.origin.x + nx * (t.radius + 100.0),
                    t.origin.y + nz * (t.radius + 100.0),
                );
                changed = true;
                pushed = true;
            }
            drop(threats);
            if !pushed {
                break; // stable — no further passes needed
            }
        }

        if changed {
            out.set("position", adjusted);
            out.set("adjusted", true);
        }
        let _ = ship_pos;
        out
    }

    pub(crate) fn get_perf_metrics_impl(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("tracking_enabled", self.perf_tracking_enabled);
        d.set("frame_count", self.perf_frame_count as i64);
        d.set("spike_threshold_us", self.perf_spike_threshold_us);
        d.set("report_interval_s", self.perf_report_interval_s);
        d.set("report_accum_s", self.perf_report_accum_s);
        let cur_phase = (self.perf_frame_count % PERF_SPIKE_PHASE_COUNT as u64) as usize;
        d.set("spike_phase_count", PERF_SPIKE_PHASE_COUNT as i32);
        d.set("spike_phase_warmup_samples", 3);
        d.set("current_phase_idx", cur_phase as i32);
        d.set("current_phase_samples", self.perf_phase_count[cur_phase] as i64);
        d.set("current_phase_avg_update_us", self.perf_phase_avg_update_us[cur_phase]);
        d.set("current_phase_avg_plan_us", self.perf_phase_avg_plan_us[cur_phase]);
        d.set(
            "current_phase_avg_avoidance_us",
            self.perf_phase_avg_avoidance_us[cur_phase],
        );
        d.set(
            "current_phase_avg_steering_us",
            self.perf_phase_avg_steering_us[cur_phase],
        );

        d.set("last_update_us", self.timing_update_us);
        d.set("last_plan_us", self.timing_plan_us);
        d.set("last_avoidance_us", self.timing_avoidance_us);
        d.set("last_steering_us", self.timing_steering_us);
        d.set("last_replan_reason", self.timing_replan_reason);
        d.set("last_plan_phase", self.timing_plan_phase_val);

        d.set("avg_update_us", self.perf_avg_update_us);
        d.set("avg_plan_us", self.perf_avg_plan_us);
        d.set("avg_avoidance_us", self.perf_avg_avoidance_us);
        d.set("avg_steering_us", self.perf_avg_steering_us);
        if self.perf_window_frame_count > 0 {
            let inv = 1.0 / self.perf_window_frame_count as f32;
            d.set("window_avg_update_us", self.perf_window_update_sum_us * inv);
            d.set("window_avg_plan_us", self.perf_window_plan_sum_us * inv);
            d.set(
                "window_avg_avoidance_us",
                self.perf_window_avoidance_sum_us * inv,
            );
            d.set(
                "window_avg_steering_us",
                self.perf_window_steering_sum_us * inv,
            );
        } else {
            d.set("window_avg_update_us", 0.0f32);
            d.set("window_avg_plan_us", 0.0f32);
            d.set("window_avg_avoidance_us", 0.0f32);
            d.set("window_avg_steering_us", 0.0f32);
        }

        d.set("max_update_us", self.perf_max_update_us);
        d.set("max_plan_us", self.perf_max_plan_us);
        d.set("max_avoidance_us", self.perf_max_avoidance_us);
        d.set("max_steering_us", self.perf_max_steering_us);

        d.set("update_spike_count", self.perf_update_spike_count as i64);
        d.set("plan_spike_count", self.perf_plan_spike_count as i64);
        d.set("avoidance_spike_count", self.perf_avoidance_spike_count as i64);
        d.set("steering_spike_count", self.perf_steering_spike_count as i64);

        d.set("worst_update_spike_us", self.perf_worst_update_spike_us);
        d.set("worst_plan_spike_us", self.perf_worst_plan_spike_us);
        d.set("worst_avoidance_spike_us", self.perf_worst_avoidance_spike_us);
        d.set("worst_steering_spike_us", self.perf_worst_steering_spike_us);

        d.set(
            "last_steering_candidates_total",
            self.perf_last_steering_candidates_total,
        );
        d.set(
            "last_steering_candidates_simulated",
            self.perf_last_steering_candidates_simulated,
        );
        d.set(
            "last_steering_terrain_rejects",
            self.perf_last_steering_terrain_rejects,
        );
        d.set(
            "last_steering_short_arc_rejects",
            self.perf_last_steering_short_arc_rejects,
        );
        d.set(
            "last_steering_arc_points_simulated",
            self.perf_last_steering_arc_points_simulated,
        );

        d
    }

    pub(crate) fn reset_perf_metrics_impl(&mut self) {
        let threshold = self.perf_spike_threshold_us;
        let report_interval = self.perf_report_interval_s;
        self.perf_frame_count = 0;
        self.perf_report_accum_s = 0.0;
        for i in 0..PERF_SPIKE_PHASE_COUNT {
            self.perf_phase_count[i] = 0;
            self.perf_phase_avg_update_us[i] = 0.0;
            self.perf_phase_avg_plan_us[i] = 0.0;
            self.perf_phase_avg_avoidance_us[i] = 0.0;
            self.perf_phase_avg_steering_us[i] = 0.0;
        }
        self.perf_window_frame_count = 0;
        self.perf_window_update_sum_us = 0.0;
        self.perf_window_plan_sum_us = 0.0;
        self.perf_window_avoidance_sum_us = 0.0;
        self.perf_window_steering_sum_us = 0.0;
        self.perf_avg_update_us = 0.0;
        self.perf_avg_plan_us = 0.0;
        self.perf_avg_avoidance_us = 0.0;
        self.perf_avg_steering_us = 0.0;
        self.perf_max_update_us = 0.0;
        self.perf_max_plan_us = 0.0;
        self.perf_max_avoidance_us = 0.0;
        self.perf_max_steering_us = 0.0;
        self.perf_update_spike_count = 0;
        self.perf_plan_spike_count = 0;
        self.perf_avoidance_spike_count = 0;
        self.perf_steering_spike_count = 0;
        self.perf_worst_update_spike_us = 0.0;
        self.perf_worst_plan_spike_us = 0.0;
        self.perf_worst_avoidance_spike_us = 0.0;
        self.perf_worst_steering_spike_us = 0.0;
        self.perf_last_steering_candidates_total = 0;
        self.perf_last_steering_candidates_simulated = 0;
        self.perf_last_steering_terrain_rejects = 0;
        self.perf_last_steering_short_arc_rejects = 0;
        self.perf_last_steering_arc_points_simulated = 0;
        self.perf_spike_threshold_us = threshold;
        self.perf_report_interval_s = report_interval;
    }

    pub(crate) fn set_perf_spike_threshold_us_impl(&mut self, threshold_us: f32) {
        self.perf_spike_threshold_us = threshold_us.max(0.0);
    }

    pub(crate) fn set_perf_tracking_enabled_impl(&mut self, enabled: bool) {
        self.perf_tracking_enabled = enabled;
    }

    // --- Derived scalars ---

    pub(crate) fn get_ship_clearance(&self) -> f32 {
        // `ship_length / 2.0` divides a float by a double literal, promoting the
        // whole expression to double; the double result is then narrowed back
        // to f32 on return. Mirrors `params.ship_length / 2.0 + get_safety_margin()`.
        (self.params.ship_length as f64 / 2.0 + self.get_safety_margin() as f64) as f32
    }

    pub(crate) fn get_soft_clearance(&self) -> f32 {
        let hard = self.get_ship_clearance();
        hard.max(self.params.turning_circle_radius) + self.get_safety_margin()
    }

    pub(crate) fn get_safety_margin(&self) -> f32 {
        self.params.ship_beam
    }

    pub(crate) fn get_lookahead_distance(&self) -> f32 {
        self.params.turning_circle_radius * 1.5
    }

    pub(crate) fn get_stopping_distance(&self) -> f32 {
        let max_decel = self.params.max_speed / self.params.acceleration_time.max(0.1);
        if max_decel < 0.001 {
            return 0.0;
        }
        (self.state.current_speed * self.state.current_speed) / (2.0 * max_decel)
    }

    pub(crate) fn throttle_to_speed(&self, throttle: i32) -> f32 {
        let fraction = throttle_to_speed_fraction(throttle);
        if fraction < 0.0 {
            return fraction * self.params.max_speed * self.params.reverse_speed_ratio;
        }
        fraction * self.params.max_speed
    }

    pub(crate) fn get_reach_radius(&self) -> f32 {
        // A waypoint is consumed once the ship is within one hull-length of it.
        // Using turning_circle_radius caused corner waypoints to be consumed a
        // full TCR before the ship reached the corner, starting turns too early.
        self.params.ship_length
    }

    pub(crate) fn set_steering_output(&mut self, rudder: f32, throttle: i32, collision: bool) {
        self.out_rudder = rudder;
        self.out_throttle = throttle;
        self.out_collision_imminent = collision;
    }
}
