use godot::prelude::*;
use std::f64::consts::PI;

use super::{
    ShipNavigator, SteeringChoice, ThreatEval, BOW_STERN_CLIP_START, DODGE_COMMITMENT_BIAS,
    DODGE_COMMITMENT_DURATION, GRAZE_MIN_FACTOR, PARKED_SPEED_THRESHOLD, SHELL_TIME_TOLERANCE,
    SOFT_TERRAIN_PENALTY, TORPEDO_VIRTUAL_CALIBER,
};
use crate::nav::types::{angle_difference, clamp_f, lerp_f, move_toward_f, normalize_angle, ArcPoint, DynamicObstacle};

/// Seconds added to a reverse arc the behaviour forbade: still a way out when every ahead arc is blocked.
const FORBID_REVERSE_PENALTY_S: f32 = 120.0;

impl ShipNavigator {
    /// Evaluate shell + torpedo threats along an arc. Returns separate scores so
    /// the caller can apply different budgets and suppress shells when the
    /// stuck override is active.
    pub(crate) fn score_arc_shell_threat(&self, arc: &[ArcPoint], end_speed: f32) -> ThreatEval {
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
        // TORPEDOES - swept test
        //
        // Between consecutive samples the torpedo's path in the ship's frame is
        // treated as a segment and clipped against the hull box grown by the
        // torpedo's radius. Point samples seconds apart missed nearly every
        // torpedo crossing the beam. Past the arc the ship runs on along its last
        // heading while its speed ramps toward `end_speed`, so a throttle chop
        // that lets a spread pass ahead is credited.
        // =========================================================
        let torps: Vec<&DynamicObstacle> = self.obstacles.values().filter(|o| o.is_torpedo() && o.velocity.length() >= 1.0).collect();
        if torps.is_empty() {
            return result;
        }
        let cal_weight = (TORPEDO_VIRTUAL_CALIBER * TORPEDO_VIRTUAL_CALIBER) / (200.0 * 200.0);
        const MAX_EXT_TIME: f32 = 90.0;
        const EXT_DT: f32 = 0.5;
        let last = *arc.last().unwrap();
        let speed_rate = self.params.max_speed / self.params.acceleration_time.max(0.1);
        // Arc points are seconds apart; one segment in the turning frame sweeps a receding torpedo back across the hull.
        let mut track: Vec<(Vector2, f32, f32)> = vec![(arc[0].position, arc[0].heading, arc[0].time)];
        for w in arc.windows(2) {
            let (a, b) = (w[0], w[1]);
            let n = ((b.time - a.time) / EXT_DT).ceil().max(1.0) as usize;
            let dh = angle_difference(a.heading, b.heading);
            for j in 1..=n {
                let s = j as f32 / n as f32;
                track.push((a.position.lerp(b.position, s), normalize_angle(a.heading + dh * s), lerp_f(a.time, b.time, s)));
            }
        }
        let (fx, fz) = (last.heading.sin(), last.heading.cos());
        let (mut pos, mut speed, mut t) = (last.position, last.speed, last.time);
        while t < MAX_EXT_TIME {
            speed = move_toward_f(speed, end_speed, EXT_DT * speed_rate);
            pos += Vector2::new(fx, fz) * speed * EXT_DT;
            t += EXT_DT;
            track.push((pos, last.heading, t));
        }
        let local = |torp: &DynamicObstacle, (p, h, t): (Vector2, f32, f32)| -> Vector2 {
            let rel = torp.position + torp.velocity * t - p;
            let (fx, fz) = (h.sin(), h.cos());
            Vector2::new(rel.x * fx + rel.y * fz, rel.x * fz - rel.y * fx)
        };
        for obs in torps {
            let (hx, hy) = (hsl + obs.radius, hsb + obs.radius);
            let mut prev = local(obs, track[0]);
            if prev.x.abs() <= hx && prev.y.abs() <= hy {
                continue;
            }
            for k in 1..track.len() {
                let cur = local(obs, track[k]);
                if let Some(f) = segment_enters_box(prev, cur, hx, hy) {
                    let hit = track[k - 1].2 + f * (track[k].2 - track[k - 1].2);
                    result.torpedo_score += cal_weight;
                    result.torpedo_time = result.torpedo_time.min(hit);
                    break;
                }
                prev = cur;
            }
        }

        result
    }

