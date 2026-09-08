use std::f64::consts::PI;
use std::time::Instant;

use godot::prelude::*;

use super::{
    path_fail_reason, DesiredDirection, ShipNavigator, ALIGN_BOUNCE_RADIUS_DEFAULT,
    HUG_CLEARANCE_BUFFER, PATH_FAIL_WARN_INTERVAL, PERF_SPIKE_PHASE_COUNT, STUCK_MIN_SECS,
    STUCK_OVERRIDE_FACTOR, STUCK_OVERRIDE_MIN, STUCK_TCR_FACTOR,
};
use crate::nav::types::{
    angle_difference, clamp_f, lerp_f, normalize_angle, waypoint_flags, NavState, PathResult,
};

impl ShipNavigator {
    pub(crate) fn update(&mut self, delta: f32) {
        let t0 = Instant::now();

        if self.path_fail_warn_cooldown > 0.0 {
            self.path_fail_warn_cooldown = (self.path_fail_warn_cooldown - delta).max(0.0);
        }

        // Reset stage timings every frame so emergency-mode frames don't retain
        // stale NORMAL-mode values.
        self.timing_plan_us = 0.0;
        self.timing_avoidance_us = 0.0;
        self.timing_steering_us = 0.0;

        // Transition to EMERGENCY if grounded or SDF indicates on land,
        // but NOT if the ship is already at the destination within tolerance.
        if self.nav_state != NavState::Emergency {
            let dist_to_dest_check = self.state.position.distance_to(self.target.position);
            let arrived_radius_check = self.target.hold_radius.max(self.params.ship_beam * 2.0);
            let at_destination = dist_to_dest_check < arrived_radius_check;

            let mut enter_emergency = false;
            if self.grounded {
                enter_emergency = true;
            } else if let Some(map) = self.map.as_ref() {
                let map = map.bind();
                if map.is_built() {
                    let sdf =
                        map.get_distance_impl(self.state.position.x, self.state.position.y);
                    if sdf <= 0.0 {
                        enter_emergency = true;
                    }
                }
            }
            if enter_emergency && !at_destination {
                self.nav_state = NavState::Emergency;
                self.emergency_initialized = false;
            }
        }

        match self.nav_state {
            NavState::Normal => self.update_normal(delta),
            NavState::Emergency => self.update_emergency(delta),
        }

        self.timing_update_us = t0.elapsed().as_secs_f64() as f32 * 1.0e6;

        if !self.perf_tracking_enabled {
            return;
        }

        let phase_idx = (self.perf_frame_count % PERF_SPIKE_PHASE_COUNT as u64) as usize;
        let phase_samples = self.perf_phase_count[phase_idx];
        const PHASE_WARMUP_SAMPLES: u64 = 3;
        let phase_base_update_us = self.perf_phase_avg_update_us[phase_idx];
        let phase_base_plan_us = self.perf_phase_avg_plan_us[phase_idx];
        let phase_base_avoidance_us = self.perf_phase_avg_avoidance_us[phase_idx];
        let phase_base_steering_us = self.perf_phase_avg_steering_us[phase_idx];

        self.perf_frame_count += 1;
        let frame_count = self.perf_frame_count;
        let update_ema = |ema: &mut f32, sample: f32| {
            if frame_count <= 1 {
                *ema = sample;
            } else {
                *ema = *ema * 0.9 + sample * 0.1;
            }
        };

        update_ema(&mut self.perf_avg_update_us, self.timing_update_us);
        update_ema(&mut self.perf_avg_plan_us, self.timing_plan_us);
        update_ema(&mut self.perf_avg_avoidance_us, self.timing_avoidance_us);
        update_ema(&mut self.perf_avg_steering_us, self.timing_steering_us);

        self.perf_max_update_us = self.perf_max_update_us.max(self.timing_update_us);
        self.perf_max_plan_us = self.perf_max_plan_us.max(self.timing_plan_us);
        self.perf_max_avoidance_us = self.perf_max_avoidance_us.max(self.timing_avoidance_us);
        self.perf_max_steering_us = self.perf_max_steering_us.max(self.timing_steering_us);

        let mut spike = false;
        if phase_samples >= PHASE_WARMUP_SAMPLES {
            if self.timing_update_us >= phase_base_update_us + self.perf_spike_threshold_us {
                self.perf_update_spike_count += 1;
                self.perf_worst_update_spike_us =
                    self.perf_worst_update_spike_us.max(self.timing_update_us);
                spike = true;
            }
            if self.timing_plan_us >= phase_base_plan_us + self.perf_spike_threshold_us {
                self.perf_plan_spike_count += 1;
                self.perf_worst_plan_spike_us =
                    self.perf_worst_plan_spike_us.max(self.timing_plan_us);
                spike = true;
            }
            if self.timing_avoidance_us >= phase_base_avoidance_us + self.perf_spike_threshold_us {
                self.perf_avoidance_spike_count += 1;
                self.perf_worst_avoidance_spike_us =
                    self.perf_worst_avoidance_spike_us.max(self.timing_avoidance_us);
                spike = true;
            }
            if self.timing_steering_us >= phase_base_steering_us + self.perf_spike_threshold_us {
                self.perf_steering_spike_count += 1;
                self.perf_worst_steering_spike_us =
                    self.perf_worst_steering_spike_us.max(self.timing_steering_us);
                spike = true;
            }
        }

        let update_phase_ema = |avg: &mut f32, sample: f32| {
            if phase_samples == 0 {
                *avg = sample;
            } else {
                *avg = *avg * 0.9 + sample * 0.1;
            }
        };
        update_phase_ema(&mut self.perf_phase_avg_update_us[phase_idx], self.timing_update_us);
        update_phase_ema(&mut self.perf_phase_avg_plan_us[phase_idx], self.timing_plan_us);
        update_phase_ema(
            &mut self.perf_phase_avg_avoidance_us[phase_idx],
            self.timing_avoidance_us,
        );
        update_phase_ema(
            &mut self.perf_phase_avg_steering_us[phase_idx],
            self.timing_steering_us,
        );
        self.perf_phase_count[phase_idx] = phase_samples + 1;

        self.perf_window_frame_count += 1;
        self.perf_window_update_sum_us += self.timing_update_us;
        self.perf_window_plan_sum_us += self.timing_plan_us;
        self.perf_window_avoidance_sum_us += self.timing_avoidance_us;
        self.perf_window_steering_sum_us += self.timing_steering_us;
        if delta > 0.0 {
            self.perf_report_accum_s += delta;
        }

        if spike {
            godot_print!(
                "[ShipNavigator][SPIKE] bot={} phase={} phase_samples={} update_us={} plan_us={} avoid_us={} steering_us={} phase_base(update/plan/avoid/steer)={}/{}/{}/{} delta_threshold_us={} cand={}/{} terrain_rejects={} short_arcs={} arc_pts={} replan_reason={} nav_state={}",
                self.bot_id,
                phase_idx,
                phase_samples as i64,
                self.timing_update_us,
                self.timing_plan_us,
                self.timing_avoidance_us,
                self.timing_steering_us,
                phase_base_update_us,
                phase_base_plan_us,
                phase_base_avoidance_us,
                phase_base_steering_us,
                self.perf_spike_threshold_us,
                self.perf_last_steering_candidates_simulated,
                self.perf_last_steering_candidates_total,
                self.perf_last_steering_terrain_rejects,
                self.perf_last_steering_short_arc_rejects,
                self.perf_last_steering_arc_points_simulated,
                self.timing_replan_reason,
                self.nav_state as i32
            );
        }

        if self.perf_report_accum_s >= self.perf_report_interval_s && self.perf_window_frame_count > 0
        {
            let inv = 1.0f32 / self.perf_window_frame_count as f32;
            let mut phase_peak_update = 0.0f32;
            let mut phase_peak_plan = 0.0f32;
            let mut phase_peak_avoid = 0.0f32;
            let mut phase_peak_steer = 0.0f32;
            for i in 0..PERF_SPIKE_PHASE_COUNT {
                phase_peak_update = phase_peak_update.max(self.perf_phase_avg_update_us[i]);
                phase_peak_plan = phase_peak_plan.max(self.perf_phase_avg_plan_us[i]);
                phase_peak_avoid = phase_peak_avoid.max(self.perf_phase_avg_avoidance_us[i]);
                phase_peak_steer = phase_peak_steer.max(self.perf_phase_avg_steering_us[i]);
            }
            godot_print!(
                "[ShipNavigator][AVG 5s] bot={} frames={} avg_update_us={} avg_plan_us={} avg_avoid_us={} avg_steering_us={} phase_peak(update/plan/avoid/steer)={}/{}/{}/{} spikes(update/plan/avoid/steer)={}/{}/{}/{}",
                self.bot_id,
                self.perf_window_frame_count as i64,
                self.perf_window_update_sum_us * inv,
                self.perf_window_plan_sum_us * inv,
                self.perf_window_avoidance_sum_us * inv,
                self.perf_window_steering_sum_us * inv,
                phase_peak_update,
                phase_peak_plan,
                phase_peak_avoid,
                phase_peak_steer,
                self.perf_update_spike_count as i64,
                self.perf_plan_spike_count as i64,
                self.perf_avoidance_spike_count as i64,
                self.perf_steering_spike_count as i64
            );

            self.perf_window_frame_count = 0;
            self.perf_window_update_sum_us = 0.0;
            self.perf_window_plan_sum_us = 0.0;
            self.perf_window_avoidance_sum_us = 0.0;
            self.perf_window_steering_sum_us = 0.0;
            while self.perf_report_accum_s >= self.perf_report_interval_s {
                self.perf_report_accum_s -= self.perf_report_interval_s;
            }
        }
    }

