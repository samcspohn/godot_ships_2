use std::collections::VecDeque;

use godot::prelude::*;

use super::NavigationMap;
use crate::nav::types::IslandData;

impl NavigationMap {
    pub(crate) fn compute_sdf_from_mask(&mut self, land_mask: &[bool]) {
        let grid_width = self.grid_width;
        let grid_height = self.grid_height;
        let total_cells = (grid_width * grid_height) as usize;
        self.sdf_grid.resize(total_cells, 0.0);

        // Two-pass distance transform (8SSEDT approximation): for each cell,
        // store the squared distance to the nearest boundary cell. Then take
        // the square root and apply the sign.
        let inf_dist = (grid_width + grid_height) as f32;

        // Store nearest boundary coordinates for each cell.
        let mut nearest_x = vec![-1i32; total_cells];
        let mut nearest_z = vec![-1i32; total_cells];

        // Initialize: boundary cells get distance 0, others get INF.
        let mut dist_sq = vec![inf_dist * inf_dist; total_cells];

        // Seed with boundary cells (land cells adjacent to water or vice versa).
        // A boundary cell is one where its land status differs from at least
        // one 4-neighbor.
        //
        // NOTE (C++ dead code): the source builds a `std::queue<int> bfs_queue`
        // here and pushes every boundary index into it, but the queue is never
        // popped or read anywhere afterward — the actual propagation is the two
        // forward/backward passes below, not a BFS. It has no effect on the
        // result, so it is not reproduced here.
        for iz in 0..grid_height {
            for ix in 0..grid_width {
                let idx = (iz * grid_width + ix) as usize;
                let is_land = land_mask[idx];

                let dx4 = [1, -1, 0, 0];
                let dz4 = [0, 0, 1, -1];
                let mut is_boundary = false;
                for d in 0..4 {
                    let nx = ix + dx4[d];
                    let nz = iz + dz4[d];
                    if nx >= 0 && nx < grid_width && nz >= 0 && nz < grid_height {
                        let nidx = (nz * grid_width + nx) as usize;
                        if land_mask[nidx] != is_land {
                            is_boundary = true;
                            break;
                        }
                    } else {
                        // Edge of map is a boundary (treated as water).
                        if is_land {
                            is_boundary = true;
                            break;
                        }
                    }
                }

                if is_boundary {
                    dist_sq[idx] = 0.0;
                    nearest_x[idx] = ix;
                    nearest_z[idx] = iz;
                }
            }
        }

        // Forward pass (top-left to bottom-right).
        let offsets_fwd = [(-1, -1), (0, -1), (1, -1), (-1, 0)];
        for iz in 0..grid_height {
            for ix in 0..grid_width {
                let idx = (iz * grid_width + ix) as usize;
                for &(ox, oz) in &offsets_fwd {
                    let nx = ix + ox;
                    let nz = iz + oz;
                    if nx >= 0 && nx < grid_width && nz >= 0 && nz < grid_height {
                        let nidx = (nz * grid_width + nx) as usize;
                        if nearest_x[nidx] >= 0 {
                            let ddx = (ix - nearest_x[nidx]) as f32;
                            let ddz = (iz - nearest_z[nidx]) as f32;
                            let new_dist_sq = ddx * ddx + ddz * ddz;
                            if new_dist_sq < dist_sq[idx] {
                                dist_sq[idx] = new_dist_sq;
                                nearest_x[idx] = nearest_x[nidx];
                                nearest_z[idx] = nearest_z[nidx];
                            }
                        }
                    }
                }
            }
        }

        // Backward pass (bottom-right to top-left).
        let offsets_bwd = [(1, 1), (0, 1), (-1, 1), (1, 0)];
        for iz in (0..grid_height).rev() {
            for ix in (0..grid_width).rev() {
                let idx = (iz * grid_width + ix) as usize;
                for &(ox, oz) in &offsets_bwd {
                    let nx = ix + ox;
                    let nz = iz + oz;
                    if nx >= 0 && nx < grid_width && nz >= 0 && nz < grid_height {
                        let nidx = (nz * grid_width + nx) as usize;
                        if nearest_x[nidx] >= 0 {
                            let ddx = (ix - nearest_x[nidx]) as f32;
                            let ddz = (iz - nearest_z[nidx]) as f32;
                            let new_dist_sq = ddx * ddx + ddz * ddz;
                            if new_dist_sq < dist_sq[idx] {
                                dist_sq[idx] = new_dist_sq;
                                nearest_x[idx] = nearest_x[nidx];
                                nearest_z[idx] = nearest_z[nidx];
                            }
                        }
                    }
                }
            }
        }

        // Convert squared grid distances to world-space signed distances.
        for i in 0..total_cells {
            let dist = dist_sq[i].sqrt() * self.cell_size;
            // Positive = water, Negative = land.
            self.sdf_grid[i] = if land_mask[i] { -dist } else { dist };
        }

        let min_val = self.sdf_grid.iter().cloned().fold(f32::INFINITY, f32::min);
        let max_val = self.sdf_grid.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        godot_print!(
            "[NavigationMap] SDF computed. Distance range: {} to {} meters",
            min_val,
            max_val
        );
    }

