use godot::prelude::*;

use super::NavigationMap;
use crate::nav::types::RayResult;

impl NavigationMap {
    pub(crate) fn sample_bilinear(&self, gx: f32, gz: f32) -> f32 {
        // Clamp to valid range
        let gx = 0.0f32.max(gx.min(self.grid_width as f32 - 1.0));
        let gz = 0.0f32.max(gz.min(self.grid_height as f32 - 1.0));

        let x0 = gx.floor() as i32;
        let z0 = gz.floor() as i32;
        let x1 = (x0 + 1).min(self.grid_width - 1);
        let z1 = (z0 + 1).min(self.grid_height - 1);

        let fx = gx - x0 as f32;
        let fz = gz - z0 as f32;

        let v00 = self.get_cell(x0, z0);
        let v10 = self.get_cell(x1, z0);
        let v01 = self.get_cell(x0, z1);
        let v11 = self.get_cell(x1, z1);

        let v0 = v00 * (1.0 - fx) + v10 * fx;
        let v1 = v01 * (1.0 - fx) + v11 * fx;

        v0 * (1.0 - fz) + v1 * fz
    }

    pub(crate) fn sample_grid_bilinear(&self, grid: &[f32], gx: f32, gz: f32) -> f32 {
        let gx = 0.0f32.max(gx.min(self.grid_width as f32 - 1.0));
        let gz = 0.0f32.max(gz.min(self.grid_height as f32 - 1.0));

        let x0 = gx.floor() as i32;
        let z0 = gz.floor() as i32;
        let x1 = (x0 + 1).min(self.grid_width - 1);
        let z1 = (z0 + 1).min(self.grid_height - 1);

        let fx = gx - x0 as f32;
        let fz = gz - z0 as f32;

        let v00 = grid[(z0 * self.grid_width + x0) as usize];
        let v10 = grid[(z0 * self.grid_width + x1) as usize];
        let v01 = grid[(z1 * self.grid_width + x0) as usize];
        let v11 = grid[(z1 * self.grid_width + x1) as usize];

        let v0 = v00 * (1.0 - fx) + v10 * fx;
        let v1 = v01 * (1.0 - fx) + v11 * fx;

        v0 * (1.0 - fz) + v1 * fz
    }

    pub(crate) fn sample_height_bilinear(&self, gx: f32, gz: f32) -> f32 {
        self.sample_grid_bilinear(&self.height_grid, gx, gz)
    }

    // Height with the cell-to-cell blend eased instead of straight. Plain bilinear
    // is only C0: its gradient jumps at every cell boundary, and a level set of it -
    // which is exactly what the edge of a terrain shadow is - comes out kinked on a
    // 50 m lattice. Easing the blend makes the field C1 and the edge smooth. The
    // overlay shader samples the same way, so the zone it draws and the drop the
    // authority refuses share an edge.
    pub(crate) fn sample_height_smooth(&self, x: f32, z: f32) -> f32 {
        if !self.built || self.shadow_height_grid.is_empty() {
            return 0.0;
        }
        let (gx, gz) = self.world_to_grid(x, z);
        if gx < 0.0
            || gx >= self.grid_width as f32
            || gz < 0.0
            || gz >= self.grid_height as f32
        {
            return 0.0;
        }
        let ix = gx.floor();
        let iz = gz.floor();
        let mut fx = gx - ix;
        let mut fz = gz - iz;
        fx = fx * fx * (3.0 - 2.0 * fx);
        fz = fz * fz * (3.0 - 2.0 * fz);
        self.sample_grid_bilinear(&self.shadow_height_grid, ix + fx, iz + fz)
    }

    pub(crate) fn get_distance_impl(&self, x: f32, z: f32) -> f32 {
        if !self.built {
            return 10000.0; // Unbounded water if not built
        }

        let (gx, gz) = self.world_to_grid(x, z);

        // Cells outside the map boundary are treated as walls
        if gx < 0.0
            || gx >= self.grid_width as f32
            || gz < 0.0
            || gz >= self.grid_height as f32
        {
            // Distance to nearest boundary, as a negative value (wall)
            let mut dx = 0.0f32;
            let mut dz_val = 0.0f32;
            if gx < 0.0 {
                dx = -gx * self.cell_size;
            } else if gx >= self.grid_width as f32 {
                dx = (gx - self.grid_width as f32 + 1.0) * self.cell_size;
            }
            if gz < 0.0 {
                dz_val = -gz * self.cell_size;
            } else if gz >= self.grid_height as f32 {
                dz_val = (gz - self.grid_height as f32 + 1.0) * self.cell_size;
            }
            return -(dx * dx + dz_val * dz_val).sqrt();
        }

        self.sample_bilinear(gx, gz)
    }