    // ========================================================================
    // NORMAL state — path following + weighted avoidance
    // ========================================================================
    pub(crate) fn update_normal(&mut self, delta: f32) {
        // --- 0. Tick commitment timers ---
        if self.dodge_commitment_timer > 0.0 {
            self.dodge_commitment_timer -= delta;
            if self.dodge_commitment_timer <= 0.0 {
                self.dodge_commitment_timer = 0.0;
                self.dodge_committed_rudder = 0.0;
            }
        }

        // --- 1. Plan bookkeeping only (no replanning here) ---
        // Replanning is event-driven from navigate_to().  This keeps set_state()
        // lightweight and prevents periodic planning spikes in per-frame updates.
        self.timing_replan_reason = 0;
        self.timing_plan_phase_val = 0;
        self.timing_plan_us = 0.0;

        // --- 2. Advance waypoints ---
        if self.path_valid {
            self.advance_waypoint();
        }

        // --- 3. Compute desired rudder + magnitude + direction ---
        let mut desired_rudder: f32 = 0.0;
        let mut desired_magnitude: i32 = 4;
        let mut direction = DesiredDirection::Forward;

        let dist_to_dest = self.state.position.distance_to(self.target.position);

        // arrived_radius: close enough to consider "at the destination".
        // Respects hold_radius from the behavior (e.g. CA cover zone) with a
        // floor of ship_beam so the ship can actually reach the point.
        let arrived_radius = self.target.hold_radius.max(self.params.ship_beam * 2.0);

        // maneuver_radius: zone around the destination where the ship is allowed
        // to overshoot and perform multi-point turns to align heading.  The ship
        // may oscillate forward/reverse within this zone while aligning.
        // Always extends at least one TCR beyond arrived_radius so the intermediate
        // moderate-speed zone exists even when hold_radius is large.
        let maneuver_radius =
            arrived_radius + self.params.turning_circle_radius.max(self.get_stopping_distance());

        // approach_radius: outer zone where deceleration begins.
        // Set to TCR so the ship drives straight at the destination and only
        // begins alignment once it's within one turning circle.
        let approach_radius_inner = self
            .params
            .turning_circle_radius
            .max(self.get_stopping_distance() * 1.5);

        let path_exhausted =
            !self.path_valid || self.current_wp_index >= self.current_path.waypoints.len() as i32;

        // Detect when we're on the final waypoint segment — the ship should start
        // decelerating toward the destination before consuming the last waypoint,
        // not after blowing past it at full speed.
        let on_final_segment = !path_exhausted
            && self.current_wp_index == self.current_path.waypoints.len() as i32 - 1;

        // Determine the immediate steering target (destination — see C++ comment
        // block left in place above the equivalent line).
        let steer_target = self.target.position;

        // Determine desired direction: BACKWARD if the steering target is behind
        // the ship and within 3.5 × turning circle radius
        if self.is_target_behind_within_reverse_zone(steer_target) {
            direction = DesiredDirection::Backward;
        }

        // Honor the behavior's explicit reverse request.  Force BACKWARD for the
        // en-route and approach phases.  The maneuver and arrived zones govern
        // their own direction internally (heading alignment overrides there).
        if self.target.prefer_reverse {
            direction = DesiredDirection::Backward;
        }

        // Heading error to desired heading at destination
        let heading_error = angle_difference(self.state.heading, self.target.heading).abs();
        let heading_aligned = heading_error < self.target.heading_tolerance;

        if (path_exhausted || on_final_segment) && dist_to_dest < approach_radius_inner {
            // Approaching / maneuvering at destination.
            // Triggered on the final waypoint segment OR after path is consumed.
            //
            // Three zones (inside → outside):
            //   1. arrived_radius:   close enough AND heading aligned → stop
            //   2. maneuver_radius:  multi-point turn zone — overshoot allowed,
            //                        oscillate fwd/rev to align heading
            //   3. approach_radius:  decelerate toward destination

            if dist_to_dest < arrived_radius && heading_aligned {
                // Arrived AND aligned: stop
                desired_rudder = self.compute_rudder_to_heading(self.target.heading, false);
                desired_magnitude = 0;
                direction = DesiredDirection::Forward;
                self.align_commit_active = false;
            } else if dist_to_dest < maneuver_radius {
                // Inside the maneuver zone — multi-point turn.
                // Priority: align heading.  Use position only to prevent
                // drifting too far from the destination.
                //
                // Strategy:
                //   - Always steer toward the desired heading
                //   - Creep forward/backward to give the rudder water flow
                //   - If destination is behind, reverse toward it (which also
                //     turns the ship); if ahead, go forward
                //   - The ship naturally oscillates: overshoot forward → reverse
                //     back → overshoot reverse → forward again, each pass
                //     closing the heading error.

                // Determine which direction moves us back toward the destination
                let to_dest = self.target.position - self.state.position;
                let fwd_x = self.state.heading.sin();
                let fwd_z = self.state.heading.cos();
                let dest_along = to_dest.x * fwd_x + to_dest.y * fwd_z;
                let dest_ahead = dest_along >= 0.0;

                if dist_to_dest < arrived_radius {
                    // Inside arrived zone but heading not aligned — scale throttle to
                    // heading error so the rudder has enough authority to turn quickly.
                    // Large misalignment demands more speed; near-aligned ships creep.
                    if heading_error > (PI / 4.0) as f32 {
                        desired_magnitude = 3; // >45°: aggressive turn
                    } else if heading_error > (PI / 8.0) as f32 {
                        desired_magnitude = 2; // >22.5°: moderate turn
                    } else {
                        desired_magnitude = 1; // close to aligned: creep
                    }

                    // Option A: pick the direction that gives full rudder authority for
                    // the needed heading correction, ignoring dest_along.  At tiny
                    // distances dest_along is noise and flipping it inverts the rudder,
                    // cancelling the turn every frame.
                    let rudder_fwd = self.compute_rudder_to_heading(self.target.heading, false);
                    let rudder_rev = self.compute_rudder_to_heading(self.target.heading, true);
                    let best_dir = if rudder_fwd.abs() >= rudder_rev.abs() {
                        DesiredDirection::Forward
                    } else {
                        DesiredDirection::Backward
                    };

                    // Option B: commit to that direction until the ship has traveled
                    // one bounce radius from where the direction was chosen.  Each
                    // stroke of the multi-point turn completes naturally before the
                    // direction is reconsidered; sizing to ship_beam gives a distance
                    // that scales with the vessel.
                    let bounce_radius =
                        self.params.turning_circle_radius.max(ALIGN_BOUNCE_RADIUS_DEFAULT);
                    if !self.align_commit_active
                        || self.state.position.distance_to(self.align_commit_pos) >= bounce_radius
                    {
                        self.align_committed_dir = best_dir;
                        self.align_commit_pos = self.state.position;
                        self.align_commit_active = true;
                    }
                    direction = self.align_committed_dir;
                } else {
                    // Drifted within maneuver zone — head back toward destination
                    // at moderate speed while turning.  dest_along is reliable here
                    // (ship is meaningfully displaced from the destination).
                    desired_magnitude = 2;
                    direction = if dest_ahead {
                        DesiredDirection::Forward
                    } else {
                        DesiredDirection::Backward
                    };
                    self.align_commit_active = false; // reset alignment commit when outside arrived zone
                }

                let reversing = direction == DesiredDirection::Backward;
                if dist_to_dest < arrived_radius {
                    // Inside arrived zone but heading wrong: pure heading alignment.
                    desired_rudder = self.compute_rudder_to_heading(self.target.heading, reversing);
                } else {
                    // Outside arrived zone: steer toward the destination position so a
                    // perpendicular or lateral offset is corrected.  Heading alignment
                    // happens naturally once the ship is within arrived_radius.
                    desired_rudder = self.compute_rudder_to_position(self.target.position, reversing);
                }
            } else {
                // Approach zone: decelerate toward destination.
                // Steer toward the destination position (not just the arrival heading)
                // so the ship doesn't sail past a destination that is perpendicular
                // to its current heading.
                let reversing_approach = self.target.prefer_reverse;
                desired_rudder =
                    self.compute_rudder_to_position(self.target.position, reversing_approach);
                desired_magnitude = self.compute_magnitude_for_approach(dist_to_dest);
                direction = if reversing_approach {
                    DesiredDirection::Backward
                } else {
                    DesiredDirection::Forward
                };
            }
        } else if !path_exhausted {
            if direction == DesiredDirection::Backward {
                // Waypoint behind in reverse zone: reverse toward it at full magnitude
                desired_rudder = self.compute_rudder_to_position(steer_target, true);
                desired_magnitude = 4;
            } else {
                // Pure pursuit toward next waypoint — full speed forward
                desired_rudder = self.compute_pure_pursuit_rudder();
                desired_magnitude = 4;
            }
        } else {
            // No path or beyond approach zone — steer directly to destination
            if direction == DesiredDirection::Backward && dist_to_dest > self.params.ship_beam {
                desired_rudder = self.compute_rudder_to_position(self.target.position, true);
                desired_magnitude = 4;
            } else {
                desired_rudder = self.compute_rudder_to_position(self.target.position, false);
                desired_magnitude = 4;
            }
        }

        // Resolve direction + magnitude into a throttle value for the rest of the pipeline
        let mut desired_throttle = self.resolve_throttle(direction, desired_magnitude);

        // --- 3.5. Heading weight: blend desired_rudder toward target heading ---
        // When heading_weight > 0 the behavior wants the ship to orient at a specific
        // angle (e.g. broadside) rather than simply navigate to the destination.
        // Blending desired_rudder here shifts the candidate distribution in
        // select_best_steering so arcs centered on the heading-pursuit rudder are
        // evaluated first.  At weight = 1 we also ensure the ship keeps enough
        // throttle to maintain steerage way.
        if self.target.heading_weight > 0.001 {
            let reversing_now = direction == DesiredDirection::Backward;
            let heading_rudder = self.compute_rudder_to_heading(self.target.heading, reversing_now);
            desired_rudder = lerp_f(desired_rudder, heading_rudder, self.target.heading_weight);
            if self.target.heading_weight >= 0.999 {
                // Full heading pursuit — keep ship moving so the rudder has authority.
                if desired_magnitude < 2 {
                    desired_magnitude = 2;
                    direction = DesiredDirection::Forward;
                }
                desired_throttle = self.resolve_throttle(direction, desired_magnitude);
            }
        }

        // --- 4. Scored candidate steering ---
        // One unified function replaces terrain-aware rudder, avoidance blending,
        // and stuck detection.  Every candidate rudder/throttle pair is simulated
        // and scored; the best one wins.  No blending of untested values.
        let avoid_t0 = Instant::now();

        let choice = self.select_best_steering(desired_rudder, desired_throttle);

        self.timing_avoidance_us = avoid_t0.elapsed().as_secs_f64() as f32 * 1.0e6;
        self.timing_steering_us = self.timing_avoidance_us;

        // --- 4.1. Stuck / bow-in detection ---
        // Detect when the navigator wants to reverse (destination is directly behind)
        // but incoming shell threats keep overriding to forward candidates, keeping
        // the ship bow-in toward the target it can't reach.
        //
        // Key insight: a forward turn-around does NOT trigger this — during a u-turn
        // desired_throttle is forward, so nav and steering AGREE.  The conflict only
        // accumulates when nav explicitly wants reverse AND threats keep choosing forward.
        //
        // Once the conflict persists long enough (scaled by the ship's turnaround time),
        // stuck_override_active_ is set: shell threat budget is zeroed so the ship can
        // push through the incoming fire to execute the reverse maneuver.  Torpedo
        // threats still apply — the ship accepts shell risk, not torpedo risk.
        {
            let nav_wants_reverse = desired_throttle < 0;
            let threat_overrode_forward = choice.throttle >= 0 && nav_wants_reverse;

            // Scale threshold and override duration by the ship's turnaround time
            let turnaround_time =
                (PI as f32) * self.params.turning_circle_radius / self.params.max_speed.max(1.0);
            let stuck_threshold = STUCK_MIN_SECS.max(turnaround_time * STUCK_TCR_FACTOR);
            let override_dur = STUCK_OVERRIDE_MIN.max(turnaround_time * STUCK_OVERRIDE_FACTOR);

            // Tick down active override
            if self.stuck_override_timer > 0.0 {
                self.stuck_override_timer -= delta;
                if self.stuck_override_timer <= 0.0 {
                    self.stuck_override_timer = 0.0;
                    self.stuck_override_active = false;
                }
            }

            if threat_overrode_forward && !self.stuck_override_active {
                self.direction_conflict_timer += delta;
                if self.direction_conflict_timer >= stuck_threshold {
                    self.direction_conflict_timer = 0.0;
                    self.stuck_override_active = true;
                    self.stuck_override_timer = override_dur;
                    // Clear dodge commitment — we're breaking through, not dodging
                    self.dodge_committed_rudder = 0.0;
                    self.dodge_commitment_timer = 0.0;
                }
            } else if !threat_overrode_forward {
                // Progress being made: decay conflict timer at 2× rate
                self.direction_conflict_timer =
                    (self.direction_conflict_timer - delta * 2.0).max(0.0);
            }
        }

        let final_rudder = choice.rudder;
        let mut final_throttle = choice.throttle;

        // --- 4.5. Rudder-discrepancy throttle reduction ---
        // When the desired rudder is far from the current physical rudder position,
        // the ship will travel straight (at the old rudder) until the rudder catches
        // up, causing wide overshooting turns.  Reduce throttle proportionally to
        // the rudder discrepancy so the ship slows while the rudder moves into
        // position, giving tighter and more controlled turns.
        // Skip when: reversing or already slow.
        if final_throttle > 1 {
            let rudder_discrepancy = (final_rudder - self.state.current_rudder).abs();
            let discrepancy_threshold = 0.3f32; // below this, no reduction
            let discrepancy_full = 1.2f32; // at or above this, maximum reduction
            if rudder_discrepancy > discrepancy_threshold {
                let t = clamp_f(
                    (rudder_discrepancy - discrepancy_threshold)
                        / (discrepancy_full - discrepancy_threshold),
                    0.0,
                    1.0,
                );
                // At full discrepancy, reduce throttle by up to 2 steps, but never below 1
                let reduction = (t * 2.0).round() as i32;
                final_throttle = (final_throttle - reduction).max(1);
            }
        }

        self.set_steering_output(final_rudder, final_throttle, choice.collision_imminent);
    }

