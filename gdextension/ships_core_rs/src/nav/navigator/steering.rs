use godot::prelude::*;
use std::f64::consts::PI;

use super::{
    ShipNavigator, SteeringChoice, ThreatEval, BOW_STERN_CLIP_START, DODGE_COMMITMENT_BIAS,
    DODGE_COMMITMENT_DURATION, GRAZE_MIN_FACTOR, PARKED_SPEED_THRESHOLD,
    PURE_PURSUIT_MIN_IMPROVEMENT, SHELL_NAV_BUDGET, SHELL_TIME_TOLERANCE, SOFT_TERRAIN_PENALTY,
    TORPEDO_NAV_BUDGET, TORPEDO_VIRTUAL_CALIBER,
};
use crate::nav::types::{angle_difference, clamp_f, lerp_f, normalize_angle, ArcPoint};

impl ShipNavigator {
    /// Evaluate shell + torpedo threats along an arc. Returns separate scores so
    /// the caller can apply different budgets and suppress shells when the
    /// stuck override is active.
    pub(crate) fn score_arc_shell_threat(&self, arc: &[ArcPoint]) -> ThreatEval {
        let mut result = ThreatEval::default();
        if arc.len() < 2 {
            return result;
        }

        // Ship half-extents for OBB test
        let hsl = self.params.ship_length * 0.5; // half-length (bow/stern)
        let hsb = self.params.ship_beam * 0.5; // half-beam (port/starboard)

        // --- Adaptive time tolerance ---
        // eff_tol is the maximum acceptable gap between a shell's impact time and
        // the nearest arc sample.  It is driven purely by the arc's own sampling
        // density (1.5x the mean inter-point interval) so that shells are only
        // tested when the arc actually covers the relevant time window.  A 2-second
        // floor handles instantaneous arcs (single point, arc_dt_mean == 0).
        let arc_duration = arc.last().unwrap().time - arc.first().unwrap().time;
        let arc_dt_mean = if arc.len() > 1 {
            arc_duration / (arc.len() - 1) as f32
        } else {
            0.0
        };
        let eff_tol = SHELL_TIME_TOLERANCE.max(arc_dt_mean * 1.5);

        // =========================================================
        // SHELLS - temporal point intersection
        //
        // For each shell, find the arc point whose simulation time is closest to
        // shell.time_remaining.  If the gap is within the adaptive tolerance,
        // project the shell's landing point into the ship's OBB at that arc
        // point's position/heading.
        // Penalty factor:
        //   - end-on (bow or stern toward incoming shell) -> GRAZE_MIN_FACTOR (autobounce)
        //   - broadside                                   -> 1.0 (maximum damage)
        //   - bow/stern hull-tip clips                    -> further reduced
        // =========================================================
        for shell in &self.incoming_shells {
            if shell.time_remaining < 0.5 {
                continue; // about to land, no time to dodge
            }

            // Skip shells whose impact time is beyond the arc's simulated range.
            // Without this check, shells landing well after the arc ends could be
            // tested against the arc's endpoint position, which may be far from
            // where the ship would actually be at the shell's impact time.
            if shell.time_remaining > arc.last().unwrap().time + eff_tol {
                continue;
            }

            let cal_weight = (shell.caliber * shell.caliber) / (200.0 * 200.0);

            // Find arc point nearest in time to shell impact
            let mut best_apt: Option<&ArcPoint> = None;
            let mut best_dt = f32::INFINITY;
            for apt in arc {
                let dt = (apt.time - shell.time_remaining).abs();
                if dt < best_dt {
                    best_dt = dt;
                    best_apt = Some(apt);
                }
            }
            let best_apt = match best_apt {
                Some(apt) if best_dt <= eff_tol => apt,
                _ => continue,
            };

            // Ship local frame at this arc point
            let fx = best_apt.heading.sin();
            let fz = best_apt.heading.cos();

            // Shell landing point relative to ship center, in ship local frame
            // along_keel > 0 = toward bow; along_beam > 0 = toward starboard
            let rel = shell.landing_pos - best_apt.position;
            let along_keel = rel.x * fx + rel.y * fz;
            let along_beam = rel.x * fz - rel.y * fx;

            // OBB check - use exact hull dimensions only.
            // An arc scores a shell hit only when the shell's predicted landing
            // position falls within the ship's actual bounding box at the matched
            // arc point.  No extra keel or beam margin is added: proximity is not
            // a hit.  This prevents dodging shells that would miss the ship.
            if along_keel.abs() > hsl {
                continue;
            }
            if along_beam.abs() > hsb {
                continue;
            }

            // Angle factor: shell arriving end-on is partially autobounced.
            //   cos_keel = |cos(angle between shell travel dir and ship keel)|:
            //     1 = bow/stern approach (autobounce) -> GRAZE_MIN_FACTOR
            //     0 = broadside hit                   -> 1.0
            let cos_keel = (shell.landing_dir.x * fx + shell.landing_dir.y * fz).abs();
            let sin_keel = (1.0 - cos_keel * cos_keel).max(0.0).sqrt();
            let angle_factor = GRAZE_MIN_FACTOR + (1.0 - GRAZE_MIN_FACTOR) * sin_keel;

            // Bow/stern hard cutoff: shells landing in the extreme forward/aft section
            // (beyond BOW_STERN_CLIP_START fraction of the half-length) are rejected
            // entirely.  Angled bow/stern armour bounces these shells regardless of
            // calibre - no gradual falloff.
            let fwd_frac = along_keel.abs() / hsl.max(0.01);
            if fwd_frac > BOW_STERN_CLIP_START {
                continue;
            }

            result.shell_score += cal_weight * angle_factor;
        }

        // =========================================================
        // TORPEDOES - temporal point intersection
        //
        // For each torpedo, project its position forward to the time of each arc
        // point and check if it falls within the ship's OBB (extended by the
        // torpedo's radius).  Torpedoes always do full damage regardless of
        // impact angle.  Accumulate the worst penalty across all arc points.
        // =========================================================
        for obs in self.obstacles.values() {
            if !obs.is_torpedo() {
                continue;
            }

            let torp_speed = obs.velocity.length();
            if torp_speed < 1.0 {
                continue;
            }

            let cal_weight = (TORPEDO_VIRTUAL_CALIBER * TORPEDO_VIRTUAL_CALIBER) / (200.0 * 200.0);
            let mut worst = 0.0f32;

            for apt in arc {
                // Project torpedo position to arc time
                let torp_pos = obs.position + obs.velocity * apt.time;

                // Ship local frame
                let fx = apt.heading.sin();
                let fz = apt.heading.cos();

                let rel = torp_pos - apt.position;
                let along_keel = rel.x * fx + rel.y * fz;
                let along_beam = rel.x * fz - rel.y * fx;

                // Clearance: hull half-extents + torpedo body radius
                if along_keel.abs() > hsl + obs.radius {
                    continue;
                }
                if along_beam.abs() > hsb + obs.radius {
                    continue;
                }

                // Torpedo hit - full damage, no angle discount
                if cal_weight > worst {
                    worst = cal_weight;
                }
            }

            // Arc extrapolation: predict_arc_to_heading may terminate early when
            // the bow aligns with the waypoint (the common case when heading
            // straight toward a distant destination).  The resulting arc may cover
            // only a few seconds while the torpedo arrives much later.  Extend the
            // ship's last known position/heading/speed straight ahead up to 90 s
            // total so distant-but-incoming torpedoes are not missed on the
            // straight-ahead candidate - giving the dodge candidates a real
            // threat advantage to beat.
            if worst == 0.0 && !arc.is_empty() {
                let last_pt = arc.last().unwrap();
                let ext_fx = last_pt.heading.sin();
                let ext_fz = last_pt.heading.cos();
                let ext_speed = last_pt.speed.abs().max(1.0);
                let step_dist = (hsl * 2.0).max(50.0);
                let step_time = step_dist / ext_speed;
                const MAX_EXT_TIME: f32 = 90.0;

                let mut t = last_pt.time + step_time;
                while t <= MAX_EXT_TIME {
                    let dt_ext = t - last_pt.time;
                    let ship_pos = Vector2::new(
                        last_pt.position.x + ext_fx * ext_speed * dt_ext,
                        last_pt.position.y + ext_fz * ext_speed * dt_ext,
                    );
                    let torp_pos_ext = obs.position + obs.velocity * t;
                    let rel_ext = torp_pos_ext - ship_pos;
                    let along_keel_ext = rel_ext.x * ext_fx + rel_ext.y * ext_fz;
                    let along_beam_ext = rel_ext.x * ext_fz - rel_ext.y * ext_fx;
                    if along_keel_ext.abs() <= hsl + obs.radius
                        && along_beam_ext.abs() <= hsb + obs.radius
                    {
                        worst = cal_weight;
                        break;
                    }
                    t += step_time;
                }
            }

            result.torpedo_score += worst;
        }

        result
    }