    pub(crate) fn get_gradient_impl(&self, x: f32, z: f32) -> Vector2 {
        if !self.built {
            return Vector2::new(0.0, 0.0);
        }

        // Central differences for gradient
        let h = self.cell_size * 0.5;
        let dx = self.get_distance_impl(x + h, z) - self.get_distance_impl(x - h, z);
        let dz = self.get_distance_impl(x, z + h) - self.get_distance_impl(x, z - h);

        let mut grad = Vector2::new(dx, dz);
        let len = grad.length();
        if len > 0.0001 {
            grad /= len;
        }
        grad
    }

    pub(crate) fn is_navigable_impl(&self, x: f32, z: f32, clearance: f32) -> bool {
        self.get_distance_impl(x, z) >= clearance
    }

    /// Walk the SDF gradient from (ix, iz) to the nearest cell with at least
    /// `clearance` of open water, writing the result back. Returns false when no
    /// such cell is reachable (land-locked / flat SDF).
    pub(crate) fn find_nearest_navigable(&self, ix: &mut i32, iz: &mut i32, clearance: f32) -> bool {
        if self.in_bounds(*ix, *iz) && self.get_cell(*ix, *iz) >= clearance {
            return true; // Already navigable
        }

        // Compute SDF gradient at a point using a wider 5x5 weighted kernel for accuracy.
        // Weights approximate a Gaussian-weighted Sobel to reduce noise.
        // Returns gradient in grid-cell units pointing toward increasing SDF (open water).
        let compute_gradient = |cx: i32, cz: i32| -> (f32, f32) {
            let mut gx = 0.0f32;
            let mut gz = 0.0f32;
            let mut weight_sum_x = 0.0f32;
            let mut weight_sum_z = 0.0f32;
            let center_sdf = if self.in_bounds(cx, cz) { self.get_cell(cx, cz) } else { 0.0 };

            // 5x5 Gaussian-weighted finite differences (sigma ~1.5)
            // For each neighbor, compute (sdf_neighbor - sdf_center) / distance,
            // then project onto x and z axes, weighted by a Gaussian kernel.
            for dx in -2..=2i32 {
                for dz in -2..=2i32 {
                    if dx == 0 && dz == 0 {
                        continue;
                    }
                    let nx = cx + dx;
                    let nz = cz + dz;
                    if !self.in_bounds(nx, nz) {
                        continue;
                    }

                    let dist_sq = (dx * dx + dz * dz) as f32;
                    let dist = dist_sq.sqrt();
                    let w = (-dist_sq / 4.5).exp(); // Gaussian sigma^2 = 2.25

                    // Finite difference: rate of change from center to neighbor
                    let diff = (self.get_cell(nx, nz) - center_sdf) / dist;

                    // Project onto axes using unit direction components
                    let ux = dx as f32 / dist;
                    let uz = dz as f32 / dist;
                    gx += w * diff * ux;
                    gz += w * diff * uz;
                    weight_sum_x += w * ux * ux; // Accumulate directional weights
                    weight_sum_z += w * uz * uz;
                }
            }

            // Normalize by directional weight sums to get unbiased gradient components
            if weight_sum_x > 0.0 {
                gx /= weight_sum_x;
            }
            if weight_sum_z > 0.0 {
                gz /= weight_sum_z;
            }

            (gx, gz)
        };

        // Jump along the SDF gradient by the deficit distance to reach clearance.
        // The SDF value tells us how far we are from the boundary; clearance - sdf
        // tells us how much further we need to go into open water.
        let mut cx = *ix;
        let mut cz = *iz;
        const MAX_ITERATIONS: i32 = 16; // Safety cap on iterations

        for _step in 0..MAX_ITERATIONS {
            let cur_sdf = if self.in_bounds(cx, cz) { self.get_cell(cx, cz) } else { -1000.0 };

            if cur_sdf >= clearance {
                *ix = cx;
                *iz = cz;
                return true;
            }

            // Compute gradient pointing toward increasing SDF
            let (gx, gz) = compute_gradient(cx, cz);

            let grad_len = (gx * gx + gz * gz).sqrt();
            if grad_len < 1e-6 {
                break; // No gradient — stuck in flat region
            }

            // Normalize gradient direction
            let dir_x = gx / grad_len;
            let dir_z = gz / grad_len;

            // Jump distance: how far along the gradient we need to go.
            // deficit = clearance - cur_sdf is the distance (in world units / cell_size)
            // we need to cover. Since SDF gradient magnitude is ~1 for a proper distance
            // field, jumping by deficit in grid cells should land us near the target.
            let deficit = clearance - cur_sdf;
            let jump_dist = (1.0f32).max(deficit / grad_len); // At least 1 cell step

            let mut new_cx = cx + (dir_x * jump_dist).round() as i32;
            let mut new_cz = cz + (dir_z * jump_dist).round() as i32;

            // Clamp to grid bounds
            new_cx = new_cx.min(self.grid_width - 1).max(0);
            new_cz = new_cz.min(self.grid_height - 1).max(0);

            // No progress — can't move further
            if new_cx == cx && new_cz == cz {
                break;
            }

            cx = new_cx;
            cz = new_cz;
        }

        // Final check in case the last jump landed on a navigable cell
        if self.in_bounds(cx, cz) && self.get_cell(cx, cz) >= clearance {
            *ix = cx;
            *iz = cz;
            return true;
        }

        false
    }