    // ========================================================================
    // EMERGENCY state — grounded or critical collision
    // ========================================================================
    pub(crate) fn update_emergency(&mut self, _delta: f32) {
        let map_missing_or_unbuilt = match self.map.as_ref() {
            None => true,
            Some(m) => !m.bind().is_built(),
        };
        if map_missing_or_unbuilt {
            let rudder = if self.state.angular_velocity_y > 0.0 { 1.0 } else { -1.0 };
            self.set_steering_output(rudder, -1, true);
            return;
        }

        // Record grounding position on first emergency frame
        if !self.emergency_initialized {
            self.emergency_grounding_pos = self.state.position;
            self.emergency_initialized = true;
        }

        // --- SDF and gradient at current position ---
        let (sdf_here, grad) = {
            let m = self.map.as_ref().unwrap().bind();
            let sdf = m.get_distance_impl(self.state.position.x, self.state.position.y);
            let grad = m.get_gradient_impl(self.state.position.x, self.state.position.y);
            (sdf, grad)
        };
        let grad_len = grad.length();

        // Normalised away-from-land direction (SDF gradient points away from land)
        let away_dir = if grad_len > 0.001 {
            grad / grad_len
        } else {
            // No gradient — fall back to direction away from grounding position
            let from_ground = self.state.position - self.emergency_grounding_pos;
            let from_ground_len = from_ground.length();
            if from_ground_len > 0.1 {
                from_ground / from_ground_len
            } else {
                // Perfectly on grounding spot with no gradient — use ship's stern direction
                Vector2::new(-self.state.heading.sin(), -self.state.heading.cos())
            }
        };

        // --- Compute coastline tangent toward destination ---
        // Two tangent candidates (perpendicular to away_dir): pick the one toward destination
        let tangent_a = Vector2::new(-away_dir.y, away_dir.x); // +90°
        let tangent_b = Vector2::new(away_dir.y, -away_dir.x); // -90°

        // Direction toward next waypoint (or destination if no path)
        let mut next_wp = self.target.position;
        if self.path_valid && self.current_wp_index < self.current_path.waypoints.len() as i32 {
            next_wp = self.current_path.waypoints[self.current_wp_index as usize];
        }
        let to_dest = next_wp - self.state.position;
        let to_dest_len = to_dest.length();

        // Forward tangent selection: pick tangent closest to destination (normal escape)
        let chosen_tangent_fwd = if to_dest_len > 1.0 {
            if tangent_a.dot(to_dest) >= tangent_b.dot(to_dest) {
                tangent_a
            } else {
                tangent_b
            }
        } else if tangent_a.dot(self.state.velocity) >= tangent_b.dot(self.state.velocity) {
            tangent_a
        } else {
            tangent_b
        };

        // Reverse tangent selection for 3-point turn: pick the tangent so that the
        // BOW (opposite to travel direction) ends up closest to the next waypoint.
        // When reversing along a tangent, the stern travels in the tangent direction
        // while the bow points in the opposite direction (-tangent).  We want
        // -chosen_tangent_rev to be closest to to_dest, i.e. the tangent whose
        // negation has the greatest dot with to_dest — equivalently, the tangent
        // with the LEAST dot with to_dest.
        let chosen_tangent_rev = if to_dest_len > 1.0 {
            if tangent_a.dot(to_dest) <= tangent_b.dot(to_dest) {
                tangent_a
            } else {
                tangent_b
            }
        } else {
            // No meaningful destination — pick tangent whose reverse aligns with current heading (bow direction)
            let bow_dir = Vector2::new(self.state.heading.sin(), self.state.heading.cos());
            if tangent_a.dot(bow_dir) <= tangent_b.dot(bow_dir) {
                tangent_a
            } else {
                tangent_b
            }
        };

        // --- Blend from away-from-land toward tangent based on distance from terrain ---
        // At sdf <= 0 (inside land): fully away
        // At sdf >= soft_clearance: fully tangent
        // In between: linear blend
        let soft_clearance = self.get_soft_clearance();
        let blend_start = soft_clearance * 0.2;
        let blend_end = soft_clearance * 0.8; // start going mostly tangential well before full clearance
        let blend_t = clamp_f(
            (sdf_here - blend_start) / (blend_end - blend_start).max(1.0),
            0.0,
            1.0,
        );

        // --- Determine forward vs backward first using forward tangent ---
        // Blend escape direction using the forward tangent to decide direction
        let mut escape_dir_fwd = Vector2::new(
            lerp_f(away_dir.x, chosen_tangent_fwd.x, blend_t),
            lerp_f(away_dir.y, chosen_tangent_fwd.y, blend_t),
        );
        let escape_fwd_len = escape_dir_fwd.length();
        if escape_fwd_len > 0.001 {
            escape_dir_fwd /= escape_fwd_len;
        } else {
            escape_dir_fwd = away_dir;
        }

        let fwd_x = self.state.heading.sin();
        let fwd_z = self.state.heading.cos();
        // Computed but never read again in the C++ (dead local) — kept for
        // faithful transliteration.
        let _escape_dot_fwd = escape_dir_fwd.x * fwd_x + escape_dir_fwd.y * fwd_z;

        // --- Evaluate forward vs reverse using the escape heading ---
        // Simulate one arc for each direction and score by the minimum SDF along
        // the arc.  The candidate whose tightest point is farthest from land wins
        // — this ensures we pick the direction that avoids squeezing through a
        // narrow gap or clipping terrain at any point along the escape path.
        let lookahead = (self.params.turning_circle_radius * 2.0)
            .max(self.params.ship_length * 3.0);

        let mut best_min_sdf = f32::NEG_INFINITY;
        let mut best_rudder = 0.0f32;
        let mut best_throttle: i32 = -1;

        // Evaluate both directions: 0 = forward, 1 = reverse
        for dir in 0..2 {
            let rev = dir == 1;
            let chosen_tangent = if rev { chosen_tangent_rev } else { chosen_tangent_fwd };

            let mut escape_dir = Vector2::new(
                lerp_f(away_dir.x, chosen_tangent.x, blend_t),
                lerp_f(away_dir.y, chosen_tangent.y, blend_t),
            );
            let escape_len = escape_dir.length();
            if escape_len > 0.001 {
                escape_dir /= escape_len;
            } else {
                escape_dir = away_dir;
            }

            let escape_heading = escape_dir.x.atan2(escape_dir.y);
            let rudder_heading = if rev {
                normalize_angle((escape_heading as f64 + PI) as f32)
            } else {
                escape_heading
            };
            let candidate_rudder = self.compute_rudder_to_heading(rudder_heading, rev);
            let throttle: i32 = if rev { -1 } else { 4 };

            let arc = self.predict_arc_internal(candidate_rudder, throttle, lookahead);
            if arc.len() < 2 {
                continue;
            }

            // Score: minimum SDF across all arc points — pick the direction
            // whose worst point is farthest from land.
            let mut min_sdf = f32::INFINITY;
            {
                let m = self.map.as_ref().unwrap().bind();
                for pt in &arc {
                    let sdf = m.get_distance_impl(pt.position.x, pt.position.y);
                    if sdf < min_sdf {
                        min_sdf = sdf;
                    }
                }
            }

            if min_sdf > best_min_sdf {
                best_min_sdf = min_sdf;
                best_rudder = candidate_rudder;
                best_throttle = throttle;
                self.winning_arc = arc;
            }
        }

        let rudder = best_rudder;
        let mut throttle = best_throttle;
        let use_reverse = throttle < 0;

        // --- Rudder-discrepancy throttle reduction (emergency) ---
        // Same principle as normal mode: when the desired rudder is far from the
        // current physical rudder, reduce throttle so the ship doesn't charge
        // forward/backward on the old rudder heading before the rudder catches up.
        // In emergency mode we map forward throttle 4 → magnitude steps and
        // reverse throttle -1 stays as-is (already minimum reverse).
        if !use_reverse && throttle > 1 {
            let rudder_discrepancy = (rudder - self.state.current_rudder).abs();
            let discrepancy_threshold = 0.3f32;
            let discrepancy_full = 1.2f32;
            if rudder_discrepancy > discrepancy_threshold {
                let t = clamp_f(
                    (rudder_discrepancy - discrepancy_threshold)
                        / (discrepancy_full - discrepancy_threshold),
                    0.0,
                    1.0,
                );
                let reduction = (t * 2.0).round() as i32;
                throttle = (throttle - reduction).max(1);
            }
        }

        // --- Exit condition: at destination with heading aligned — no need to escape ---
        {
            let dist_to_dest_em = self.state.position.distance_to(self.target.position);
            let arrived_radius_em = self.target.hold_radius.max(self.params.ship_beam * 2.0);
            let heading_error_em =
                angle_difference(self.state.heading, self.target.heading).abs();
            if dist_to_dest_em < arrived_radius_em && heading_error_em < self.target.heading_tolerance
            {
                self.nav_state = NavState::Normal;
                self.emergency_initialized = false;
                return;
            }
        }

        // --- Exit condition: no longer grounded AND arc toward next waypoint is clear ---
        let soft_cl = self.get_soft_clearance();
        let hard_cl = self.get_ship_clearance();
        if !self.grounded && (sdf_here as f64) > (hard_cl as f64) * 2.0 {
            // If waypoint is far (> 3 TCR) the exit cruise direction flips from the current emergency direction
            let exit_reverse = to_dest_len < self.params.turning_circle_radius * 3.0;
            let exit_throttle: i32 = if exit_reverse { -1 } else { 2 };
            let wp_heading = to_dest.x.atan2(to_dest.y);
            let exit_heading_target = if exit_reverse {
                normalize_angle((wp_heading as f64 + PI) as f32)
            } else {
                wp_heading
            };
            let exit_rudder = self.compute_rudder_to_heading(exit_heading_target, exit_reverse);
            let exit_lookahead =
                (2.0f64 * PI * self.params.turning_circle_radius as f64) as f32;

            let arc = self.predict_arc_to_heading(
                exit_rudder,
                exit_throttle,
                next_wp,
                exit_lookahead,
                60.0,
                false,
            );
            let arc_time = if arc.is_empty() { 0.0 } else { arc.last().unwrap().time };
            let ttc = self.check_arc_collision(&arc, hard_cl * 0.8, soft_cl);

            if arc_time > 0.0 && ttc >= arc_time {
                self.nav_state = NavState::Normal;
                self.emergency_initialized = false;
                return;
            }
        }

        self.set_steering_output(rudder, throttle, true);
    }