    /// Mean travel direction of the torpedoes that will reach us, nearest weighted most.
    fn torpedo_track(&self) -> Option<Vector2> {
        let mut sum = Vector2::ZERO;
        for o in self.obstacles.values().filter(|o| o.is_torpedo()) {
            let speed = o.velocity.length();
            let to_us = self.state.position - o.position;
            if speed < 1.0 || o.velocity.dot(to_us) <= 0.0 {
                continue;
            }
            sum += o.velocity / speed / (1.0 + to_us.length() / 1000.0);
        }
        (sum.length() > 1e-3).then(|| sum.normalized())
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
            let rel = obs.position - self.state.position;
            let near = if obs.is_torpedo() {
                rel.length() < obs.velocity.length() * 90.0 + self.params.ship_length
            } else {
                // Closest approach on both current tracks, padded by a turning circle
                // since our arc can bend toward it.
                let rv = obs.velocity - self.state.velocity;
                let horizon = engagement_range / self.params.max_speed.max(1.0);
                let t = if rv.length_squared() > 1e-6 { (-rel.dot(rv) / rv.length_squared()).clamp(0.0, horizon) } else { 0.0 };
                let miss = (self.params.ship_length + obs.length) * 0.5 + hard_clearance + self.params.turning_circle_radius;
                rel.length() < engagement_range && (rel + rv * t).length() < miss
            };
            if near {
                obstacles_safe = false;
                break;
            }
        }

        // Shells deliberately do NOT gate the fast path any more.  They only
        // break ties inside the torpedo override, which cannot be reached when
        // obstacles_safe holds -- so a ship in open water under gunfire takes the
        // one-arc fast path, and SkillEvade does the dodging.
        if terrain_safe && obstacles_safe {
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
            /// Hold the rudder until the bow bears on this point instead of the waypoint.
            aim: Option<Vector2>,
        }

        // Any torpedo in the obstacle set puts the candidate list into override
        // shape.  Cheap superset of "a torpedo actually threatens an arc" -- the
        // real test needs the simulated arcs, which do not exist yet.
        let torpedoes_present = self.obstacles.values().any(|o| o.is_torpedo());