    pub(crate) fn is_reachable_impl(&self, a: Vector2, b: Vector2, clearance: f32) -> bool {
        if !self.built {
            return false;
        }

        let mut ax = a.x;
        let mut az = a.y;
        let mut bx = b.x;
        let mut bz = b.y;
        self.clamp_world_to_bounds(&mut ax, &mut az);
        self.clamp_world_to_bounds(&mut bx, &mut bz);

        let (gax, gaz) = self.world_to_grid(ax, az);
        let (gbx, gbz) = self.world_to_grid(bx, bz);

        let mut aix = gax.round() as i32;
        aix = aix.min(self.grid_width - 1).max(0);
        let mut aiz = gaz.round() as i32;
        aiz = aiz.min(self.grid_height - 1).max(0);
        let mut bix = gbx.round() as i32;
        bix = bix.min(self.grid_width - 1).max(0);
        let mut biz = gbz.round() as i32;
        biz = biz.min(self.grid_height - 1).max(0);

        if !self.find_nearest_navigable(&mut aix, &mut aiz, clearance) {
            return false;
        }
        if !self.find_nearest_navigable(&mut bix, &mut biz, clearance) {
            return false;
        }

        self.same_region(aix, aiz, bix, biz)
    }

    pub(crate) fn raycast_internal(
        &self,
        from: Vector2,
        to: Vector2,
        clearance: f32,
    ) -> RayResult {
        let mut result = RayResult::default();

        if !self.built {
            return result;
        }

        let dir = to - from;
        let total_dist = dir.length();
        if total_dist < 0.001 {
            // From == To, just check navigability at that point
            let d = self.get_distance_impl(from.x, from.y);
            if d < clearance {
                result.hit = true;
                result.position = from;
                result.distance = 0.0;
                result.penetration = clearance - d;
            }
            return result;
        }

        // Sphere tracing: at each position, the SDF value is the distance to the
        // nearest obstacle, so we can jump by (sdf - clearance) along the ray
        // each step, skipping empty space cheaply.
        let dir_norm = dir / total_dist;
        let mut t = 0.0f32;

        while t <= total_dist {
            let pos = from + dir_norm * t;
            let d = self.get_distance_impl(pos.x, pos.y);

            if d < clearance {
                result.hit = true;
                result.position = pos;
                result.distance = t;
                result.penetration = clearance - d;
                return result;
            }

            // Jump by the safe radius; clamp to at least a small epsilon to
            // guarantee forward progress when d is nearly equal to clearance.
            let mut jump = d - clearance;
            if jump < 0.1 {
                jump = 0.1;
            }
            t += jump;
        }

        result
    }

