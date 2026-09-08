use godot::prelude::*;
use std::cmp::Reverse;

use super::NavigationMap;
use crate::nav::types::{waypoint_flags::WP_NONE, PathResult, PathSearch, PqEntry};

/// 8-connected neighbour offsets, declared locally in the C++ A* loop and paired
/// there with a 1.414 diagonal constant.
const DX8: [i32; 8] = [-1, 0, 1, -1, 1, -1, 0, 1];
const DZ8: [i32; 8] = [-1, -1, -1, 0, 0, 1, 1, 1];

impl NavigationMap {
    pub(crate) fn find_path_internal(
        &self,
        from: Vector2,
        to: Vector2,
        clearance: f32,
        turning_radius: f32,
    ) -> PathResult {
        let mut search = self.sync_search.borrow_mut();
        if self.begin_path_search(&mut search, from, to, clearance, turning_radius) {
            return search.result.clone();
        }
        let max_iterations = search.max_iterations;
        self.continue_path_search(&mut search, max_iterations);
        self.finish_path_search(&mut search)
    }

    pub(crate) fn begin_path_search(
        &self,
        search: &mut PathSearch,
        from: Vector2,
        to: Vector2,
        clearance: f32,
        turning_radius: f32,
    ) -> bool {
        search.reset();
        search.result.valid = false;
        search.result.total_distance = 0.0;

        if !self.built {
            search.complete = true;
            return true;
        }

        search.from = from;
        search.to = to;
        search.clearance = clearance;
        search.clearance_world = clearance;

        // Clamp to map bounds so off-map points project to the nearest edge
        // rather than landing on a far corner after grid clamping.
        let (mut from_x, mut from_z) = (from.x, from.y);
        let (mut to_x, mut to_z) = (to.x, to.y);
        self.clamp_world_to_bounds(&mut from_x, &mut from_z);
        self.clamp_world_to_bounds(&mut to_x, &mut to_z);

        let (gx_start, gz_start) = self.world_to_grid(from_x, from_z);
        let (gx_end, gz_end) = self.world_to_grid(to_x, to_z);

        search.sx = gx_start.round() as i32;
        search.sz = gz_start.round() as i32;
        search.ex = gx_end.round() as i32;
        search.ez = gz_end.round() as i32;

        search.sx = 0.max(search.sx.min(self.grid_width - 1));
        search.sz = 0.max(search.sz.min(self.grid_height - 1));
        search.ex = 0.max(search.ex.min(self.grid_width - 1));
        search.ez = 0.max(search.ez.min(self.grid_height - 1));

        let clearance_world = search.clearance_world;
        let (mut sx, mut sz) = (search.sx, search.sz);
        if !self.find_nearest_navigable(&mut sx, &mut sz, clearance_world) {
            godot_print!("[NavigationMap] find_path: start position is not navigable and no nearby navigable cell found");
            search.sx = sx;
            search.sz = sz;
            search.complete = true;
            return true;
        }
        search.sx = sx;
        search.sz = sz;

        let (mut ex, mut ez) = (search.ex, search.ez);
        if !self.find_nearest_navigable(&mut ex, &mut ez, clearance_world) {
            search.ex = ex;
            search.ez = ez;
            godot_print!(
                "[NavigationMap] find_path: end position is not navigable and no nearby navigable cell found ex: {} ez: {}",
                search.ex,
                search.ez
            );
            search.complete = true;
            return true;
        }
        search.ex = ex;
        search.ez = ez;

        if !self.same_region(search.sx, search.sz, search.ex, search.ez) {
            godot_print!("[NavigationMap] find_path: start and end are in different water regions (unreachable)");
            search.complete = true;
            return true;
        }

        if search.sx == search.ex && search.sz == search.ez {
            let (wx, wz) = self.grid_to_world(search.sx, search.sz);
            search.result.waypoints.push(Vector2::new(wx, wz));
            search.result.valid = true;
            search.result.total_distance = 0.0;
            search.complete = true;
            return true;
        }

        // Direct LOS shortcut: skip A* entirely.
        if self.line_of_sight(search.sx, search.sz, search.ex, search.ez, clearance) {
            search.result.waypoints.push(from);
            search.result.waypoints.push(to);
            search.result.flags.push(WP_NONE);
            search.result.flags.push(WP_NONE);
            search.result.valid = true;
            search.result.total_distance = from.distance_to(to);
            search.complete = true;
            return true;
        }

        search.grid_width = self.grid_width;
        search.grid_height = self.grid_height;
        search.cell_size = self.cell_size;
        search.turning_radius = turning_radius;

        let total_cells = self.grid_width * self.grid_height;

        search.end_idx = search.ez * search.grid_width + search.ex;
        search.start_idx = search.sz * search.grid_width + search.sx;

        search.allocate(total_cells);
        search.current_gen = search.current_gen.wrapping_add(1);
        if search.current_gen == 0 {
            search.open_gen.fill(0);
            search.closed_gen.fill(0);
            search.current_gen = 1;
        }

        let start_idx = search.start_idx as usize;
        search.g_cost[start_idx] = 0.0;
        search.open_gen[start_idx] = search.current_gen;
        let h = self.heuristic(search.sx, search.sz, search.ex, search.ez);
        search.open_set.push(Reverse(PqEntry(h, search.start_idx)));

        search.parent[start_idx] = search.start_idx;
        search.parent_dir[start_idx] = -1;

        search.max_iterations = total_cells.min(300000);
        search.active = true;

        // Temporary straight-line path so the ship can start moving while A*
        // computes the real one.
        search.result.waypoints.clear();
        search.result.flags.clear();
        search.result.waypoints.push(from);
        search.result.waypoints.push(to);
        search.result.flags.push(WP_NONE);
        search.result.flags.push(WP_NONE);
        search.result.valid = true;
        search.result.total_distance = from.distance_to(to);

        false
    }

