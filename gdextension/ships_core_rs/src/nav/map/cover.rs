use godot::prelude::*;
use std::f64::consts::PI;

use super::NavigationMap;
use crate::nav::types::{normalize_angle, CoverZone};

impl NavigationMap {
    pub(crate) fn get_nearest_island_impl(&self, position: Vector2) -> VarDictionary {
        let mut result = VarDictionary::new();

        if self.islands.is_empty() {
            result.set("valid", false);
            return result;
        }

        // NOTE: despite the name, `best_dist_sq` holds `effective_dist` (a
        // plain distance, not squared) — a naming leftover from the C++.
        // Preserved faithfully; not fixed here.
        let mut best_dist_sq = f32::INFINITY;
        let mut best_idx: i32 = -1;

        for (i, island) in self.islands.iter().enumerate() {
            let dx = position.x - island.center.x;
            let dz = position.y - island.center.y; // .y is Z in Vector2
            let dist_sq = dx * dx + dz * dz;
            // Use distance from center minus radius as the effective distance
            let effective_dist = dist_sq.sqrt() - island.radius;
            if effective_dist < best_dist_sq {
                best_dist_sq = effective_dist;
                best_idx = i as i32;
            }
        }

        if best_idx >= 0 {
            result = self.islands[best_idx as usize].to_dictionary();
            result.set("valid", true);
        } else {
            result.set("valid", false);
        }

        result
    }