    pub(crate) fn select_best_steering(
        &mut self,
        desired_rudder: f32,
        desired_throttle: i32,
    ) -> SteeringChoice {
        let mut result = SteeringChoice {
            rudder: desired_rudder,
            throttle: desired_throttle,
            collision_imminent: false,
        };

        let mut steering_candidates_total: i32 = 0;
        let mut steering_candidates_simulated: i32 = 0;
        let mut steering_terrain_rejects: i32 = 0;
        let mut steering_short_arc_rejects: i32 = 0;
        let mut steering_arc_points_simulated: i32 = 0;

        let mut hard_clearance = self.get_ship_clearance();
        let soft_clearance = self.get_soft_clearance();
        let lookahead = self.get_lookahead_distance();

        // Compute current SDF once - reused for adaptive clearance, fast-exit,
        // and soft-terrain penalty tracking inside the candidate loop.
        let sdf_here: f32 = match self.map.as_ref() {
            Some(map) => {
                let mb = map.bind();
                if mb.is_built() {
                    mb.get_distance_impl(self.state.position.x, self.state.position.y)
                } else {
                    f32::INFINITY
                }
            }
            None => f32::INFINITY,
        };

        // --- Adaptive clearance: halve when close to land ---
        // When the SDF at the ship's position is below 1.5x hard clearance the ship
        // is entering a tight region.  Halving the simulated clearance lets the
        // planner find arcs through the passage instead of disqualifying every
        // candidate and oscillating in place.
        if sdf_here < hard_clearance * 1.5 {
            hard_clearance *= 0.75;
        } else if sdf_here < hard_clearance {
            hard_clearance *= 0.5;
        }

        // --- Parked-ship filter ---
        self.skip_ship_obstacles =
            self.state.current_speed.abs() < PARKED_SPEED_THRESHOLD && desired_throttle <= 0;

        // --- Fast early-exit: skip when clearly safe and no threats at all ---
        // Threshold: sdf > lookahead + hard_clearance means no arc of length
        // 'lookahead' can possibly reach the hard-clearance zone.
        // (Using soft_clearance here would make the threshold enormous for large
        // ships - e.g. 1530 m for a battleship - forcing full simulation even in
        // open water hundreds of metres from land.)
        let terrain_safe = sdf_here > lookahead + hard_clearance;

        let mut obstacles_safe = true;
        let engagement_range = lookahead + self.params.max_speed * 10.0;
        for obs in self.obstacles.values() {
            if self.skip_ship_obstacles && !obs.is_torpedo() {
                continue;
            }
            // Torpedoes can be fast and far - use 90 s of torpedo travel as the
            // engagement horizon so the ship begins dodging well before impact.
            // Ship obstacles use the normal lookahead-based range.
            let check_range = if obs.is_torpedo() {
                obs.velocity.length() * 90.0 + self.params.ship_length
            } else {
                engagement_range
            };
            if self.state.position.distance_to(obs.position) < check_range {
                obstacles_safe = false;
                break;
            }
        }

        // shells_safe: true when no shell can possibly intercept the ship before
        // landing.  Quick geometric pre-filter: if the ship's maximum reachable
        // radius in the shell's remaining flight time does not overlap the landing
        // position (padded by half the ship's extents), the shell is guaranteed to
        // miss without any arc simulation.
        let mut shells_safe = true;
        if !self.incoming_shells.is_empty() {
            let quick_hsl = self.params.ship_length * 0.5;
            let quick_hsb = self.params.ship_beam * 0.5;
            for shell in &self.incoming_shells {
                if shell.time_remaining < 0.5 {
                    continue;
                }
                let max_reach = self.params.max_speed * shell.time_remaining + quick_hsl + quick_hsb;
                if self.state.position.distance_to(shell.landing_pos) <= max_reach {
                    shells_safe = false;
                    break;
                }
            }
        }

        if terrain_safe && obstacles_safe && shells_safe {
            let fast_path_lookahead = self.params.turning_circle_radius * 1.5;
            self.winning_arc =
                self.predict_arc_internal(desired_rudder, desired_throttle, fast_path_lookahead);
            self.perf_last_steering_candidates_total = 1;
            self.perf_last_steering_candidates_simulated = 1;
            self.perf_last_steering_terrain_rejects = 0;
            self.perf_last_steering_short_arc_rejects = 0;
            self.perf_last_steering_arc_points_simulated = self.winning_arc.len() as i32;
            return result;
        }

        // --- Determine waypoint target ---
        let mut wp_target = self.target.position;
        if self.path_valid && self.current_wp_index < self.current_path.waypoints.len() as i32 {
            wp_target = self.current_path.waypoints[self.current_wp_index as usize];
        }
        let wp_reach_radius = self.get_reach_radius();

        // wp_is_virtual: score by heading alignment only when the ship is truly
        // AT the steering target (within arrived_radius ~= 2 x ship_beam).
        // Using TCR or path_exhausted as the trigger caused heading-only scoring
        // when the destination was still far away and perpendicular, making
        // reverse candidates (half the turn-around time of a forward circle)
        // beat correct forward turns.
        let mut wp_is_virtual = false;
        {
            let arrived_r = self.target.hold_radius.max(self.params.ship_beam * 2.0);
            if self.state.position.distance_to(wp_target) < arrived_r {
                wp_is_virtual = true;
            }
        }

        // --- Ship forward vector (used for obstacle hitter check) ---
        let our_fwd = Vector2::new(self.state.heading.sin(), self.state.heading.cos());

        // --- Build candidate list ---
        struct Candidate {
            rudder: f32,
            throttle: i32,
        }

        let rudder_offsets: [f32; 7] = [0.0, 0.3, -0.3, 0.6, -0.6, -1.0, 1.0];
        // Include all 7 offsets (+-0.3, +-0.6, +-1.0) so the ship can execute hard
        // full-rudder turns to dodge torpedoes - previously only +-0.3 were tried.
        let mut candidates: Vec<Candidate> = Vec::new();
        {
            let mut add_candidate = |r: f32, t: i32| {
                let r = clamp_f(r, -1.0, 1.0);
                if candidates
                    .iter()
                    .any(|c| (c.rudder - r).abs() < 0.05 && c.throttle == t)
                {
                    return;
                }
                candidates.push(Candidate { rudder: r, throttle: t });
            };

            for &off in rudder_offsets.iter() {
                add_candidate(desired_rudder + off, desired_throttle);
            }

            if desired_rudder.abs() > 0.15 {
                add_candidate(if desired_rudder > 0.0 { -1.0 } else { 1.0 }, desired_throttle);
            }

            add_candidate(0.0, -1);
            add_candidate(-0.3, -1);
            add_candidate(0.3, -1);
            add_candidate(-0.6, -1);
            add_candidate(0.6, -1);
            add_candidate(-1.0, -1);
            add_candidate(1.0, -1);
        }

        let n_candidates = candidates.len();
        steering_candidates_total = n_candidates as i32;

        // --- Simulation parameters ---
        let turn_circumference = 2.0f32 * (PI as f32) * self.params.turning_circle_radius;
        let sim_lookahead = turn_circumference.max(lookahead * 2.0);
        let sim_max_time: f32 = 120.0;
        const HEADING_ALIGN_THRESH: f32 = 0.087; // ~5 degrees

        // --- Exit-heading: precompute remaining path context (normal path only) ---
        let mut next_goal_after_wp = self.target.position;
        let mut desired_exit_heading: f32 = 0.0;
        let mut apply_exit_penalty = false;
        if !wp_is_virtual && self.path_valid {
            let next_idx = self.current_wp_index + 1;
            if next_idx < self.current_path.waypoints.len() as i32 {
                next_goal_after_wp = self.current_path.waypoints[next_idx as usize];
            }
            let to_next = next_goal_after_wp - wp_target;
            if to_next.length() > 1.0 {
                desired_exit_heading = to_next.x.atan2(to_next.y);
                apply_exit_penalty = true;
            }
        }

        // --- Heading-weight mode (normal path only) ---
        let has_heading_weight = self.target.heading_weight > 0.001;
        let mut heading_vp = Vector2::ZERO;
        if has_heading_weight {
            let th = self.target.heading;
            heading_vp = self.state.position + Vector2::new(th.sin(), th.cos()) * 10000.0;
        }

        // =========================================================
        // Two-pass scoring storage
        //   nav_score = pure navigation cost (no threat penalty)
        //   threats   = shell + torpedo hit scores (dimensionless)
        // Selection: find best_nav; filter to best_nav + budget;
        //            pick the candidate with the lowest effective threat.
        // =========================================================
        struct PassEntry {
            rudder: f32,
            throttle: i32,
            nav_score: f32,
            threats: ThreatEval,
            any_obs_collision: bool,
        }
        const MAX_PASS_ENTRIES: usize = 24;
        let mut pass_data: Vec<PassEntry> = Vec::new();
        let mut any_collision = false;

        // =========================================================
        // Per-candidate scoring loop
        // =========================================================
        for i in 0..n_candidates {
            let cand_rudder = candidates[i].rudder;
            let cand_throttle = candidates[i].throttle;

            if wp_is_virtual {
                // ---- At-destination: score by heading alignment time ----
                // predict_arc_internal gives a free-running arc not tied to a waypoint
                // arrival condition, avoiding the symmetric-scoring tie that the old
                // virtual-waypoint approach produced.
                let arc = self.predict_arc_internal(cand_rudder, cand_throttle, sim_lookahead);
                if arc.len() < 2 {
                    steering_short_arc_rejects += 1;
                    continue;
                }
                steering_candidates_simulated += 1;
                steering_arc_points_simulated += arc.len() as i32;

                // Terrain: check arc points up to the immediate stroke horizon.
                // At destination the ship executes short strokes and re-evaluates
                // every frame, so checking the full 3700+ m arc would falsely block
                // forward candidates that clip terrain only far into a circular arc
                // they will never complete.  Cap the check at 'lookahead' of cumulative
                // arc distance - enough to detect truly imminent terrain without
                // penalising multi-point turns near the coastline.
                let mut terrain_blocked = false;
                let mut soft_min_sdf = f32::INFINITY;
                if let Some(map) = self.map.as_ref() {
                    let mb = map.bind();
                    if mb.is_built() {
                        let mut arc_dist = 0.0f32;
                        let mut prev = arc[0].position;
                        for pt in &arc {
                            arc_dist += pt.position.distance_to(prev);
                            prev = pt.position;
                            if arc_dist > lookahead {
                                break; // beyond immediate re-eval horizon
                            }
                            let sdf = mb.get_distance_impl(pt.position.x, pt.position.y);
                            if sdf < hard_clearance {
                                terrain_blocked = true;
                                break;
                            }
                            if sdf < soft_clearance && sdf < soft_min_sdf {
                                soft_min_sdf = sdf;
                            }
                        }
                    }
                }
                if terrain_blocked {
                    steering_terrain_rejects += 1;
                    continue;
                }

                // Nav score: time until bow (forward) or stern (reverse) aligns with target.heading.
                // For reverse candidates the effective heading is bow + pi - the direction
                // the ship will present when it switches back to forward drive.
                let effective_target_h = if cand_throttle < 0 {
                    normalize_angle(self.target.heading + (PI as f32))
                } else {
                    self.target.heading
                };
                let mut nav_score = f32::INFINITY;
                for pt in &arc {
                    if angle_difference(pt.heading, effective_target_h).abs() < HEADING_ALIGN_THRESH {
                        nav_score = pt.time;
                        break;
                    }
                }
                if nav_score == f32::INFINITY {
                    // Did not align within arc - penalise by residual heading error
                    let h_err = angle_difference(arc.last().unwrap().heading, effective_target_h).abs();
                    nav_score = arc.last().unwrap().time + (h_err / (PI as f32)) * 60.0;
                }

                // Obstacle collision penalty (part of nav cost)
                let mut obs_col = false;
                let obs_info = self.check_arc_obstacles_detailed(&arc);
                if obs_info.has_collision && !obs_info.is_torpedo {
                    let to_obs = obs_info.obstacle_position - self.state.position;
                    if to_obs.length() > 0.1 && our_fwd.dot(to_obs.normalized()) > 0.3 {
                        let urgency = (10.0 / obs_info.time_to_collision.max(1.0)).min(1.0);
                        nav_score += urgency * 60.0;
                        obs_col = true;
                    }
                }

                let threats = self.score_arc_shell_threat(&arc);

                // Soft terrain penalty: prefer arcs that stay outside soft_clearance
                // when the ship is currently outside it.  When already inside
                // (e.g. spawned near terrain), all arcs share the same starting
                // position so suppress the penalty to avoid non-discriminating inflation.
                if sdf_here >= soft_clearance && soft_min_sdf < soft_clearance {
                    let pen_t = 1.0
                        - clamp_f(
                            (soft_min_sdf - hard_clearance) / (soft_clearance - hard_clearance).max(1.0),
                            0.0,
                            1.0,
                        );
                    nav_score += pen_t * SOFT_TERRAIN_PENALTY;
                }

                if pass_data.len() < MAX_PASS_ENTRIES {
                    pass_data.push(PassEntry {
                        rudder: cand_rudder,
                        throttle: cand_throttle,
                        nav_score,
                        threats,
                        any_obs_collision: obs_col,
                    });
                }
            } else {
                // ---- Normal: predict_arc_to_heading + arrival/alignment scoring ----
                // For prefer_reverse arcs: align bow AWAY from waypoint (stern toward it).
                let rev_align = self.target.prefer_reverse && cand_throttle < 0;
                let arc = self.predict_arc_to_heading(
                    cand_rudder,
                    cand_throttle,
                    wp_target,
                    sim_lookahead,
                    sim_max_time,
                    rev_align,
                );
                if arc.len() < 2 {
                    steering_short_arc_rejects += 1;
                    continue;
                }
                steering_candidates_simulated += 1;
                steering_arc_points_simulated += arc.len() as i32;

                // Terrain check with waypoint-arrival early stop.
                // Also track minimum SDF for the soft-terrain penalty below.
                let mut terrain_blocked = false;
                let mut arrival_time: f32 = -1.0;
                let mut soft_min_sdf = f32::INFINITY;
                if let Some(map) = self.map.as_ref() {
                    let mb = map.bind();
                    if mb.is_built() {
                        for pt in &arc {
                            if pt.position.distance_to(wp_target) < wp_reach_radius {
                                arrival_time = pt.time;
                                break;
                            }
                            let sdf = mb.get_distance_impl(pt.position.x, pt.position.y);
                            if sdf < hard_clearance {
                                terrain_blocked = true;
                                break;
                            }
                            if sdf < soft_clearance && sdf < soft_min_sdf {
                                soft_min_sdf = sdf;
                            }
                        }
                    }
                }
                if terrain_blocked {
                    steering_terrain_rejects += 1;
                    continue;
                }

                // Nav score: arrival or alignment time + estimated travel
                let mut nav_score;
                if arrival_time >= 0.0 {
                    nav_score = arrival_time;
                } else {
                    let alignment_time = arc.last().unwrap().time;
                    // Closest approach to waypoint across the full arc (prevents tie on overshoot)
                    let mut endpoint_dist = arc.last().unwrap().position.distance_to(wp_target);
                    for pt in &arc {
                        let d = pt.position.distance_to(wp_target);
                        if d < endpoint_dist {
                            endpoint_dist = d;
                        }
                    }
                    // prefer_reverse arcs stay in reverse all the way to the waypoint;
                    // non-prefer_reverse reverse fallbacks do a U-turn then go forward.
                    let endpoint_speed = if self.target.prefer_reverse && cand_throttle < 0 {
                        self.throttle_to_speed(-1).abs()
                    } else if cand_throttle < 0 {
                        self.throttle_to_speed(3)
                    } else {
                        arc.last().unwrap().speed.abs()
                    };
                    nav_score = alignment_time + endpoint_dist / endpoint_speed.max(1.0);
                }

                // Heading-weight blend
                if has_heading_weight {
                    let mut heading_align_time = f32::INFINITY;
                    for hpt in &arc {
                        let to_hvp = heading_vp - hpt.position;
                        if to_hvp.length() > 1.0 {
                            let desired_h = to_hvp.x.atan2(to_hvp.y);
                            if angle_difference(hpt.heading, desired_h).abs() < HEADING_ALIGN_THRESH {
                                heading_align_time = hpt.time;
                                break;
                            }
                        }
                    }
                    if heading_align_time == f32::INFINITY {
                        let to_hvp = heading_vp - arc.last().unwrap().position;
                        if to_hvp.length() > 1.0 {
                            let desired_h = to_hvp.x.atan2(to_hvp.y);
                            let h_err = angle_difference(arc.last().unwrap().heading, desired_h).abs();
                            heading_align_time = arc.last().unwrap().time + (h_err / (PI as f32)) * 60.0;
                        } else {
                            heading_align_time = arc.last().unwrap().time;
                        }
                    }
                    nav_score = lerp_f(nav_score, heading_align_time, self.target.heading_weight);
                }

                // Exit-heading penalty
                if apply_exit_penalty {
                    let arrival_h: f32;
                    if arrival_time >= 0.0 {
                        let mut h_at_wp = arc.last().unwrap().heading;
                        for pt in &arc {
                            if pt.position.distance_to(wp_target) < wp_reach_radius {
                                h_at_wp = pt.heading;
                                break;
                            }
                        }
                        arrival_h = if cand_throttle < 0 {
                            normalize_angle(h_at_wp + (PI as f32))
                        } else {
                            h_at_wp
                        };
                    } else {
                        let d_wp = wp_target - arc.last().unwrap().position;
                        arrival_h = if d_wp.length() > 1.0 {
                            d_wp.x.atan2(d_wp.y)
                        } else {
                            arc.last().unwrap().heading
                        };
                    }
                    let exit_err = angle_difference(arrival_h, desired_exit_heading).abs();
                    let fwd_speed = self.throttle_to_speed(4).max(1.0);
                    let half_tc = ((PI as f32) * self.params.turning_circle_radius) / fwd_speed;
                    nav_score += (exit_err / (PI as f32)) * half_tc;
                }

                // Obstacle collision penalty (part of nav cost)
                let mut obs_col = false;
                let obs_info = self.check_arc_obstacles_detailed(&arc);
                if obs_info.has_collision && !obs_info.is_torpedo {
                    let to_obs = obs_info.obstacle_position - self.state.position;
                    if to_obs.length() > 0.1 && our_fwd.dot(to_obs.normalized()) > 0.3 {
                        let urgency = (10.0 / obs_info.time_to_collision.max(1.0)).min(1.0);
                        nav_score += urgency * 60.0;
                        obs_col = true;
                    }
                }

                let threats = self.score_arc_shell_threat(&arc);

                // Soft terrain penalty: same logic as the wp_is_virtual branch.
                if sdf_here >= soft_clearance && soft_min_sdf < soft_clearance {
                    let pen_t = 1.0
                        - clamp_f(
                            (soft_min_sdf - hard_clearance) / (soft_clearance - hard_clearance).max(1.0),
                            0.0,
                            1.0,
                        );
                    nav_score += pen_t * SOFT_TERRAIN_PENALTY;
                }

                if pass_data.len() < MAX_PASS_ENTRIES {
                    pass_data.push(PassEntry {
                        rudder: cand_rudder,
                        throttle: cand_throttle,
                        nav_score,
                        threats,
                        any_obs_collision: obs_col,
                    });
                }
            }
        } // end candidate loop

        // =========================================================
        // Terrain-blocked fallback
        // If every candidate was disqualified by terrain, choose the
        // one whose arc reaches the highest minimum SDF.
        // =========================================================
        if pass_data.is_empty() {
            let mut least_bad_sdf = f32::NEG_INFINITY;
            for i in 0..n_candidates {
                let arc = self.predict_arc_internal(candidates[i].rudder, candidates[i].throttle, lookahead);
                if arc.is_empty() {
                    continue;
                }
                steering_candidates_simulated += 1;
                steering_arc_points_simulated += arc.len() as i32;
                let mut min_sdf = f32::INFINITY;
                if let Some(map) = self.map.as_ref() {
                    let mb = map.bind();
                    if mb.is_built() {
                        for pt in &arc {
                            let sdf = mb.get_distance_impl(pt.position.x, pt.position.y);
                            if sdf < min_sdf {
                                min_sdf = sdf;
                            }
                        }
                    }
                }
                if min_sdf > least_bad_sdf {
                    least_bad_sdf = min_sdf;
                    result.rudder = candidates[i].rudder;
                    result.throttle = candidates[i].throttle;
                    self.winning_arc = arc;
                }
            }
            result.collision_imminent = true;
            self.perf_last_steering_candidates_total = steering_candidates_total;
            self.perf_last_steering_candidates_simulated = steering_candidates_simulated;
            self.perf_last_steering_terrain_rejects = steering_terrain_rejects;
            self.perf_last_steering_short_arc_rejects = steering_short_arc_rejects;
            self.perf_last_steering_arc_points_simulated = steering_arc_points_simulated;
            return result;
        }

        // =========================================================
        // Two-pass selection
        // =========================================================
        // Pass 1: best pure-navigation score
        let mut best_nav = f32::INFINITY;
        for p in &pass_data {
            if p.nav_score < best_nav {
                best_nav = p.nav_score;
            }
        }

        // Pass 2: threat budgets
        // Shell budget: how many extra nav-seconds we accept to get a better shell angle.
        //   Zeroed when stuck_override_active (ship pushes through shell fire).
        // Torpedo budget: much larger - surviving a torpedo is worth a major detour.
        let mut has_torpedoes = false;
        for obs in self.obstacles.values() {
            if obs.is_torpedo() {
                has_torpedoes = true;
                break;
            }
        }

        let shell_budget = if shells_safe || self.stuck_override_active {
            0.0
        } else {
            SHELL_NAV_BUDGET
        };
        let torpedo_budget = if has_torpedoes { TORPEDO_NAV_BUDGET } else { 0.0 };
        let budget_threshold = best_nav + shell_budget + torpedo_budget;

        // Pre-compute the minimum raw threat among budget-eligible candidates.
        // Normalising to relative scores means the best-achievable threat = 0.
        // When all arcs are hit equally (min > 0, e.g. ship stationary broadside),
        // every relative score is 0 and nav_score becomes the natural tiebreaker -
        // the arc that gets the ship to the destination wins instead of one that
        // merely presents a slightly different angle to the incoming shell.
        let mut min_shell_eligible = 0.0f32;
        let mut min_torp_eligible = 0.0f32;
        {
            let mut ms = f32::INFINITY;
            let mut mt = f32::INFINITY;
            for p in &pass_data {
                if p.nav_score > budget_threshold {
                    continue;
                }
                if !self.stuck_override_active {
                    ms = ms.min(p.threats.shell_score);
                }
                mt = mt.min(p.threats.torpedo_score);
            }
            if ms < f32::INFINITY {
                min_shell_eligible = ms;
            }
            if mt < f32::INFINITY {
                min_torp_eligible = mt;
            }
        }

        // Pass 2: pick lowest relative threat within budget, nav_score as tiebreaker.
        let mut best_idx: i32 = -1;
        let mut best_eff_threat = f32::INFINITY;
        for i in 0..pass_data.len() {
            if pass_data[i].nav_score > budget_threshold {
                continue;
            }
            if pass_data[i].any_obs_collision {
                any_collision = true;
            }

            // Shell score: suppressed during stuck override; otherwise normalised to
            // best-achievable so that "equally bad" arcs all score 0 here.
            let shell_t = if self.stuck_override_active {
                0.0
            } else {
                pass_data[i].threats.shell_score - min_shell_eligible
            };
            let mut eff_threat = shell_t + (pass_data[i].threats.torpedo_score - min_torp_eligible);

            // Commitment bias: penalise candidates opposing the committed dodge direction,
            // but only when this arc is strictly worse than the minimum-threat arc.
            if self.dodge_committed_rudder != 0.0 && eff_threat > 0.0 {
                if pass_data[i].rudder * self.dodge_committed_rudder < -0.01 {
                    eff_threat += DODGE_COMMITMENT_BIAS;
                }
            }

            // Primary criterion: lowest relative threat.
            // Tiebreaker (within floating-point noise): lowest nav_score.
            let better_threat = eff_threat < best_eff_threat;
            let equal_threat = !better_threat && eff_threat <= best_eff_threat + 1e-4;
            let better_nav = best_idx >= 0 && pass_data[i].nav_score < pass_data[best_idx as usize].nav_score;

            if better_threat || (equal_threat && better_nav) {
                best_eff_threat = eff_threat;
                best_idx = i as i32;
            }
        }

        // Safety fallback: best_nav is always within budget, so best_idx should
        // never be -1 when n_pass > 0.  Guard anyway.
        if best_idx == -1 {
            for i in 0..pass_data.len() {
                if pass_data[i].nav_score <= best_nav + 1e-3 {
                    best_idx = i as i32;
                    break;
                }
            }
        }

        // =========================================================
        // Pure-pursuit baseline gate
        // Only deviate from the navigator's desired rudder when the
        // winning arc offers a meaningful reduction in combined threat.
        // If the improvement over pure pursuit is < PURE_PURSUIT_MIN_IMPROVEMENT
        // (15 %), revert to pure pursuit to avoid unnecessary jinking.
        // Disabled when stuck_override_active (nav intent must push through).
        // =========================================================
        if best_idx != -1 && !self.stuck_override_active && !shells_safe {
            // Find pass_data entry that matches the pure-pursuit candidate
            // (desired_rudder, desired_throttle).  It is always added first as
            // rudder_offsets[0] == 0, so the closest-rudder match at the right
            // throttle will be it.
            let mut pp_idx: i32 = -1;
            let mut pp_rudder_diff = f32::INFINITY;
            for i in 0..pass_data.len() {
                if pass_data[i].throttle != desired_throttle {
                    continue;
                }
                let diff = (pass_data[i].rudder - desired_rudder).abs();
                if diff < pp_rudder_diff {
                    pp_rudder_diff = diff;
                    pp_idx = i as i32;
                }
            }
            if pp_idx != -1 && best_idx != pp_idx {
                let pp_threat = pass_data[pp_idx as usize].threats.combined();
                let win_threat = pass_data[best_idx as usize].threats.combined();
                // Only gate when pure pursuit actually has a non-trivial threat score.
                // When pp_threat == 0 both arcs are equally safe and nav score already
                // governs, so no gating is needed.
                if pp_threat > 1e-4 {
                    let improvement = (pp_threat - win_threat) / pp_threat;
                    if improvement < PURE_PURSUIT_MIN_IMPROVEMENT {
                        best_idx = pp_idx;
                    }
                }
            }
        }

        result.rudder = pass_data[best_idx as usize].rudder;
        result.throttle = pass_data[best_idx as usize].throttle;

        // Re-simulate winning arc for visualization
        self.winning_arc = self.predict_arc_internal(result.rudder, result.throttle, sim_lookahead);

        result.collision_imminent =
            any_collision || (result.rudder != desired_rudder) || (result.throttle != desired_throttle);

        self.perf_last_steering_candidates_total = steering_candidates_total;
        self.perf_last_steering_candidates_simulated = steering_candidates_simulated;
        self.perf_last_steering_terrain_rejects = steering_terrain_rejects;
        self.perf_last_steering_short_arc_rejects = steering_short_arc_rejects;
        self.perf_last_steering_arc_points_simulated = steering_arc_points_simulated;

        // --- Update dodge commitment ---
        // threats_active: mirrors the shells_safe reachability check so that
        // non-threatening shells (landing too far to reach) do not prevent the
        // commitment timer from clearing.
        let mut threats_active = !shells_safe;
        if !threats_active {
            for obs in self.obstacles.values() {
                if obs.is_torpedo() {
                    threats_active = true;
                    break;
                }
            }
        }

        if threats_active && (result.rudder - desired_rudder).abs() > 0.1 {
            let rudder_sign = if result.rudder > 0.0 { 1.0 } else { -1.0 };
            if self.dodge_committed_rudder == 0.0 || rudder_sign == self.dodge_committed_rudder {
                self.dodge_committed_rudder = rudder_sign;
                self.dodge_commitment_timer = DODGE_COMMITMENT_DURATION;
            }
        } else if !threats_active {
            self.dodge_committed_rudder = 0.0;
            self.dodge_commitment_timer = 0.0;
        }

        result
    }