        let rudder_offsets: [f32; 7] = [0.0, 0.3, -0.3, 0.6, -0.6, -1.0, 1.0];
        // Include all 7 offsets (+-0.3, +-0.6, +-1.0) so the ship can execute hard
        // full-rudder turns to dodge torpedoes - previously only +-0.3 were tried.
        let mut candidates: Vec<Candidate> = Vec::new();
        {
            let mut add = |r: f32, t: i32, aim: Option<Vector2>| {
                let r = clamp_f(r, -1.0, 1.0);
                if candidates
                    .iter()
                    .any(|c| (c.rudder - r).abs() < 0.05 && c.throttle == t && c.aim == aim)
                {
                    return;
                }
                candidates.push(Candidate { rudder: r, throttle: t, aim });
            };
            let mut add_candidate = |r: f32, t: i32| add(r, t, None);

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

            // Outrunning or combing a spread is frequently a FULL AHEAD
            // manoeuvre, and the offsets above only ever sample the throttle the
            // navigator already wanted (plus reverse).  Without these the
            // override could not choose speed at all.
            if torpedoes_present && desired_throttle < 4 {
                for &off in rudder_offsets.iter() {
                    add_candidate(desired_rudder + off, 4);
                }
            }
            if torpedoes_present {
                // Letting a wall pass ahead, and combing a spread: turn onto its
                // track (bow in or stern out) and hold, at speed or slowed.
                for &t in &[0, 2] {
                    for &r in &[desired_rudder, 0.0, 0.6, -0.6] {
                        add_candidate(r, t);
                    }
                }
                if let Some(track) = self.torpedo_track() {
                    for dir in [track, -track] {
                        let h = dir.x.atan2(dir.y);
                        let turn = -angle_difference(self.state.heading, h).signum();
                        let aim = Some(self.state.position + dir * 20000.0);
                        for &t in &[desired_throttle.max(2), 4, 2] {
                            add(turn, t, aim);
                            add(turn * 0.6, t, aim);
                        }
                    }
                }
            }
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
        const MAX_PASS_ENTRIES: usize = 48;
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
                let arc = match candidates[i].aim {
                    Some(aim) => self.predict_arc_to_heading(cand_rudder, cand_throttle, aim, sim_lookahead, sim_max_time, false),
                    None => self.predict_arc_internal(cand_rudder, cand_throttle, sim_lookahead),
                };
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

                let threats = self.score_arc_shell_threat(&arc, self.throttle_to_speed(cand_throttle));

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
                    candidates[i].aim.unwrap_or(wp_target),
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

                // Time for the bow to come onto the waypoint bearing.  Distance
                // to the waypoint is deliberately absent: scoring how closely the
                // arc passes it rewarded lazy rudders that sweep across over hard
                // turns that swing the bow onto it now.
                let arc_end = *arc.last().unwrap();
                let mut nav_score = arc_end.time;
                let to_wp = wp_target - arc_end.position;
                if to_wp.length() > 1.0 {
                    let mut wp_heading = to_wp.x.atan2(to_wp.y);
                    if rev_align {
                        wp_heading = normalize_angle(wp_heading + (PI as f32));
                    }
                    let h_err = angle_difference(arc_end.heading, wp_heading).abs();
                    if h_err >= HEADING_ALIGN_THRESH {
                        nav_score += (h_err / (PI as f32)) * 60.0;
                    }
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
                if self.target.forbid_reverse && cand_throttle < 0 && !torpedoes_present {
                    nav_score += FORBID_REVERSE_PENALTY_S;
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

                let threats = self.score_arc_shell_threat(&arc, self.throttle_to_speed(cand_throttle));

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
        // Selection
        // =========================================================
        // Shell evasion no longer lives here.  A steering optimiser that scores
        // "time to waypoint, subject to not being hit" has a degenerate optimum
        // -- stop -- and the enemy's fire control closes the loop around it: the
        // bot slows, the next salvo lands short, and the locally-optimal answer
        // to a short salvo is to keep the speed change.  That converged on zero
        // speed, which is the easiest possible thing to hit.  SkillEvade owns
        // shell evasion now, at the behaviour layer, where it can commit to a
        // pattern across salvos instead of re-deciding every frame.
        //
        // Two regimes remain:
        //   * the arc navigation would have taken eats no torpedo -> pure
        //     navigation, and SkillEvade keeps working the guns problem.
        //   * it eats one -> torpedo avoidance HARD OVERRIDES navigation,
        //     ranked lexicographically.
        //
        // Navigation's own answer is computed first because it is also the gate.
        // Entering the override off "any candidate is hit" armed it for torpedoes
        // the ship was never going to steer into -- every torpedo inside the
        // envelope put the ship in dodge mode and stood SkillEvade down, whether
        // or not the route was ever in the water.
        let mut nav_best_idx: usize = 0;
        let mut best_nav = f32::INFINITY;
        for i in 0..pass_data.len() {
            if pass_data[i].any_obs_collision {
                any_collision = true;
            }
            if pass_data[i].nav_score < best_nav {
                best_nav = pass_data[i].nav_score;
                nav_best_idx = i;
            }
        }

        let nav_best_hit = pass_data[nav_best_idx].threats.torpedo_score > 0.0;

        // Latch through the commitment window.  Mid-dodge, the nav arc goes clean
        // the instant the turn clears the torpedo, and the hit test carries no
        // clearance margin -- releasing there steers back across a torpedo that
        // is now much closer, which re-arms the override, which turns away again.
        let torpedoes_threaten = nav_best_hit || self.dodge_commitment_timer > 0.0;
        self.torpedo_override_active = torpedoes_threaten;

        let mut best_idx: i32 = nav_best_idx as i32;

        if torpedoes_threaten {
            // Lexicographic ranking.  Each key is only consulted when every key
            // before it ties, so navigation cannot buy its way past a torpedo.
            //   1. fewest torpedo hits          (torpedo_score is 100 per hit)
            //   2. latest first impact          (buys another decision cycle)
            //   3. lowest shell threat          (vary speed/heading against guns
            //                                    while dodging -- the arcs here
            //                                    already differ in throttle)
            //   4. lowest nav score             (get on with the mission)
            let mut best: Option<(f32, f32, f32, f32)> = None;
            for i in 0..pass_data.len() {
                let p = &pass_data[i];

                // Commitment: a candidate that reverses an in-progress dodge is
                // ranked as if it ate one more torpedo.  Half a second of
                // hysteresis is what stops the ship dithering between two
                // symmetric escapes and taking neither.
                let mut torp = p.threats.torpedo_score;
                if self.dodge_committed_rudder != 0.0
                    && p.rudder * self.dodge_committed_rudder < -0.01
                {
                    torp += DODGE_COMMITMENT_BIAS;
                }

                // Negated so that "larger is worse" holds for every key and the
                // whole tuple can be compared with a single <.
                let key = (torp, -p.threats.torpedo_time, p.threats.shell_score, p.nav_score);
                let better = match best {
                    None => true,
                    Some(b) => {
                        key.0 < b.0 - 1e-4
                            || ((key.0 - b.0).abs() <= 1e-4
                                && (key.1 < b.1 - 1e-4
                                    || ((key.1 - b.1).abs() <= 1e-4
                                        && (key.2 < b.2 - 1e-4
                                            || ((key.2 - b.2).abs() <= 1e-4 && key.3 < b.3)))))
                    }
                };
                if better {
                    best = Some(key);
                    best_idx = i as i32;
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
        // Commitment is a torpedo-override concept only.  It used to be armed by
        // shell threat too, which meant the ship latched a rudder direction in
        // response to gunfire and then spent the next half second refusing the
        // opposite turn -- part of what made bots freeze under fire.
        if nav_best_hit && (result.rudder - desired_rudder).abs() > 0.1 {
            let rudder_sign = if result.rudder > 0.0 { 1.0 } else { -1.0 };
            if self.dodge_committed_rudder == 0.0 || rudder_sign == self.dodge_committed_rudder {
                self.dodge_committed_rudder = rudder_sign;
                self.dodge_commitment_timer = DODGE_COMMITMENT_DURATION;
            }
        } else if !torpedoes_threaten {
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

/// Fraction along a->b where it first enters the box |x| <= hx, |y| <= hy.
fn segment_enters_box(a: Vector2, b: Vector2, hx: f32, hy: f32) -> Option<f32> {
    let (mut lo, mut hi) = (0.0f32, 1.0f32);
    let d = b - a;
    for (p, dp, h) in [(a.x, d.x, hx), (a.y, d.y, hy)] {
        if dp.abs() < 1e-6 {
            if p.abs() > h {
                return None;
            }
            continue;
        }
        let (t0, t1) = ((-h - p) / dp, (h - p) / dp);
        lo = lo.max(t0.min(t1));
        hi = hi.min(t0.max(t1));
        if lo > hi {
            return None;
        }
    }
    Some(lo)
}

#[cfg(test)]
mod torpedo_tests {
    use super::*;

    #[test]
    fn crossing_between_samples_hits() {
        assert!(segment_enters_box(Vector2::new(0.0, -80.0), Vector2::new(0.0, 80.0), 55.0, 6.0).is_some());
        assert!(segment_enters_box(Vector2::new(70.0, -80.0), Vector2::new(70.0, 80.0), 55.0, 6.0).is_none());
        let f = segment_enters_box(Vector2::new(-100.0, 0.0), Vector2::new(100.0, 0.0), 50.0, 6.0).unwrap();
        assert!((f - 0.25).abs() < 1e-6);
    }
}