    pub(crate) fn compute_cover_zone_internal(
        &self,
        island_id: i32,
        threat_direction: Vector2,
        ship_clearance: f32,
        turning_radius: f32,
    ) -> CoverZone {
        let mut result = CoverZone::default();

        if island_id < 0 || island_id >= self.islands.len() as i32 {
            return result;
        }

        let island = &self.islands[island_id as usize];
        result.center = island.center;

        // Normalize threat direction
        let threat_len = threat_direction.length();
        if threat_len < 0.0001 {
            return result;
        }
        let threat_dir = threat_direction / threat_len;

        // The "cover" direction is opposite to the threat.
        // We want to find navigable water on the far side of the island from the threat.
        // atan2(x, z) for heading convention. Both args are f32, so this is the float
        // overload of atan2 (no promotion); `threat_angle` stays f32.
        let threat_angle: f32 = threat_dir.x.atan2(threat_dir.y);
        // Math::PI is double in godot-cpp: `threat_angle + Math::PI` promotes to f64 and
        // narrows back to f32 on the (float-typed) normalize_angle argument.
        let cover_angle = normalize_angle((threat_angle as f64 + PI) as f32);

        // Sweep angles in the hemisphere opposite the threat.
        const SWEEP_SAMPLES: i32 = 36;
        // `Math::PI * 0.8f`: double * float promotes 0.8f to double, product computed in
        // double, narrowed to f32 on assignment to the (float) SWEEP_RANGE constant.
        let sweep_range: f32 = (PI * (0.8f32 as f64)) as f32; // Sweep 144 degrees (+-72 from cover dir)

        let mut best_score = f32::NEG_INFINITY;
        let mut valid_arc_start = cover_angle;
        let mut valid_arc_end = cover_angle;
        let mut found_any = false;
        let mut arc_started = false;

        #[derive(Clone, Copy)]
        struct CoverCandidate {
            position: Vector2,
            dist_from_island: f32,
            score: f32,
            valid: bool,
        }

        let mut candidates: Vec<CoverCandidate> = Vec::new();

        for i in 0..SWEEP_SAMPLES {
            let t = i as f32 / (SWEEP_SAMPLES - 1) as f32;
            let mut angle = cover_angle + sweep_range * (t - 0.5);
            angle = normalize_angle(angle);

            // Direction from island center at this angle.
            let dir = Vector2::new(angle.sin(), angle.cos());

            // March outward from island edge. The cover position should be close
            // enough to the island to benefit from concealment, but far enough for
            // the ship to maneuver safely.
            //
            // Use turning_radius * 1.5 as the max buffer from the island edge.
            // This gives the ship enough room to execute a full turn without
            // colliding with the island, while staying close enough to benefit
            // from the island's visual/radar screening.
            let start_dist = island.radius + ship_clearance;
            let max_buffer = turning_radius * 1.5;
            let end_dist = (start_dist + self.cell_size).max(island.radius + max_buffer);
            let step = self.cell_size;

            let mut best_at_angle = CoverCandidate {
                position: Vector2::ZERO,
                dist_from_island: 0.0,
                score: f32::NEG_INFINITY,
                valid: false,
            };

            let mut d = start_dist;
            while d <= end_dist {
                let test_pos = island.center + dir * d;

                if !self.is_navigable_impl(test_pos.x, test_pos.y, ship_clearance) {
                    d += step;
                    continue;
                }

                // Score this position:
                // - Prefer positions farther from the island (more maneuvering room)
                // - Prefer positions closer to cover_angle (more directly behind the island)
                // - Must be at least min_engagement_range from island center in threat direction
                let angular_diff = normalize_angle(angle - cover_angle).abs();
                let angular_score = 1.0 - (angular_diff / sweep_range); // 1.0 at center, 0 at edges
                let distance_score = (d - start_dist) / (end_dist - start_dist); // Prefer some distance

                // Check engagement range: the position must be within weapon range.
                // We approximate: position should be within max_engagement_range of where
                // threats would be.
                let score = angular_score * 2.0 + distance_score * 1.0;

                if score > best_at_angle.score {
                    best_at_angle.position = test_pos;
                    best_at_angle.dist_from_island = d;
                    best_at_angle.score = score;
                    best_at_angle.valid = true;
                }

                d += step;
            }

            if best_at_angle.valid {
                candidates.push(best_at_angle);

                if !arc_started {
                    valid_arc_start = angle;
                    arc_started = true;
                }
                valid_arc_end = angle;
                found_any = true;

                if best_at_angle.score > best_score {
                    best_score = best_at_angle.score;
                    result.best_position = best_at_angle.position;
                    result.min_radius = island.radius + ship_clearance;
                    result.max_radius = best_at_angle.dist_from_island;
                }
            }
        }

        if !found_any {
            return result; // valid = false
        }

        result.arc_start = valid_arc_start;
        result.arc_end = valid_arc_end;
        result.valid = true;

        // Best heading: perpendicular to threat direction (broadside).
        // Two options — pick the one closer to the cover direction.
        let broadside1 = normalize_angle((threat_angle as f64 + PI * 0.5) as f32);
        let broadside2 = normalize_angle((threat_angle as f64 - PI * 0.5) as f32);

        // Prefer the broadside heading that keeps the ship roughly facing the threat
        // (so guns can bear).
        let diff1 = normalize_angle(broadside1 - cover_angle).abs();
        let diff2 = normalize_angle(broadside2 - cover_angle).abs();
        result.best_heading = if diff1 <= diff2 { broadside1 } else { broadside2 };

        // Compute a zone radius for station-keeping based on the arc extent.
        // The zone should be large enough to be comfortable but not so large that
        // the ship drifts out of cover.
        if !candidates.is_empty() {
            let mut avg_dist = 0.0f32;
            for c in &candidates {
                avg_dist += c.dist_from_island;
            }
            avg_dist /= candidates.len() as f32;
            result.min_radius = island.radius + ship_clearance;
            result.max_radius = avg_dist;
        }

        result
    }