    // ========================================================================
    // Plan management
    // ========================================================================

    /// Synchronous HPA* planning, called from navigate_to().
    pub(crate) fn run_plan_sync(&mut self) {
        // Search at the hull's true minimum; buy sea room through the hug stand-off
        // instead.  See HUG_CLEARANCE_BUFFER in the header for why padding the
        // search clearance is the wrong lever.
        let plan_min_clearance = self.get_ship_clearance();
        let hug_clearance = self.get_ship_clearance() + HUG_CLEARANCE_BUFFER;

        // Every exit below the HPA* block is a degraded result.  planner_ready
        // separates "the planner ran and found nothing" from "there was nothing to
        // plan with", so the warning names the actual root cause.
        let planner_ready = self.hpa_graph.is_some()
            && self.hpa_graph.as_ref().unwrap().bind().is_built()
            && self.map.is_some()
            && self.map.as_ref().unwrap().bind().is_built();

        // -----------------------------------------------------------------------
        // HPA* path (primary): threat-aware hierarchical A*.
        // HpaGraph is shared by many ships; apply this navigator's threat layer
        // immediately before each query so the correct threats are stamped.
        // -----------------------------------------------------------------------
        if planner_ready {
            self.refresh_threats();

            let threats_empty = self.threats.borrow().is_empty();
            if !threats_empty {
                let circles = self.threats.borrow().clone();
                self.hpa_graph.as_mut().unwrap().bind_mut().stamp_threats(&circles);
            } else {
                self.hpa_graph.as_mut().unwrap().bind_mut().clear_threats();
            }

            // Bias the search toward the near field of the route already being
            // followed.  Two clips, and both matter.  Dropping the legs already
            // sailed keeps the corridor from pulling backwards; clipping the far
            // end to get_near_field_range() is what bounds the discount, because
            // the saving from riding the corridor scales with how much of it the
            // new route can ride.  Stamped to the destination, a long corridor pays
            // for a detour out to the old goal and a turn back — the shape that
            // looks like a route to the previous destination with a 180 on the end.
            // See HpaGraph::PathBias and PATH_NEAR_FIELD_TCR.
            let mut bias_path: Vec<Vector2> = Vec::new();
            if self.path_valid && self.current_path.waypoints.len() >= 2 {
                let first = (self.current_wp_index - 1)
                    .min(self.current_path.waypoints.len() as i32 - 1)
                    .max(0);
                let tail: Vec<Vector2> = self.current_path.waypoints[first as usize..].to_vec();
                bias_path = Self::truncate_path(&tail, self.get_near_field_range());
            }
            let bias_opt = if bias_path.len() >= 2 { Some(&bias_path) } else { None };

            let mut pr = {
                let g = self.hpa_graph.as_ref().unwrap().bind();
                g.find_path(
                    self.state.position,
                    self.target.position,
                    plan_min_clearance,
                    hug_clearance,
                    bias_opt,
                )
            };
            self.path_threat_relaxed = pr.valid && {
                let g = self.hpa_graph.as_ref().unwrap().bind();
                g.did_last_query_ignore_threats()
            };
            if pr.valid && !pr.waypoints.is_empty() {
                // Always end at the exact destination — HPA* snaps to grid nodes
                // so the final grid node may not be target.position.
                if pr.waypoints.last().unwrap().distance_to(self.target.position) > 1.0 {
                    pr.waypoints.push(self.target.position);
                    pr.flags.push(waypoint_flags::WP_NONE);
                }
                self.accept_plan_result(&pr);
                return;
            }
            // HPA* failed — retain the previous path rather than overwriting it with
            // a straight-line fallback.  The ship continues following its existing
            // route while navigate_to() retries on the next call.
            if self.path_valid && !self.current_path.waypoints.is_empty() {
                self.report_path_failure(path_fail_reason::NO_ROUTE_KEPT_PATH);
                return;
            }
            // No prior path available — fall through to straight-line fallbacks.
        }

        // -----------------------------------------------------------------------
        // Straight-line fallback (terrain-only, no threats)
        // -----------------------------------------------------------------------
        let threats_empty = self.threats.borrow().is_empty();
        let map_built = self.map.is_some() && self.map.as_ref().unwrap().bind().is_built();
        if threats_empty && map_built {
            let los = {
                let m = self.map.as_ref().unwrap().bind();
                m.raycast_internal(self.state.position, self.target.position, plan_min_clearance)
            };
            if !los.hit {
                let mut direct = PathResult::default();
                direct.waypoints.push(self.state.position);
                direct.waypoints.push(self.target.position);
                direct.flags.push(waypoint_flags::WP_NONE);
                direct.flags.push(waypoint_flags::WP_NONE);
                direct.valid = true;
                direct.total_distance = self.state.position.distance_to(self.target.position);
                let reason = if planner_ready {
                    path_fail_reason::NO_ROUTE_DIRECT
                } else {
                    path_fail_reason::NO_MAP
                };
                self.report_path_failure(reason);
                self.accept_plan_result(&direct);
                return;
            }
        }

        // -----------------------------------------------------------------------
        // Last resort: stop short of terrain/threats along the straight line
        // -----------------------------------------------------------------------
        {
            let dir = self.target.position - self.state.position;
            let total = dir.length();

            let mut direct = PathResult::default();
            direct.waypoints.push(self.state.position);

            if total > plan_min_clearance
                && self.map.is_some()
                && self.map.as_ref().unwrap().bind().is_built()
            {
                let dir_n = dir / total;
                let step = plan_min_clearance.max(50.0);
                let mut best_dist = 0.0f32;
                let mut d = step;
                loop {
                    let test_d = d.min(total);
                    let test = self.state.position + dir_n * test_d;
                    let sdf = {
                        let m = self.map.as_ref().unwrap().bind();
                        m.get_distance_impl(test.x, test.y)
                    };
                    if sdf < plan_min_clearance {
                        break;
                    }
                    if !self.threats.borrow().is_empty() {
                        let mut in_threat = false;
                        for t in self.threats.borrow().iter() {
                            let dx = test.x - t.origin.x;
                            let dz = test.y - t.origin.y;
                            if dx * dx + dz * dz < t.radius * t.radius {
                                in_threat = true;
                                break;
                            }
                        }
                        if in_threat {
                            break;
                        }
                    }
                    best_dist = test_d;
                    if test_d >= total {
                        break;
                    }
                    d += step;
                }
                if best_dist > plan_min_clearance {
                    direct.waypoints.push(self.state.position + dir_n * best_dist);
                }
            }

            if direct.waypoints.len() < 2 {
                direct.waypoints.push(self.target.position); // blocked — destination is goal even if unreachable now
            }

            direct.flags = vec![waypoint_flags::WP_NONE; direct.waypoints.len()];
            direct.valid = true;
            direct.total_distance = 0.0;
            for i in 0..direct.waypoints.len().saturating_sub(1) {
                direct.total_distance += direct.waypoints[i].distance_to(direct.waypoints[i + 1]);
            }

            // Ending short of the destination means the route was cut off by
            // terrain/threats; ending on it means we never verified a clear line.
            let truncated =
                direct.waypoints.last().unwrap().distance_to(self.target.position) > 1.0;
            let reason = if truncated {
                path_fail_reason::NO_ROUTE_TRUNCATED
            } else {
                path_fail_reason::NO_ROUTE_BLIND
            };
            let final_reason = if planner_ready { reason } else { path_fail_reason::NO_MAP };
            self.report_path_failure(final_reason);
            self.accept_plan_result(&direct);
        }
    }

