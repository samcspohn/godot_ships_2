use godot::prelude::*;
use godot::classes::{
    BoxShape3D, CollisionShape3D, ConcavePolygonShape3D, ConvexPolygonShape3D, CylinderShape3D,
    Node3D, PhysicsDirectSpaceState3D, PhysicsRayQueryParameters3D, SphereShape3D,
};

use super::NavigationMap;

impl NavigationMap {
    pub(crate) fn build_from_collision_shapes_impl(&mut self, island_bodies: Array<Gd<Node3D>>) {
        // Calculate grid dimensions
        self.grid_width = ((self.max_x - self.min_x) / self.cell_size).ceil() as i32 + 1;
        self.grid_height = ((self.max_z - self.min_z) / self.cell_size).ceil() as i32 + 1;

        let total_cells = self.grid_width * self.grid_height;
        let total_usize = total_cells as usize;
        godot_print!(
            "[NavigationMap] Building SDF: {}x{} ({} cells, cell_size={}m)",
            self.grid_width,
            self.grid_height,
            total_cells,
            self.cell_size
        );

        // Step 1: Create binary land mask
        // NOTE: All rasterization methods now filter by waterline Y > 0.
        // Geometry at or below the waterline (base planes, underwater collision)
        // is NOT marked as land. This prevents rectangular base meshes from
        // inflating island footprints in the SDF.
        let mut land_mask = vec![false; total_usize];
        let mut height_grid = vec![0.0f32; total_usize];

        let island_count = island_bodies.len();
        godot_print!("[NavigationMap] Processing {} island bodies...", island_count);

        for i in 0..island_count {
            let body = island_bodies.at(i);

            let body_transform = body.get_global_transform();

            // Iterate children looking for CollisionShape3D
            let child_count = body.get_child_count();
            let mut shapes_processed = 0;

            for c in 0..child_count {
                let Some(child) = body.get_child(c) else { continue; };
                let Ok(col_shape) = child.try_cast::<CollisionShape3D>() else { continue; };

                let Some(shape) = col_shape.get_shape() else { continue; };

                let shape_transform = body_transform * col_shape.get_transform();

                // Try ConcavePolygonShape3D (most common for island terrain)
                let shape = match shape.try_cast::<ConcavePolygonShape3D>() {
                    Ok(concave) => {
                        let faces = concave.get_faces();
                        let face_count = faces.len() / 3;
                        let mut above_water_tris = 0;
                        for f in 0..face_count {
                            let v0 = shape_transform * faces[f * 3];
                            let v1 = shape_transform * faces[f * 3 + 1];
                            let v2 = shape_transform * faces[f * 3 + 2];
                            // rasterize_triangle now internally filters by Y > 0
                            if v0.y.max(v1.y).max(v2.y) > 0.0 {
                                above_water_tris += 1;
                            }
                            self.rasterize_triangle(v0, v1, v2, &mut land_mask, &mut height_grid);
                        }
                        godot_print!(
                            "[NavigationMap]     ConcavePolygon: {} tris, {} above waterline",
                            face_count,
                            above_water_tris
                        );
                        shapes_processed += 1;
                        continue;
                    }
                    Err(shape) => shape,
                };

                // Try ConvexPolygonShape3D
                let shape = match shape.try_cast::<ConvexPolygonShape3D>() {
                    Ok(convex) => {
                        let points = convex.get_points();
                        // Simple approach: create triangles from a fan
                        if points.len() >= 3 {
                            // Project to XZ and create a simple triangulation
                            for p in 1..points.len() - 1 {
                                let v0 = shape_transform * points[0];
                                let v1 = shape_transform * points[p];
                                let v2 = shape_transform * points[p + 1];
                                self.rasterize_triangle(v0, v1, v2, &mut land_mask, &mut height_grid);
                            }
                        }
                        shapes_processed += 1;
                        continue;
                    }
                    Err(shape) => shape,
                };

                // Try BoxShape3D
                let shape = match shape.try_cast::<BoxShape3D>() {
                    Ok(box_shape) => {
                        let half_extents = box_shape.get_size() * 0.5;
                        self.rasterize_box(
                            Vector3::new(0.0, 0.0, 0.0),
                            half_extents,
                            shape_transform,
                            &mut land_mask,
                            &mut height_grid,
                        );
                        shapes_processed += 1;
                        continue;
                    }
                    Err(shape) => shape,
                };

                // Try SphereShape3D
                let shape = match shape.try_cast::<SphereShape3D>() {
                    Ok(sphere) => {
                        let radius = sphere.get_radius();
                        self.rasterize_sphere(
                            Vector3::new(0.0, 0.0, 0.0),
                            radius,
                            shape_transform,
                            &mut land_mask,
                            &mut height_grid,
                        );
                        shapes_processed += 1;
                        continue;
                    }
                    Err(shape) => shape,
                };

                // Try CylinderShape3D
                if let Ok(cylinder) = shape.try_cast::<CylinderShape3D>() {
                    let radius = cylinder.get_radius();
                    let height = cylinder.get_height();
                    self.rasterize_cylinder(
                        Vector3::new(0.0, 0.0, 0.0),
                        radius,
                        height,
                        shape_transform,
                        &mut land_mask,
                        &mut height_grid,
                    );
                    shapes_processed += 1;
                    continue;
                }
            }

            if shapes_processed > 0 {
                godot_print!(
                    "[NavigationMap]   Island '{}': {} shapes rasterized",
                    body.get_name(),
                    shapes_processed
                );
            }
        }

        // Count land cells
        let mut land_cells: i32 = 0;
        for i in 0..total_usize {
            if land_mask[i] {
                land_cells += 1;
            }
        }
        godot_print!(
            "[NavigationMap] Land cells: {} / {} ({}%)",
            land_cells,
            total_cells,
            (land_cells as f32 * 100.0) / total_cells as f32
        );

        // Step 2: Compute signed distance field from land mask
        self.compute_sdf_from_mask(&land_mask);

        // Step 3: Extract island metadata
        self.extract_islands(&land_mask, &height_grid);

        // Step 4: Compute connected water regions for O(1) reachability checks
        self.compute_regions();

        // Step 5: Allocate reusable A* buffers
        self.allocate_search_buffers();

        self.height_grid = height_grid;
        let mut max_terrain_height = 0.0f32;
        for h in &self.height_grid {
            max_terrain_height = max_terrain_height.max(*h);
        }
        self.max_terrain_height = max_terrain_height;
        self.build_shadow_height_grid();
        self.built = true;
        godot_print!(
            "[NavigationMap] Build complete. {} islands detected, {} navigable regions.",
            self.islands.len(),
            self.region_count
        );
    }