    pub(crate) fn extract_islands(&mut self, land_mask: &[bool], height_grid: &[f32]) {
        self.islands.clear();

        let grid_width = self.grid_width;
        let grid_height = self.grid_height;
        let cell_size = self.cell_size;
        let total_cells = (grid_width * grid_height) as usize;
        let mut visited = vec![-1i32; total_cells]; // -1 = unvisited, >=0 = island_id

        let mut island_id: i32 = 0;

        // Flood-fill to find connected land regions.
        for iz in 0..grid_height {
            for ix in 0..grid_width {
                let idx = (iz * grid_width + ix) as usize;
                if !land_mask[idx] || visited[idx] >= 0 {
                    continue;
                }

                // New island found — BFS flood fill.
                let mut island = IslandData::default();
                island.id = island_id;

                let mut queue: VecDeque<(i32, i32)> = VecDeque::new();
                queue.push_back((ix, iz));
                visited[idx] = island_id;

                let mut sum_x: f64 = 0.0;
                let mut sum_z: f64 = 0.0;
                let mut cell_count: i32 = 0;
                let mut island_cells: Vec<(i32, i32)> = Vec::new();

                while let Some((cx, cz)) = queue.pop_front() {
                    let (wx, wz) = self.grid_to_world(cx, cz);
                    sum_x += wx as f64;
                    sum_z += wz as f64;
                    cell_count += 1;
                    island_cells.push((cx, cz));

                    // Check 8-connected neighbors.
                    for d in 0..8 {
                        let nx = cx + super::DX8[d];
                        let nz = cz + super::DZ8[d];
                        if nx >= 0 && nx < grid_width && nz >= 0 && nz < grid_height {
                            let nidx = (nz * grid_width + nx) as usize;
                            if land_mask[nidx] && visited[nidx] < 0 {
                                visited[nidx] = island_id;
                                queue.push_back((nx, nz));
                            }
                        }
                    }
                }

                // Skip tiny islands (noise) — fewer than 4 cells at 50m = 10,000 sq meters.
                if cell_count < 4 {
                    island_id += 1;
                    continue;
                }

                island.center = Vector2::new(
                    (sum_x / cell_count as f64) as f32,
                    (sum_z / cell_count as f64) as f32,
                );
                island.area = cell_count as f32 * cell_size * cell_size;

                // Compute radius (max distance from center to any land cell) and the
                // tallest cell on the island — the latter sets how far this island's
                // terrain shadow can reach (see terrain_shadow_depth).
                let mut max_dist_sq: f32 = 0.0;
                for &(cx, cz) in &island_cells {
                    let (wx, wz) = self.grid_to_world(cx, cz);
                    let dx = wx - island.center.x;
                    let dz = wz - island.center.y; // center.y is world Z
                    let d = dx * dx + dz * dz;
                    if d > max_dist_sq {
                        max_dist_sq = d;
                    }
                    let h = height_grid[(cz * grid_width + cx) as usize];
                    if h > island.max_height {
                        island.max_height = h;
                    }
                }
                island.radius = max_dist_sq.sqrt();

                // Extract edge points (cells on the boundary between land and water).
                // Sample every few cells to keep the array manageable.
                let edge_sample_stride = 1.max(cell_count / 64);
                let mut edge_counter: i32 = 0;
                for &(cx, cz) in &island_cells {
                    // Check if this cell has a water neighbor (it's on the edge).
                    let mut on_edge = false;
                    let dx4 = [1, -1, 0, 0];
                    let dz4 = [0, 0, 1, -1];
                    for d in 0..4 {
                        let nx = cx + dx4[d];
                        let nz = cz + dz4[d];
                        if nx < 0 || nx >= grid_width || nz < 0 || nz >= grid_height {
                            on_edge = true;
                            break;
                        }
                        if !land_mask[(nz * grid_width + nx) as usize] {
                            on_edge = true;
                            break;
                        }
                    }
                    if on_edge {
                        edge_counter += 1;
                        if edge_counter % edge_sample_stride == 0 {
                            let (wx, wz) = self.grid_to_world(cx, cz);
                            island.edge_points.push(Vector2::new(wx, wz));
                        }
                    }
                }

                godot_print!(
                    "[NavigationMap]   Island {}: center=({}, {}), radius={}m, area={}m², {} edge points",
                    island_id,
                    island.center.x,
                    island.center.y,
                    island.radius,
                    island.area,
                    island.edge_points.len()
                );

                self.islands.push(island);
                island_id += 1;
            }
        }
    }