    pub(crate) fn find_cover_candidates_impl(
        &self,
        island_id: i32,
        threat_positions: PackedVector2Array,
        danger_center: Vector2,
        ship_position: Vector2,
        ship_clearance: f32,
        gun_range: f32,
        max_results: i32,
        max_candidates: i32,
    ) -> Array<VarDictionary> {
        let mut output: Array<VarDictionary> = Array::new();

        if !self.built {
            return output;
        }
        if island_id < 0 || island_id >= self.islands.len() as i32 {
            return output;
        }

        let island = &self.islands[island_id as usize];
        let threat_count = threat_positions.len() as i32;

        if threat_count == 0 {
            return output;
        }

        // --- Strategy ---
        // Walk a band of SDF cells around the island where:
        //   sdf >= ship_clearance  (navigable)
        //   sdf <= ship_clearance + buffer  (close to shore = good cover)
        //
        // For each cell, test LOS (SDF raycast, clearance=0) to every threat.
        // Score by concealment, shore proximity, travel cost, and opposite-side bias.
        //
        // Shootability is NOT evaluated here — shells travel in parabolic arcs and
        // CAs shoot OVER islands. The GDScript caller validates shootability via
        // the full ballistic simulation (Gun.sim_can_shoot_over_terrain) by
        // iterating through this ranked list asynchronously.

        let search_margin = ship_clearance + self.cell_size * 6.0;
        let max_sdf_for_cover = ship_clearance + self.cell_size * 4.0;

        let box_min_x = island.center.x - island.radius - search_margin;
        let box_max_x = island.center.x + island.radius + search_margin;
        let box_min_z = island.center.y - island.radius - search_margin;
        let box_max_z = island.center.y + island.radius + search_margin;

        let (gx_min_f, gz_min_f) = self.world_to_grid(box_min_x, box_min_z);
        let (gx_max_f, gz_max_f) = self.world_to_grid(box_max_x, box_max_z);

        let gx_min = (gx_min_f.floor() as i32).max(0);
        let gz_min = (gz_min_f.floor() as i32).max(0);
        let gx_max = (gx_max_f.ceil() as i32).min(self.grid_width - 1);
        let gz_max = (gz_max_f.ceil() as i32).min(self.grid_height - 1);

        // --- Phase 1: collect navigable cells in the near-shore band ---
        #[derive(Clone, Copy)]
        struct CoverCell {
            wx: f32,
            wz: f32,
            sdf_val: f32,
        }
        let mut candidates: Vec<CoverCell> = Vec::with_capacity((max_candidates as usize) * 2);

        let area_cells = (gx_max - gx_min + 1) * (gz_max - gz_min + 1);
        let mut stride = 1;
        if area_cells > max_candidates * 8 {
            stride = 2;
        }
        if area_cells > max_candidates * 32 {
            stride = 3;
        }

        for iz in (gz_min..=gz_max).step_by(stride as usize) {
            for ix in (gx_min..=gx_max).step_by(stride as usize) {
                let sdf_val = self.get_cell(ix, iz);
                if sdf_val < ship_clearance {
                    continue;
                }
                if sdf_val > max_sdf_for_cover {
                    continue;
                }

                let (wx, wz) = self.grid_to_world(ix, iz);

                let dx_d = wx - danger_center.x;
                let dz_d = wz - danger_center.y;
                if dx_d * dx_d + dz_d * dz_d > gun_range * gun_range {
                    continue;
                }

                candidates.push(CoverCell { wx, wz, sdf_val });
            }
        }

        if candidates.is_empty() {
            return output;
        }

        // Subsample if too many
        if candidates.len() as i32 > max_candidates {
            let keep_stride = candidates.len() as i32 / max_candidates + 1;
            let mut sub: Vec<CoverCell> = Vec::with_capacity(max_candidates as usize);
            let mut i = 0usize;
            while i < candidates.len() {
                sub.push(candidates[i]);
                i += keep_stride as usize;
            }
            candidates = sub;
        }

        // Pre-compute average threat position for opposite-side bias
        let mut avg_tx = 0.0f32;
        let mut avg_tz = 0.0f32;
        for ti in 0..threat_count {
            let p = threat_positions[ti as usize];
            avg_tx += p.x;
            avg_tz += p.y;
        }
        avg_tx /= threat_count as f32;
        avg_tz /= threat_count as f32;
        let island_to_threat_x = avg_tx - island.center.x;
        let island_to_threat_z = avg_tz - island.center.y;
        let len_t = (island_to_threat_x * island_to_threat_x + island_to_threat_z * island_to_threat_z).sqrt();

        let proximity_range = max_sdf_for_cover - ship_clearance;

        // --- Phase 2: score each candidate ---
        #[derive(Clone, Copy)]
        struct ScoredCell {
            wx: f32,
            wz: f32,
            sdf_val: f32,
            hidden_count: i32,
            score: f32,
        }
        let mut scored: Vec<ScoredCell> = Vec::with_capacity(candidates.len());

        for cell in &candidates {
            let cell_pos = Vector2::new(cell.wx, cell.wz);

            // Test LOS to each threat
            let mut hidden_count: i32 = 0;
            for ti in 0..threat_count {
                let ray = self.raycast_internal(cell_pos, threat_positions[ti as usize], 0.0);
                if ray.hit {
                    hidden_count += 1;
                }
            }

            let mut score = 0.0f32;

            // Primary: threats hidden (1000 per threat)
            score += hidden_count as f32 * 1000.0;

            // Proximity to shore: tighter = better (up to 80 pts)
            if proximity_range > 0.001 {
                score += (1.0 - (cell.sdf_val - ship_clearance) / proximity_range) * 80.0;
            }

            // Travel distance penalty
            let dx_s = cell.wx - ship_position.x;
            let dz_s = cell.wz - ship_position.y;
            score -= (dx_s * dx_s + dz_s * dz_s).sqrt() * 0.03;

            // Opposite-side bias
            if len_t > 0.001 {
                let ic_x = cell.wx - island.center.x;
                let ic_z = cell.wz - island.center.y;
                let len_c = (ic_x * ic_x + ic_z * ic_z).sqrt();
                if len_c > 0.001 {
                    let dot = (ic_x * island_to_threat_x + ic_z * island_to_threat_z) / (len_c * len_t);
                    score += (-dot) * 50.0;
                }
            }

            scored.push(ScoredCell {
                wx: cell.wx,
                wz: cell.wz,
                sdf_val: cell.sdf_val,
                hidden_count,
                score,
            });
        }

        // --- Phase 3: for top coarse candidates, do fine-grained local refinement ---
        // Sort descending by score. C++ uses std::sort (unstable) here, so we mirror it
        // with sort_unstable_by; ties have no defined order in either language.
        scored.sort_unstable_by(|a, b| b.score.total_cmp(&a.score));

        // Take the top N coarse winners and refine each with a 5x5 local search
        let refine_count = (scored.len() as i32).min(max_results * 2);
        let mut refined: Vec<ScoredCell> = Vec::with_capacity((refine_count.max(0) as usize) * 25);

        for ri in 0..refine_count {
            let base = scored[ri as usize];
            // Include the coarse cell itself
            refined.push(base);

            let (fine_gx, fine_gz) = self.world_to_grid(base.wx, base.wz);
            let fine_cx = fine_gx.round() as i32;
            let fine_cz = fine_gz.round() as i32;

            for dz in -2..=2 {
                for dx in -2..=2 {
                    if dx == 0 && dz == 0 {
                        continue;
                    }
                    let nx = fine_cx + dx;
                    let nz = fine_cz + dz;
                    if !self.in_bounds(nx, nz) {
                        continue;
                    }

                    let sdf_val = self.get_cell(nx, nz);
                    if sdf_val < ship_clearance {
                        continue;
                    }
                    if sdf_val > max_sdf_for_cover {
                        continue;
                    }

                    let (wx, wz) = self.grid_to_world(nx, nz);

                    let dx_d = wx - danger_center.x;
                    let dz_d = wz - danger_center.y;
                    if dx_d * dx_d + dz_d * dz_d > gun_range * gun_range {
                        continue;
                    }

                    let cell_pos = Vector2::new(wx, wz);

                    let mut hidden_count: i32 = 0;
                    for ti in 0..threat_count {
                        let ray = self.raycast_internal(cell_pos, threat_positions[ti as usize], 0.0);
                        if ray.hit {
                            hidden_count += 1;
                        }
                    }

                    let mut score = hidden_count as f32 * 1000.0;

                    if proximity_range > 0.001 {
                        score += (1.0 - (sdf_val - ship_clearance) / proximity_range) * 80.0;
                    }

                    let dx_s2 = wx - ship_position.x;
                    let dz_s2 = wz - ship_position.y;
                    score -= (dx_s2 * dx_s2 + dz_s2 * dz_s2).sqrt() * 0.03;

                    if len_t > 0.001 {
                        let ic_x = wx - island.center.x;
                        let ic_z = wz - island.center.y;
                        let len_c = (ic_x * ic_x + ic_z * ic_z).sqrt();
                        if len_c > 0.001 {
                            let dot = (ic_x * island_to_threat_x + ic_z * island_to_threat_z) / (len_c * len_t);
                            score += (-dot) * 50.0;
                        }
                    }

                    refined.push(ScoredCell { wx, wz, sdf_val, hidden_count, score });
                }
            }
        }

        // --- Phase 4: sort all refined candidates, deduplicate nearby, and return top N ---
        refined.sort_unstable_by(|a, b| b.score.total_cmp(&a.score));

        // Deduplicate: skip candidates within 1.5 cells of an already-emitted one
        let dedup_dist_sq = (self.cell_size * 1.5) * (self.cell_size * 1.5);
        let mut final_list: Vec<ScoredCell> = Vec::with_capacity(max_results.max(0) as usize);

        for c in &refined {
            if final_list.len() as i32 >= max_results {
                break;
            }

            let mut too_close = false;
            for existing in &final_list {
                let ddx = c.wx - existing.wx;
                let ddz = c.wz - existing.wz;
                if ddx * ddx + ddz * ddz < dedup_dist_sq {
                    too_close = true;
                    break;
                }
            }
            if too_close {
                continue;
            }

            final_list.push(*c);
        }

        // Build output array
        for c in &final_list {
            let mut d = VarDictionary::new();
            d.set("position", Vector2::new(c.wx, c.wz));
            d.set("hidden_count", c.hidden_count);
            d.set("total_threats", threat_count);
            d.set("all_hidden", c.hidden_count >= threat_count);
            d.set("sdf_distance", c.sdf_val);
            d.set("score", c.score);
            output.push(&d);
        }

        output
    }