    pub(crate) fn build_from_raycast_scan_impl(
        &mut self,
        space_state: Option<Gd<PhysicsDirectSpaceState3D>>,
        island_bodies: Array<Gd<Node3D>>,
        collision_mask: i32,
    ) {
        let Some(mut space_state) = space_state else {
            godot_error!("[NavigationMap] build_from_raycast_scan: space_state is null");
            return;
        };

        // Calculate grid dimensions
        self.grid_width = ((self.max_x - self.min_x) / self.cell_size).ceil() as i32 + 1;
        self.grid_height = ((self.max_z - self.min_z) / self.cell_size).ceil() as i32 + 1;

        let total_cells = self.grid_width * self.grid_height;
        let total_usize = total_cells as usize;
        godot_print!(
            "[NavigationMap] Building SDF via raycast scan: {}x{} ({} cells, cell_size={}m)",
            self.grid_width,
            self.grid_height,
            total_cells,
            self.cell_size
        );

        // --- Determine ray origin height ---
        // Walk every island body's CollisionShape3D children, compute their AABBs in
        // world space, and track the maximum Y coordinate. The ray origin is placed
        // just above this so we never start inside geometry.
        let mut max_y: f32 = 100.0; // sensible default if no AABBs found

        let island_count = island_bodies.len();
        for i in 0..island_count {
            let body = island_bodies.at(i);

            let body_transform = body.get_global_transform();
            let child_count = body.get_child_count();

            for c in 0..child_count {
                let Some(child) = body.get_child(c) else { continue; };
                let Ok(col_shape) = child.try_cast::<CollisionShape3D>() else { continue; };

                let Some(shape) = col_shape.get_shape() else { continue; };

                let shape_transform = body_transform * col_shape.get_transform();

                // Try each supported shape type for its AABB height
                let shape = match shape.try_cast::<ConcavePolygonShape3D>() {
                    Ok(concave) => {
                        let faces = concave.get_faces();
                        for f in 0..faces.len() {
                            let world_v = shape_transform * faces[f];
                            if world_v.y > max_y {
                                max_y = world_v.y;
                            }
                        }
                        continue;
                    }
                    Err(shape) => shape,
                };

                let shape = match shape.try_cast::<ConvexPolygonShape3D>() {
                    Ok(convex) => {
                        let points = convex.get_points();
                        for p in 0..points.len() {
                            let world_v = shape_transform * points[p];
                            if world_v.y > max_y {
                                max_y = world_v.y;
                            }
                        }
                        continue;
                    }
                    Err(shape) => shape,
                };

                let shape = match shape.try_cast::<BoxShape3D>() {
                    Ok(box_shape) => {
                        let half = box_shape.get_size() * 0.5;
                        for corner in 0..8i32 {
                            let local = Vector3::new(
                                if (corner & 1) != 0 { half.x } else { -half.x },
                                if (corner & 2) != 0 { half.y } else { -half.y },
                                if (corner & 4) != 0 { half.z } else { -half.z },
                            );
                            let world_v = shape_transform * local;
                            if world_v.y > max_y {
                                max_y = world_v.y;
                            }
                        }
                        continue;
                    }
                    Err(shape) => shape,
                };

                let shape = match shape.try_cast::<SphereShape3D>() {
                    Ok(sphere) => {
                        let r = sphere.get_radius();
                        let top = shape_transform * Vector3::new(0.0, r, 0.0);
                        if top.y > max_y {
                            max_y = top.y;
                        }
                        continue;
                    }
                    Err(shape) => shape,
                };

                if let Ok(cylinder) = shape.try_cast::<CylinderShape3D>() {
                    let h = cylinder.get_height() * 0.5;
                    let top = shape_transform * Vector3::new(0.0, h, 0.0);
                    if top.y > max_y {
                        max_y = top.y;
                    }
                    continue;
                }
            }
        }

        // Place ray origin 10 m above the tallest geometry
        let ray_origin_y = max_y + 10.0;
        let ray_end_y: f32 = -10.0; // well below the waterline
        godot_print!(
            "[NavigationMap] Tallest island geometry Y={}, ray origin Y={}",
            max_y,
            ray_origin_y
        );

        // --- Set up the reusable ray query ---
        let mut ray_query = PhysicsRayQueryParameters3D::new_gd();
        ray_query.set_collision_mask(collision_mask as u32);
        ray_query.set_collide_with_bodies(true);
        ray_query.set_collide_with_areas(false);
        ray_query.set_hit_back_faces(false);

        // --- Cast one ray per grid cell ---
        let mut land_mask = vec![false; total_usize];
        let mut height_grid = vec![0.0f32; total_usize];
        let mut land_cells: i32 = 0;

        for iz in 0..self.grid_height {
            for ix in 0..self.grid_width {
                let (wx, wz) = self.grid_to_world(ix, iz);

                ray_query.set_from(Vector3::new(wx, ray_origin_y, wz));
                ray_query.set_to(Vector3::new(wx, ray_end_y, wz));

                let result = space_state.intersect_ray(&ray_query);

                if !result.is_empty() {
                    let hit_pos: Vector3 = result.get("position").unwrap().to();
                    // Hit point above the waterline (Y > 0) means land
                    if hit_pos.y > 0.0 {
                        let idx = (iz * self.grid_width + ix) as usize;
                        land_mask[idx] = true;
                        height_grid[idx] = height_grid[idx].max(hit_pos.y);
                        land_cells += 1;
                    }
                }
            }
        }

        godot_print!(
            "[NavigationMap] Raycast scan complete. Land cells: {} / {} ({}%)",
            land_cells,
            total_cells,
            (land_cells as f32 * 100.0) / total_cells as f32
        );

        // --- Reuse the same SDF pipeline as build_from_collision_shapes ---
        self.compute_sdf_from_mask(&land_mask);
        self.extract_islands(&land_mask, &height_grid);
        self.compute_regions();

        // Allocate reusable A* buffers
        self.allocate_search_buffers();

        self.height_grid = height_grid;
        let mut max_terrain_height = 0.0f32;
        for h in &self.height_grid {
            max_terrain_height = max_terrain_height.max(*h);
        }
        self.max_terrain_height = max_terrain_height;
        self.build_shadow_height_grid();
        self.built = true;
        godot_print!(
            "[NavigationMap] Raycast build complete. {} islands detected, {} navigable regions.",
            self.islands.len(),
            self.region_count
        );
    }