    // ============================================================================
    // Pure pursuit steering
    // ============================================================================

    pub(crate) fn compute_pure_pursuit_rudder(&self) -> f32 {
        let wp = if !self.current_path.waypoints.is_empty()
            && self.current_wp_index < self.current_path.waypoints.len() as i32
        {
            self.current_path.waypoints[self.current_wp_index as usize]
        } else {
            self.target.position
        };

        let to_wp = wp - self.state.position;
        let forward_x = self.state.heading.sin();
        let forward_z = self.state.heading.cos();
        let along = to_wp.x * forward_x + to_wp.y * forward_z;

        if along < 0.0 {
            return self.compute_rudder_to_position(wp, false);
        }

        if to_wp.length_squared() > 1.0 {
            let wp_heading = to_wp.x.atan2(to_wp.y);
            return self.compute_rudder_to_heading(wp_heading, false);
        }
        0.0
    }

    // ============================================================================
    // Direction determination - is the target behind within the reverse zone?
    // ============================================================================

    pub(crate) fn is_target_behind_within_reverse_zone(&self, target_pos: godot::prelude::Vector2) -> bool {
        let to_target = target_pos - self.state.position;
        let forward_x = self.state.heading.sin();
        let forward_z = self.state.heading.cos();
        let along = to_target.x * forward_x + to_target.y * forward_z;
        let dist = to_target.length();

        // Tighter threshold: target must be more than 110 degrees off the bow
        // cos(110 deg) ~= -0.342, so along/dist must be less than that
        if dist < 1e-6 {
            return false;
        }
        if along / dist >= -0.342 {
            return false;
        }

        // Target is behind - check if it's within 3.0 x turning circle radius
        dist < self.params.turning_circle_radius * 3.0
    }
}