    pub(crate) fn safe_nav_point_internal(
        &self,
        ship_position: Vector2,
        candidate: Vector2,
        clearance: f32,
        turning_radius: f32,
    ) -> Vector2 {
        if !self.built {
            return candidate;
        }

        // Clamp candidate into map bounds so that off-map points project to the
        // nearest edge rather than gradient-walking into a map corner.
        let mut candidate = candidate;
        let mut cx = candidate.x;
        let mut cz = candidate.y;
        self.clamp_world_to_bounds(&mut cx, &mut cz);
        candidate.x = cx;
        candidate.y = cz;

        let mut dist = self.get_distance_impl(candidate.x, candidate.y);

        // If the candidate has plenty of room, return it unchanged.
        // The "danger zone" is anything within turning_radius of land — a ship heading
        // straight at a coastline from this distance may not be able to turn away in time.
        let safe_threshold = clearance + turning_radius * 0.75;
        if dist >= safe_threshold {
            return candidate;
        }

        // --- Step 1: If inside land or below hard clearance, push out along SDF gradient ---
        let mut adjusted = candidate;
        if dist < clearance {
            let mut grad = self.get_gradient_impl(candidate.x, candidate.y);
            if grad.length_squared() < 0.0001 {
                // No gradient info — try pushing toward ship position as fallback
                let to_ship = ship_position - candidate;
                let to_ship_len = to_ship.length();
                if to_ship_len > 0.1 {
                    grad = to_ship / to_ship_len;
                } else {
                    return candidate; // Can't determine direction, bail
                }
            }
            // Push out of land: penetration depth + clearance + a buffer of half the turning radius
            let push_dist = dist.abs() + clearance + turning_radius * 0.5;
            adjusted.x = candidate.x + grad.x * push_dist;
            adjusted.y = candidate.y + grad.y * push_dist;

            // Re-check — if still not navigable, iteratively push further
            let new_dist = self.get_distance_impl(adjusted.x, adjusted.y);
            if new_dist < clearance {
                adjusted.x += grad.x * clearance;
                adjusted.y += grad.y * clearance;
            }
            dist = self.get_distance_impl(adjusted.x, adjusted.y);
        }

        // --- Step 2: If near a coastline (within safe_threshold), adjust tangentially ---
        // The key insight: when a destination is close to shore, a ship approaching it
        // from far away will often be heading ~perpendicular to the coast. This creates
        // a situation where the ship can't turn away in time. We slide the destination
        // along the coast so the ship approaches more tangentially.
        if dist < safe_threshold && dist > 0.0 {
            // Get the coast normal (gradient points away from land = into water)
            let coast_normal = self.get_gradient_impl(adjusted.x, adjusted.y);
            if coast_normal.length_squared() < 0.0001 {
                return adjusted;
            }

            // Compute approach direction: from ship to candidate
            let approach_dir_raw = adjusted - ship_position;
            let approach_len = approach_dir_raw.length();
            if approach_len < 1.0 {
                return adjusted;
            }
            let approach_dir = approach_dir_raw / approach_len;

            // How perpendicular is the approach to the coastline?
            // dot(approach_dir, coast_normal) = cos(angle between approach and coast normal)
            // If |dot| is high, the ship is heading straight into/away from shore.
            // If |dot| is low, the ship is moving parallel to shore (safe).
            let perpendicularity = approach_dir.dot(coast_normal).abs();

            // Only adjust if approach is significantly perpendicular (> ~30 degrees from parallel)
            if perpendicularity > 0.5 {
                // Compute the tangent direction along the coast.
                // tangent = perpendicular to coast_normal, choosing the direction that
                // most closely aligns with the current approach direction.
                let tangent1 = Vector2::new(coast_normal.y, -coast_normal.x); // rotate 90 CW
                let tangent2 = Vector2::new(-coast_normal.y, coast_normal.x); // rotate 90 CCW

                // Pick the tangent that best aligns with approach direction
                let tangent = if approach_dir.dot(tangent1) > approach_dir.dot(tangent2) {
                    tangent1
                } else {
                    tangent2
                };

                // How much to slide depends on:
                //   - How perpendicular the approach is (more perpendicular -> more slide)
                //   - How close to shore (closer -> more slide)
                //   - Ship turning radius (larger -> more slide needed)
                let proximity = 1.0 - (dist / safe_threshold); // 0 at threshold, 1 at shore
                let slide_strength = perpendicularity * proximity;

                // Slide distance: up to 1.5x turning radius for the worst case
                let slide_dist = turning_radius * 1.5 * slide_strength;

                // Apply tangential slide
                let mut slid = adjusted;
                slid.x += tangent.x * slide_dist;
                slid.y += tangent.y * slide_dist;

                // Also push further away from shore proportional to perpendicularity
                let push_extra = turning_radius * 0.5 * slide_strength;
                slid.x += coast_normal.x * push_extra;
                slid.y += coast_normal.y * push_extra;

                // Verify the slid point is actually navigable
                let slid_dist = self.get_distance_impl(slid.x, slid.y);
                if slid_dist >= clearance {
                    adjusted = slid;
                } else {
                    // Slid point is worse — just push the original further from shore
                    let needed = safe_threshold - dist;
                    adjusted.x += coast_normal.x * needed;
                    adjusted.y += coast_normal.y * needed;
                }
            } else {
                // Approach is already roughly parallel — just ensure minimum distance
                if dist < clearance + turning_radius * 0.25 {
                    let needed = (clearance + turning_radius * 0.25) - dist;
                    adjusted.x += coast_normal.x * needed;
                    adjusted.y += coast_normal.y * needed;
                }
            }
        }

        adjusted
    }