    pub(crate) fn rasterize_triangle(
        &mut self,
        v0: Vector3,
        v1: Vector3,
        v2: Vector3,
        land_mask: &mut [bool],
        height_grid: &mut [f32],
    ) {
        // Project triangle to XZ plane and rasterize onto the grid.
        // AGGRESSIVE rasterization: mark ANY cell that the triangle touches, even partially.
        // This ensures no land above water is ever treated as empty/navigable.
        // Only mark cells as land where the triangle surface is above the waterline (Y > 0).

        // Quick reject: if all three vertices are at or below the waterline, skip entirely.
        let max_y = v0.y.max(v1.y).max(v2.y);
        if max_y <= 0.0 {
            return;
        }

        // Convert to grid coordinates
        let (gx0, gz0) = self.world_to_grid(v0.x, v0.z);
        let (gx1, gz1) = self.world_to_grid(v1.x, v1.z);
        let (gx2, gz2) = self.world_to_grid(v2.x, v2.z);

        // Bounding box in grid space — use floor/ceil to cover all cells the triangle could touch
        let min_gx = ((gx0.min(gx1).min(gx2)).floor() as i32).max(0);
        let max_gx = ((gx0.max(gx1).max(gx2)).ceil() as i32).min(self.grid_width - 1);
        let min_gz = ((gz0.min(gz1).min(gz2)).floor() as i32).max(0);
        let max_gz = ((gz0.max(gz1).max(gz2)).ceil() as i32).min(self.grid_height - 1);

        // Edge function for point-in-triangle test
        let edge_func = |ax: f32, az: f32, bx: f32, bz: f32, px: f32, pz: f32| -> f32 {
            (bx - ax) * (pz - az) - (bz - az) * (px - ax)
        };

        // Check winding order
        let area_sign = edge_func(gx0, gz0, gx1, gz1, gx2, gz2);
        if area_sign.abs() < 0.0001 {
            return; // Degenerate triangle
        }

        // If the triangle is entirely above the waterline we can skip per-cell Y checks
        let all_above = v0.y > 0.0 && v1.y > 0.0 && v2.y > 0.0;

        let inv_area = 1.0 / area_sign;

        // Triangle edges as segments in grid space for segment-vs-AABB intersection
        let tri_x = [gx0, gx1, gx2];
        let tri_z = [gz0, gz1, gz2];

        // Helper: test if 1D intervals [a_min, a_max] and [b_min, b_max] overlap
        let intervals_overlap = |a_min: f32, a_max: f32, b_min: f32, b_max: f32| -> bool {
            a_min <= b_max && b_min <= a_max
        };

        // Helper: test if a line segment (p0 -> p1) intersects an AABB [box_min, box_max]
        // Using separating axis theorem on 2D AABB vs segment
        let segment_aabb_intersect = |p0x: f32,
                                       p0z: f32,
                                       p1x: f32,
                                       p1z: f32,
                                       box_min_x: f32,
                                       box_min_z: f32,
                                       box_max_x: f32,
                                       box_max_z: f32|
         -> bool {
            // First: bounding box overlap test
            let seg_min_x = p0x.min(p1x);
            let seg_max_x = p0x.max(p1x);
            let seg_min_z = p0z.min(p1z);
            let seg_max_z = p0z.max(p1z);
            if !intervals_overlap(seg_min_x, seg_max_x, box_min_x, box_max_x) {
                return false;
            }
            if !intervals_overlap(seg_min_z, seg_max_z, box_min_z, box_max_z) {
                return false;
            }

            // Separating axis from edge normal: n = (dz, -dx) where d = p1 - p0
            let dx = p1x - p0x;
            let dz = p1z - p0z;
            // Project AABB corners onto the edge normal axis
            // edge_func value at a point is: dx * (pz - p0z) - dz * (px - p0x)
            // which equals dot((dz, -dx), (px - p0x, pz - p0z)) ... actually let's just
            // compute the edge function at all 4 box corners
            let c0 = dx * (box_min_z - p0z) - dz * (box_min_x - p0x);
            let c1 = dx * (box_min_z - p0z) - dz * (box_max_x - p0x);
            let c2 = dx * (box_max_z - p0z) - dz * (box_min_x - p0x);
            let c3 = dx * (box_max_z - p0z) - dz * (box_max_x - p0x);
            let cmin = c0.min(c1).min(c2).min(c3);
            let cmax = c0.max(c1).max(c2).max(c3);
            // If all corners are on the same side of the line, the segment doesn't cross the box
            if cmin > 0.0 || cmax < 0.0 {
                return false;
            }

            true
        };

        // Helper: test if a point is inside the triangle
        let point_in_triangle = |px: f32, pz: f32| -> bool {
            let e0 = edge_func(gx0, gz0, gx1, gz1, px, pz);
            let e1 = edge_func(gx1, gz1, gx2, gz2, px, pz);
            let e2 = edge_func(gx2, gz2, gx0, gz0, px, pz);
            if area_sign > 0.0 {
                e0 >= 0.0 && e1 >= 0.0 && e2 >= 0.0
            } else {
                e0 <= 0.0 && e1 <= 0.0 && e2 <= 0.0
            }
        };

        for iz in min_gz..=max_gz {
            for ix in min_gx..=max_gx {
                // Cell AABB in grid space: [ix, iz] to [ix+1, iz+1]
                let cell_min_x = ix as f32;
                let cell_min_z = iz as f32;
                let cell_max_x = (ix + 1) as f32;
                let cell_max_z = (iz + 1) as f32;

                // Test triangle-vs-cell overlap using three checks:
                // 1) Any cell corner inside the triangle?
                // 2) Any triangle vertex inside the cell?
                // 3) Any triangle edge intersects the cell AABB?
                let mut overlaps = false;

                // Check 1: Any of the 4 cell corners inside the triangle?
                if !overlaps {
                    let corners_x = [cell_min_x, cell_max_x, cell_min_x, cell_max_x];
                    let corners_z = [cell_min_z, cell_min_z, cell_max_z, cell_max_z];
                    for c in 0..4 {
                        if point_in_triangle(corners_x[c], corners_z[c]) {
                            overlaps = true;
                            break;
                        }
                    }
                }

                // Check 2: Any triangle vertex inside the cell AABB?
                if !overlaps {
                    for t in 0..3 {
                        if tri_x[t] >= cell_min_x
                            && tri_x[t] <= cell_max_x
                            && tri_z[t] >= cell_min_z
                            && tri_z[t] <= cell_max_z
                        {
                            overlaps = true;
                            break;
                        }
                    }
                }

                // Check 3: Any triangle edge intersects the cell AABB?
                if !overlaps {
                    for e in 0..3 {
                        let e_next = (e + 1) % 3;
                        if segment_aabb_intersect(
                            tri_x[e],
                            tri_z[e],
                            tri_x[e_next],
                            tri_z[e_next],
                            cell_min_x,
                            cell_min_z,
                            cell_max_x,
                            cell_max_z,
                        ) {
                            overlaps = true;
                            break;
                        }
                    }
                }

                if overlaps {
                    if all_above {
                        let idx = (iz * self.grid_width + ix) as usize;
                        land_mask[idx] = true;
                        height_grid[idx] = height_grid[idx].max(max_y);
                    } else {
                        // Mixed triangle: interpolate Y at cell center using barycentric coords.
                        // If center is outside triangle, use nearest-point clamping to be aggressive:
                        // if ANY vertex above water, mark as land.
                        let px = ix as f32 + 0.5;
                        let pz = iz as f32 + 0.5;

                        let e0 = edge_func(gx0, gz0, gx1, gz1, px, pz);
                        let e1 = edge_func(gx1, gz1, gx2, gz2, px, pz);
                        let e2 = edge_func(gx2, gz2, gx0, gz0, px, pz);

                        let center_inside = if area_sign > 0.0 {
                            e0 >= 0.0 && e1 >= 0.0 && e2 >= 0.0
                        } else {
                            e0 <= 0.0 && e1 <= 0.0 && e2 <= 0.0
                        };

                        if center_inside {
                            // Interpolate Y at cell center
                            let w0 = e1 * inv_area;
                            let w1 = e2 * inv_area;
                            let w2 = e0 * inv_area;
                            let y_at_cell = w0 * v0.y + w1 * v1.y + w2 * v2.y;
                            if y_at_cell > 0.0 {
                                let idx = (iz * self.grid_width + ix) as usize;
                                land_mask[idx] = true;
                                height_grid[idx] = height_grid[idx].max(y_at_cell);
                            }
                        } else {
                            // Cell overlaps triangle but center is outside (edge/corner overlap).
                            // Clamp barycentric weights to [0,1] to interpolate Y at the nearest
                            // point on the triangle to the cell center. This avoids marking cells
                            // that only touch a low-Y (underwater) edge of a mixed triangle.
                            let mut w0 = e1 * inv_area;
                            let mut w1 = e2 * inv_area;
                            let mut w2 = e0 * inv_area;
                            // Clamp each weight to [0,1] and renormalize
                            w0 = w0.max(0.0);
                            w1 = w1.max(0.0);
                            w2 = w2.max(0.0);
                            let wsum = w0 + w1 + w2;
                            if wsum > 0.0 {
                                let inv_wsum = 1.0 / wsum;
                                w0 *= inv_wsum;
                                w1 *= inv_wsum;
                                w2 *= inv_wsum;
                            } else {
                                // Degenerate: fall back to equal weights
                                w0 = 1.0 / 3.0;
                                w1 = 1.0 / 3.0;
                                w2 = 1.0 / 3.0;
                            }
                            let y_at_nearest = w0 * v0.y + w1 * v1.y + w2 * v2.y;
                            if y_at_nearest > 0.0 {
                                let idx = (iz * self.grid_width + ix) as usize;
                                land_mask[idx] = true;
                                height_grid[idx] = height_grid[idx].max(y_at_nearest);
                            }
                        }
                    }
                }
            }
        }
    }