    /// Bresenham supercover LOS on the SDF grid, in grid coordinates.
    pub(crate) fn line_of_sight(&self, x0: i32, z0: i32, x1: i32, z1: i32, clearance: f32) -> bool {
        // Supercover Bresenham — visits every cell the line touches, no gaps.
        // clearance is in the same units as the SDF grid values (world meters).
        let dx = (x1 - x0).abs();
        let dz = (z1 - z0).abs();
        let sx: i32 = if x0 < x1 { 1 } else { -1 };
        let sz: i32 = if z0 < z1 { 1 } else { -1 };

        let mut cx = x0;
        let mut cz = z0;

        // Check start cell
        if !self.in_bounds(cx, cz) || self.get_cell(cx, cz) < clearance {
            return false;
        }

        if dx == 0 && dz == 0 {
            return true;
        }

        let mut err = dx - dz;

        while !(cx == x1 && cz == z1) {
            let e2 = 2 * err;

            // Supercover: use >= and <= to catch exact corner crossings.
            // When the line passes exactly through a grid vertex, both step
            // conditions fire and we visit the diagonal plus both cardinal
            // neighbors — eliminating false negatives from missed cells.
            let step_x = (e2 > -dz) || (e2 == -dz && dx > 0);
            let step_z = (e2 < dx) || (e2 == dx && dz > 0);

            if step_x && step_z {
                // Diagonal step — check both cardinal neighbors for supercover,
                // then move diagonally
                if !self.in_bounds(cx + sx, cz) || self.get_cell(cx + sx, cz) < clearance {
                    return false;
                }
                if !self.in_bounds(cx, cz + sz) || self.get_cell(cx, cz + sz) < clearance {
                    return false;
                }
                err -= dz;
                err += dx;
                cx += sx;
                cz += sz;
            } else if step_x {
                // Horizontal step
                err -= dz;
                cx += sx;
            } else {
                // Vertical step
                err += dx;
                cz += sz;
            }

            if !self.in_bounds(cx, cz) || self.get_cell(cx, cz) < clearance {
                return false;
            }
        }

        true
    }

    pub(crate) fn get_terrain_height_impl(&self, x: f32, z: f32) -> f32 {
        if !self.built || self.height_grid.is_empty() {
            return 0.0;
        }

        let (gx, gz) = self.world_to_grid(x, z);

        if gx < 0.0
            || gx >= self.grid_width as f32
            || gz < 0.0
            || gz >= self.grid_height as f32
        {
            return 0.0;
        }

        self.sample_height_bilinear(gx, gz)
    }

    pub(crate) fn terrain_shadow_depth_impl(&self, point: Vector2, origin: Vector2, slope: f32) -> f32 {
        if !self.built || self.height_grid.is_empty() || slope <= 0.0 || self.max_terrain_height <= 0.0 {
            return 0.0;
        }

        let to_origin = origin - point;
        let span = to_origin.length();
        if span < 0.001 {
            return 0.0;
        }
        let dir = to_origin / span;

        // Past this the ray is already above the tallest thing on the map.
        let limit = span.min(self.max_terrain_height / slope);
        // Half a cell, so a ridge one cell wide cannot be stepped over.
        let step = self.cell_size * 0.5;

        // The ray leaves the ground under the drop point, not sea level. The grid
        // marks every cell a triangle touches and bilinear sampling bleeds that
        // height a further cell into the water, so a point sitting just off a shore
        // samples the island's own height AT ITSELF - which read as blocked even on
        // the near side, where the island is behind the point and shields nothing.
        // Subtracting it makes the first sample zero by construction, so only
        // terrain rising above the drop point's own ground can break the run-in.
        let base = self.sample_height_smooth(point.x, point.y);

        let mut depth = 0.0f32;
        let mut s = 0.0f32;
        while s <= limit {
            let p = point + dir * s;
            let h = self.sample_height_smooth(p.x, p.y);
            if h > 0.0 {
                let d = h - base - s * slope;
                if d > depth {
                    depth = d;
                }
            }
            s += step;
        }
        depth
    }

    pub(crate) fn is_terrain_shadowed_impl(&self, point: Vector2, origin: Vector2, slope: f32) -> bool {
        self.terrain_shadow_depth_impl(point, origin, slope) > 0.0
    }
}