    pub(crate) fn validate_destination_internal(
        &self,
        ship_position: Vector2,
        destination: Vector2,
        clearance: f32,
        turning_radius: f32,
    ) -> Vector2 {
        if !self.built {
            return destination;
        }

        // Clamp destination into map bounds so that off-map points project to the
        // nearest edge rather than gradient-walking into a map corner.
        let mut destination = destination;
        let mut dx = destination.x;
        let mut dz = destination.y;
        self.clamp_world_to_bounds(&mut dx, &mut dz);
        destination.x = dx;
        destination.y = dz;

        // First pass: make the destination itself safe
        let mut safe_dest = self.safe_nav_point_internal(ship_position, destination, clearance, turning_radius);

        // Second pass: check if the path from ship to destination passes dangerously
        // close to any land. Use SDF raycast to find the closest land approach.
        let ray = self.raycast_internal(ship_position, safe_dest, clearance + turning_radius * 0.5);

        if !ray.hit {
            // Clear path — destination is safe
            return safe_dest;
        }

        // The direct line clips land. The A* pathfinder will route around it, but
        // we should check whether the destination itself is in a "pocket" that
        // forces the ship to approach from a dangerous angle.

        // Check: is the destination on the far side of an island from the ship?
        // If so, the pathfinder will route around, and the last segment of the path
        // will approach from a different direction. Re-validate from the midpoint
        // of the ray hit to the destination.
        let approach_point = ray.position;

        // Get the coast normal at the point where we'd clip land
        let clip_normal = self.get_gradient_impl(approach_point.x, approach_point.y);
        if clip_normal.length_squared() < 0.0001 {
            return safe_dest;
        }

        // The ship will actually approach the destination from roughly where the
        // path curves around the island. Check if the destination is in a narrow
        // gap or inlet where any approach would be dangerous.
        let dest_dist = self.get_distance_impl(safe_dest.x, safe_dest.y);
        if dest_dist < clearance + turning_radius {
            // Destination is tight — make sure it's approached tangentially
            // by re-running safe_nav_point with the likely approach direction
            // (the direction from the ray hit point, offset by the coast normal)
            let likely_approach = approach_point + clip_normal * turning_radius;
            safe_dest = self.safe_nav_point_internal(likely_approach, safe_dest, clearance, turning_radius);
        }

        safe_dest
    }
}