    pub(crate) fn rasterize_box(
        &mut self,
        center: Vector3,
        half_extents: Vector3,
        transform: Transform3D,
        land_mask: &mut [bool],
        height_grid: &mut [f32],
    ) {
        // Generate 8 corners of the box, transform to world, project to XZ.
        // Only mark cells as land if the box extends above the waterline (Y > 0).
        let mut corners = [Vector3::new(0.0, 0.0, 0.0); 8];
        let mut box_max_y: f32 = -1e30;
        for i in 0..8i32 {
            let local = Vector3::new(
                if (i & 1) != 0 { half_extents.x } else { -half_extents.x },
                if (i & 2) != 0 { half_extents.y } else { -half_extents.y },
                if (i & 4) != 0 { half_extents.z } else { -half_extents.z },
            );
            let world_corner = transform * (center + local);
            corners[i as usize] = world_corner;
            if world_corner.y > box_max_y {
                box_max_y = world_corner.y;
            }
        }

        // If the entire box is at or below the waterline, skip it
        if box_max_y <= 0.0 {
            return;
        }

        // Project to XZ and find bounding box
        let mut min_wx = corners[0].x;
        let mut max_wx = corners[0].x;
        let mut min_wz = corners[0].z;
        let mut max_wz = corners[0].z;
        for i in 1..8 {
            min_wx = min_wx.min(corners[i].x);
            max_wx = max_wx.max(corners[i].x);
            min_wz = min_wz.min(corners[i].z);
            max_wz = max_wz.max(corners[i].z);
        }

        // Convert to grid coordinates
        let (gx_min_f, gz_min_f) = self.world_to_grid(min_wx, min_wz);
        let (gx_max_f, gz_max_f) = self.world_to_grid(max_wx, max_wz);

        let gx_min = (gx_min_f.floor() as i32).max(0);
        let gx_max = (gx_max_f.ceil() as i32).min(self.grid_width - 1);
        let gz_min = (gz_min_f.floor() as i32).max(0);
        let gz_max = (gz_max_f.ceil() as i32).min(self.grid_height - 1);

        // For each cell in the bounding box, test if the world point is inside the OBB
        // and whether the box surface at that XZ is above the waterline.
        let inv_transform = transform.affine_inverse();

        for iz in gz_min..=gz_max {
            for ix in gx_min..=gx_max {
                let (wx, wz) = self.grid_to_world(ix, iz);

                // Transform world point back to local box space (at Y=0 waterline)
                let local = inv_transform * Vector3::new(wx, 0.0, wz);

                // Check if inside box XZ footprint
                if (local.x - center.x).abs() <= half_extents.x
                    && (local.z - center.z).abs() <= half_extents.z
                {
                    // Check if the top of the box at this column is above the waterline.
                    // The highest local Y in the box is center.y + half_extents.y.
                    // Transform that point back to world to get the world-space top Y.
                    let local_top = Vector3::new(local.x, center.y + half_extents.y, local.z);
                    let world_top = transform * local_top;
                    if world_top.y > 0.0 {
                        let idx = (iz * self.grid_width + ix) as usize;
                        land_mask[idx] = true;
                        height_grid[idx] = height_grid[idx].max(world_top.y);
                    }
                }
            }
        }
    }