    pub(crate) fn compute_regions(&mut self) {
        let grid_width = self.grid_width;
        let grid_height = self.grid_height;
        let total_cells = (grid_width * grid_height) as usize;
        self.region_grid = vec![-1i32; total_cells];
        self.region_count = 0;

        // BFS flood-fill over all navigable (water) cells — sdf_grid > 0 means water.
        for iz in 0..grid_height {
            for ix in 0..grid_width {
                let idx = (iz * grid_width + ix) as usize;
                if self.region_grid[idx] >= 0 {
                    continue; // already assigned
                }
                if self.sdf_grid[idx] <= 0.0 {
                    continue; // land cell
                }

                // New region — BFS flood fill.
                let rid = self.region_count;
                self.region_count += 1;
                let mut q: VecDeque<i32> = VecDeque::new();
                self.region_grid[idx] = rid;
                q.push_back(idx as i32);

                while let Some(ci) = q.pop_front() {
                    let cz = ci / grid_width;
                    let cx = ci % grid_width;

                    let dx4 = [1, -1, 0, 0];
                    let dz4 = [0, 0, 1, -1];
                    for d in 0..4 {
                        let nx = cx + dx4[d];
                        let nz = cz + dz4[d];
                        if nx < 0 || nx >= grid_width || nz < 0 || nz >= grid_height {
                            continue;
                        }
                        let nidx = (nz * grid_width + nx) as usize;
                        if self.region_grid[nidx] >= 0 {
                            continue;
                        }
                        if self.sdf_grid[nidx] <= 0.0 {
                            continue;
                        }
                        self.region_grid[nidx] = rid;
                        q.push_back(nidx as i32);
                    }
                }
            }
        }

        godot_print!(
            "[NavigationMap] Computed {} navigable water regions.",
            self.region_count
        );
    }

    // Separable 1-2-1 blur, once per axis. Enough to round the per-cell coastline
    // without meaningfully lowering a ridge: a peak that spans several cells keeps
    // its height, while a single-cell step gets shoulders.
    pub(crate) fn build_shadow_height_grid(&mut self) {
        let grid_width = self.grid_width;
        let grid_height = self.grid_height;
        let total = (grid_width * grid_height) as usize;
        self.shadow_height_grid = vec![0.0f32; total];
        if self.height_grid.is_empty() {
            return;
        }
        let mut tmp = vec![0.0f32; total];
        for z in 0..grid_height {
            for x in 0..grid_width {
                let i = (z * grid_width + x) as usize;
                let l = self.height_grid[(z * grid_width + (x - 1).max(0)) as usize];
                let r = self.height_grid[(z * grid_width + (x + 1).min(grid_width - 1)) as usize];
                tmp[i] = 0.25 * l + 0.5 * self.height_grid[i] + 0.25 * r;
            }
        }
        for z in 0..grid_height {
            for x in 0..grid_width {
                let i = (z * grid_width + x) as usize;
                let u = tmp[((z - 1).max(0) * grid_width + x) as usize];
                let d = tmp[((z + 1).min(grid_height - 1) * grid_width + x) as usize];
                self.shadow_height_grid[i] = 0.25 * u + 0.5 * tmp[i] + 0.25 * d;
            }
        }
    }
}