    pub(crate) fn continue_path_search(&self, search: &mut PathSearch, max_iterations: i32) -> bool {
        if !search.active || search.complete {
            return true;
        }

        let mut budget = max_iterations;

        // Cell A* only enforces hard clearance; route choice is geometric distance.
        let hard_clearance = search.clearance_world;

        while !search.open_set.is_empty() && search.iterations < search.max_iterations && budget > 0 {
            budget -= 1;
            search.iterations += 1;

            let Reverse(PqEntry(_f, ci)) = search.open_set.pop().unwrap();
            let ciu = ci as usize;

            if search.closed_gen[ciu] == search.current_gen {
                continue;
            }
            search.closed_gen[ciu] = search.current_gen;

            if ci == search.end_idx {
                search.found = true;
                break;
            }

            let cx = ci % search.grid_width;
            let cz = ci / search.grid_width;
            let cg = search.g_cost[ciu];

            let sdf_here = self.get_cell(cx, cz);

            // The SDF guarantees every point within (sdf_here - clearance) of
            // this cell is navigable water, so we can jump that far in one step.
            let safe_radius = sdf_here - hard_clearance;

            let goal_dx = search.ex - cx;
            let goal_dz = search.ez - cz;

            for d in 0..8usize {
                let is_diag = DX8[d] != 0 && DZ8[d] != 0;

                let step_world = if is_diag { search.cell_size * 1.414 } else { search.cell_size };

                let sdf_max_jump = ((safe_radius / step_world) as i32).max(1);

                let mut hard_max = i32::MAX;
                if DX8[d] != 0 {
                    let max_x = if DX8[d] > 0 { search.grid_width - 1 - cx } else { cx };
                    hard_max = hard_max.min(max_x);
                    if DX8[d] * goal_dx > 0 {
                        hard_max = hard_max.min(goal_dx.abs());
                    }
                }
                if DZ8[d] != 0 {
                    let max_z = if DZ8[d] > 0 { search.grid_height - 1 - cz } else { cz };
                    hard_max = hard_max.min(max_z);
                    if DZ8[d] * goal_dz > 0 {
                        hard_max = hard_max.min(goal_dz.abs());
                    }
                }
                if hard_max <= 0 {
                    continue;
                }

                let max_jump = sdf_max_jump.min(hard_max);

                // Full jump, half jump (intermediate stepping stones), and a
                // single step for fine progress near terrain — deduplicated.
                let half_jump = max_jump / 2;
                let mut jumps = [0i32; 3];
                let mut n_jumps = 0;
                jumps[n_jumps] = max_jump;
                n_jumps += 1;
                if half_jump > 0 && half_jump != max_jump {
                    jumps[n_jumps] = half_jump;
                    n_jumps += 1;
                }
                if max_jump > 1 {
                    jumps[n_jumps] = 1;
                    n_jumps += 1;
                }

                for &jump in jumps.iter().take(n_jumps) {
                    let nx = cx + DX8[d] * jump;
                    let nz = cz + DZ8[d] * jump;

                    let nidx = nz * search.grid_width + nx;
                    let nidxu = nidx as usize;
                    if search.closed_gen[nidxu] == search.current_gen {
                        continue;
                    }

                    let landing_sdf = self.get_cell(nx, nz);
                    if landing_sdf < hard_clearance {
                        continue;
                    }

                    // Single-step diagonal: reject corner cutting.
                    if jump == 1 && is_diag {
                        if self.get_cell(cx + DX8[d], cz) < hard_clearance {
                            continue;
                        }
                        if self.get_cell(cx, cz + DZ8[d]) < hard_clearance {
                            continue;
                        }
                    }

                    let step_dist = if is_diag { jump as f32 * 1.414 } else { jump as f32 };

                    let new_g = cg + step_dist;

                    let is_better = search.open_gen[nidxu] != search.current_gen
                        || new_g < search.g_cost[nidxu];
                    if is_better {
                        search.g_cost[nidxu] = new_g;
                        search.open_gen[nidxu] = search.current_gen;
                        search.parent[nidxu] = ci;
                        search.parent_dir[nidxu] = d as i8;
                        let f = new_g + self.heuristic(nx, nz, search.ex, search.ez);
                        search.open_set.push(Reverse(PqEntry(f, nidx)));
                    }
                }
            }
        }

        if search.found || search.open_set.is_empty() || search.iterations >= search.max_iterations {
            search.complete = true;
            search.active = false;
            return true;
        }

        false
    }