    pub(crate) fn rasterize_sphere(
        &mut self,
        center: Vector3,
        radius: f32,
        transform: Transform3D,
        land_mask: &mut [bool],
        height_grid: &mut [f32],
    ) {
        let world_center = transform * center;

        // Skip if the entire sphere is below the waterline
        if world_center.y + radius <= 0.0 {
            return;
        }

        let (gx_center, gz_center) = self.world_to_grid(world_center.x, world_center.z);

        // If the sphere only partially extends above the waterline, reduce the
        // effective XZ radius to the cross-section at Y=0.
        // For a sphere centered at (cx, cy, cz) with radius r, the cross-section
        // at Y=0 has radius sqrt(r² - cy²) when |cy| < r.
        let mut effective_radius = radius;
        if world_center.y < radius {
            let dy = world_center.y; // distance from waterline to center (positive = above)
            if dy < 0.0 {
                // Center is below water — cross-section at Y=0
                effective_radius = (radius * radius - dy * dy).sqrt();
            }
            // else center is above water but bottom dips below — full XZ radius is fine
        }

        let grid_radius = effective_radius / self.cell_size;

        let gx_min = ((gx_center - grid_radius).floor() as i32).max(0);
        let gx_max = ((gx_center + grid_radius).ceil() as i32).min(self.grid_width - 1);
        let gz_min = ((gz_center - grid_radius).floor() as i32).max(0);
        let gz_max = ((gz_center + grid_radius).ceil() as i32).min(self.grid_height - 1);

        for iz in gz_min..=gz_max {
            for ix in gx_min..=gx_max {
                let dx = ix as f32 - gx_center;
                let dz = iz as f32 - gz_center;
                if dx * dx + dz * dz <= grid_radius * grid_radius {
                    let (wx_cell, wz_cell) = self.grid_to_world(ix, iz);
                    let cell_dx = wx_cell - world_center.x;
                    let cell_dz = wz_cell - world_center.z;
                    let dist_sq = cell_dx * cell_dx + cell_dz * cell_dz;
                    let top_y = world_center.y + (radius * radius - dist_sq).max(0.0).sqrt();
                    let idx = (iz * self.grid_width + ix) as usize;
                    land_mask[idx] = true;
                    height_grid[idx] = height_grid[idx].max(top_y);
                }
            }
        }
    }