    /// Record a failed path request and warn about it, throttled to one message
    /// per PATH_FAIL_WARN_INTERVAL per navigator so a permanently unreachable
    /// destination cannot flood the log.
    pub(crate) fn report_path_failure(&mut self, reason: i32) {
        self.path_fail_reason = reason;
        self.path_fail_count += 1;
        self.path_fail_suppressed += 1;

        if self.path_fail_warn_cooldown > 0.0 {
            return; // folded into the next warning via path_fail_suppressed
        }

        let suppressed = self.path_fail_suppressed - 1; // this one is being reported
        self.path_fail_suppressed = 0;
        self.path_fail_warn_cooldown = PATH_FAIL_WARN_INTERVAL;

        let hpa_stage = if let Some(hpa) = self.hpa_graph.as_ref() {
            hpa.bind().get_last_fail_stage_name()
        } else {
            GString::from("n/a")
        };

        godot_warn!(
            "[ShipNavigator] bot {}: path request failed — {} | from={} to={} dist={} clearance={} threats={} hpa_stage={} suppressed={} total={}",
            self.bot_id,
            Self::path_fail_reason_name(self.path_fail_reason),
            self.state.position,
            self.target.position,
            self.state.position.distance_to(self.target.position),
            self.get_ship_clearance(),
            self.threats.borrow().len() as i32,
            hpa_stage,
            suppressed,
            self.path_fail_count
        );
    }

    pub(crate) fn clear_path_failures_impl(&mut self) {
        self.path_fail_reason = path_fail_reason::NONE;
        self.path_fail_count = 0;
        self.path_fail_suppressed = 0;
        self.path_fail_warn_cooldown = 0.0;
    }
}