    pub(crate) fn finish_path_search(&self, search: &mut PathSearch) -> PathResult {
        let mut result = PathResult::default();
        result.valid = false;
        result.total_distance = 0.0;

        if !search.found {
            godot_print!(
                "[NavigationMap] find_path: No path found after {} iterations",
                search.iterations
            );
            return result;
        }

        // Reconstruct grid path back to the start.
        let mut path: Vec<Vector2> = Vec::new();
        {
            let mut ci = search.end_idx;
            while ci != search.start_idx {
                let cx = ci % search.grid_width;
                let cz = ci / search.grid_width;
                let (wx, wz) = self.grid_to_world(cx, cz);
                path.push(Vector2::new(wx, wz));

                let pi = search.parent[ci as usize];
                if pi == ci || pi < 0 {
                    break; // safety
                }
                ci = pi;
            }
        }

        path.push(search.from);
        path.reverse();

        if path.len() >= 2 {
            let last = path.len() - 1;
            path[last] = search.to;
        }

        // Grid-level LOS simplification.
        if path.len() > 2 {
            let mut simplified: Vec<Vector2> = Vec::new();
            simplified.push(path[0]);

            let mut current = 0usize;
            while current < path.len() - 1 {
                let mut farthest = current + 1;

                let mut test = path.len() - 1;
                while test > current + 1 {
                    let (gx0, gz0) = self.world_to_grid(path[current].x, path[current].y);
                    let (gx1, gz1) = self.world_to_grid(path[test].x, path[test].y);
                    let ix0 = gx0.round() as i32;
                    let iz0 = gz0.round() as i32;
                    let ix1 = gx1.round() as i32;
                    let iz1 = gz1.round() as i32;

                    if self.line_of_sight(ix0, iz0, ix1, iz1, search.clearance_world) {
                        farthest = test;
                        break;
                    }
                    test -= 1;
                }

                simplified.push(path[farthest]);
                current = farthest;
            }
            path = simplified;
        }

        let mut total_dist = 0.0f32;
        for i in 1..path.len() {
            total_dist += path[i - 1].distance_to(path[i]);
        }

        result.flags = vec![WP_NONE; path.len()];
        result.waypoints = path;
        result.total_distance = total_dist;
        result.valid = true;
        result
    }

}