    pub(crate) fn rasterize_cylinder(
        &mut self,
        center: Vector3,
        radius: f32,
        height: f32,
        transform: Transform3D,
        land_mask: &mut [bool],
        height_grid: &mut [f32],
    ) {
        // Check if the top of the cylinder is above the waterline
        let world_top = transform * (center + Vector3::new(0.0, height * 0.5, 0.0));
        if world_top.y <= 0.0 {
            return; // Entire cylinder is below water
        }

        // For navigation purposes, a cylinder projects as a circle on XZ.
        // Use the cylinder radius directly (not height-dependent like a sphere).
        let world_center = transform * center;

        let (gx_center, gz_center) = self.world_to_grid(world_center.x, world_center.z);

        let grid_radius = radius / self.cell_size;

        let gx_min = ((gx_center - grid_radius).floor() as i32).max(0);
        let gx_max = ((gx_center + grid_radius).ceil() as i32).min(self.grid_width - 1);
        let gz_min = ((gz_center - grid_radius).floor() as i32).max(0);
        let gz_max = ((gz_center + grid_radius).ceil() as i32).min(self.grid_height - 1);

        for iz in gz_min..=gz_max {
            for ix in gx_min..=gx_max {
                let dx = ix as f32 - gx_center;
                let dz = iz as f32 - gz_center;
                if dx * dx + dz * dz <= grid_radius * grid_radius {
                    let idx = (iz * self.grid_width + ix) as usize;
                    land_mask[idx] = true;
                    height_grid[idx] = height_grid[idx].max(world_top.y);
                }
            }
        }
    }
}
