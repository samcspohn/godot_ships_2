use godot::prelude::*;
use std::cell::RefCell;

use crate::nav::types::{IslandData, PathSearch};

mod build;
mod cover;
mod path;
mod sdf;
mod query;

/// Direction offsets for the 8-connected grid. `dir_from_offset` and
/// `turn_angle_lut` are both indexed in this order.
pub(crate) const DX8: [i32; 8] = [-1, 0, 1, -1, 1, -1, 0, 1];
pub(crate) const DZ8: [i32; 8] = [-1, -1, -1, 0, 0, 1, 1, 1];

#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct NavigationMap {
    base: Base<RefCounted>,

    // --- SDF grid ---
    /// Signed distance values; positive = water, negative = land.
    pub(crate) sdf_grid: Vec<f32>,
    /// Max terrain height per cell; 0.0 = water.
    pub(crate) height_grid: Vec<f32>,
    /// `height_grid` lightly blurred, and the only thing terrain shadows are
    /// cast from. The raw grid's coastline is a 50 m staircase because the land
    /// mask is per-cell, and a shadow cast from a staircase has staircase edges
    /// however smoothly it is interpolated. Blurring rounds the caster instead
    /// of the result. Kept separate: `height_grid` itself must stay sharp for
    /// the shell-arc terrain test, which a lowered ridge would let shells
    /// through.
    pub(crate) shadow_height_grid: Vec<f32>,
    /// Tallest cell in `height_grid`; bounds the shadow march.
    pub(crate) max_terrain_height: f32,
    pub(crate) grid_width: i32,
    pub(crate) grid_height: i32,
    pub(crate) cell_size: f32,
    pub(crate) min_x: f32,
    pub(crate) min_z: f32,
    pub(crate) max_x: f32,
    pub(crate) max_z: f32,
    pub(crate) built: bool,

    /// Each navigable cell gets a region ID; cells in the same connected water
    /// region share one. Non-navigable cells get -1. Enables O(1) reachability
    /// checks before pathfinding.
    pub(crate) region_grid: Vec<i32>,
    pub(crate) region_count: i32,

    pub(crate) islands: Vec<IslandData>,

    /// Pre-allocated search state for synchronous `find_path_internal` calls.
    /// The C++ declares this `mutable` so it can be driven from `const` query
    /// methods; `RefCell` is the faithful equivalent and keeps every query
    /// taking `&self`, so nested `Gd` binds stay shared.
    pub(crate) sync_search: RefCell<PathSearch>,
}

#[godot_api]
impl IRefCounted for NavigationMap {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            sdf_grid: Vec::new(),
            height_grid: Vec::new(),
            shadow_height_grid: Vec::new(),
            max_terrain_height: 0.0,
            grid_width: 0,
            grid_height: 0,
            cell_size: 50.0,
            min_x: -17500.0,
            min_z: -17500.0,
            max_x: 17500.0,
            max_z: 17500.0,
            built: false,
            region_grid: Vec::new(),
            region_count: 0,
            islands: Vec::new(),
            sync_search: RefCell::new(PathSearch::default()),
        }
    }
}

// --- Internal helpers (private in the C++ header) ---

impl NavigationMap {
    /// World coordinates to fractional grid indices.
    pub(crate) fn world_to_grid(&self, wx: f32, wz: f32) -> (f32, f32) {
        ((wx - self.min_x) / self.cell_size, (wz - self.min_z) / self.cell_size)
    }

    pub(crate) fn grid_to_world(&self, ix: i32, iz: i32) -> (f32, f32) {
        (
            self.min_x + ix as f32 * self.cell_size,
            self.min_z + iz as f32 * self.cell_size,
        )
    }

    pub(crate) fn in_bounds(&self, ix: i32, iz: i32) -> bool {
        ix >= 0 && ix < self.grid_width && iz >= 0 && iz < self.grid_height
    }

    /// Project out-of-bounds points to the nearest edge, preventing SDF
    /// gradient walks from dragging them toward map corners.
    pub(crate) fn clamp_world_to_bounds(&self, wx: &mut f32, wz: &mut f32) {
        if *wx < self.min_x {
            *wx = self.min_x;
        } else if *wx > self.max_x {
            *wx = self.max_x;
        }
        if *wz < self.min_z {
            *wz = self.min_z;
        } else if *wz > self.max_z {
            *wz = self.max_z;
        }
    }

    /// Raw SDF value at a grid cell, no interpolation. Out of bounds = wall.
    pub(crate) fn get_cell(&self, ix: i32, iz: i32) -> f32 {
        if !self.in_bounds(ix, iz) {
            return 0.0;
        }
        self.sdf_grid[(iz * self.grid_width + ix) as usize]
    }

    /// Heuristic: Euclidean distance in grid cells.
    pub(crate) fn heuristic(&self, x0: i32, z0: i32, x1: i32, z1: i32) -> f32 {
        let dx = (x1 - x0) as f32;
        let dz = (z1 - z0) as f32;
        (dx * dx + dz * dz).sqrt()
    }

    /// O(1) reachability test: are these cells in the same navigable region?
    pub(crate) fn same_region(&self, x0: i32, z0: i32, x1: i32, z1: i32) -> bool {
        if !self.in_bounds(x0, z0) || !self.in_bounds(x1, z1) {
            return false;
        }
        let r0 = self.region_grid[(z0 * self.grid_width + x0) as usize];
        let r1 = self.region_grid[(z1 * self.grid_width + x1) as usize];
        r0 >= 0 && r0 == r1
    }

    /// Allocate the reusable search state to match the current grid size.
    pub(crate) fn allocate_search_buffers(&mut self) {
        let total = self.grid_width * self.grid_height;
        self.sync_search.borrow_mut().allocate(total);
    }
}

// --- Bound API ---

#[godot_api]
impl NavigationMap {
    #[func]
    fn set_bounds(&mut self, min_x: f32, min_z: f32, max_x: f32, max_z: f32) {
        self.min_x = min_x;
        self.min_z = min_z;
        self.max_x = max_x;
        self.max_z = max_z;
    }

    #[func]
    fn set_cell_size(&mut self, size: f32) {
        if size > 0.0 {
            self.cell_size = size;
        }
    }

    #[func]
    pub(crate) fn get_grid_width(&self) -> i32 {
        self.grid_width
    }

    #[func]
    pub(crate) fn get_grid_height(&self) -> i32 {
        self.grid_height
    }

    #[func]
    pub(crate) fn get_cell_size_value(&self) -> f32 {
        self.cell_size
    }

    #[func]
    pub(crate) fn get_min_x(&self) -> f32 {
        self.min_x
    }

    #[func]
    pub(crate) fn get_min_z(&self) -> f32 {
        self.min_z
    }

    #[func]
    pub(crate) fn get_max_x(&self) -> f32 {
        self.max_x
    }

    #[func]
    pub(crate) fn get_max_z(&self) -> f32 {
        self.max_z
    }

    #[func]
    pub(crate) fn is_built(&self) -> bool {
        self.built
    }

    #[func]
    pub(crate) fn get_island_count(&self) -> i32 {
        self.islands.len() as i32
    }

    #[func]
    pub(crate) fn get_max_terrain_height(&self) -> f32 {
        self.max_terrain_height
    }

    #[func]
    fn get_sdf_data(&self) -> PackedFloat32Array {
        PackedFloat32Array::from(&self.sdf_grid[..])
    }

    #[func]
    fn get_height_data(&self) -> PackedFloat32Array {
        PackedFloat32Array::from(&self.height_grid[..])
    }

    #[func]
    fn get_shadow_height_data(&self) -> PackedFloat32Array {
        PackedFloat32Array::from(&self.shadow_height_grid[..])
    }

    #[func]
    fn get_islands(&self) -> Array<VarDictionary> {
        let mut out = Array::new();
        for island in &self.islands {
            out.push(&island.to_dictionary());
        }
        out
    }

    #[func]
    fn build_from_collision_shapes(&mut self, island_bodies: Array<Gd<godot::classes::Node3D>>) {
        self.build_from_collision_shapes_impl(island_bodies);
    }

    #[func]
    fn build_from_raycast_scan(
        &mut self,
        space_state: Option<Gd<godot::classes::PhysicsDirectSpaceState3D>>,
        island_bodies: Array<Gd<godot::classes::Node3D>>,
        #[opt(default = 1)] collision_mask: i32,
    ) {
        self.build_from_raycast_scan_impl(space_state, island_bodies, collision_mask);
    }

    #[func]
    fn get_distance(&self, x: f32, z: f32) -> f32 {
        self.get_distance_impl(x, z)
    }

    #[func]
    fn get_gradient(&self, x: f32, z: f32) -> Vector2 {
        self.get_gradient_impl(x, z)
    }

    #[func]
    fn is_navigable(&self, x: f32, z: f32, clearance: f32) -> bool {
        self.is_navigable_impl(x, z, clearance)
    }

    #[func]
    fn is_reachable(&self, a: Vector2, b: Vector2, clearance: f32) -> bool {
        self.is_reachable_impl(a, b, clearance)
    }

    #[func]
    fn raycast(&self, from: Vector2, to: Vector2, clearance: f32) -> VarDictionary {
        let r = self.raycast_internal(from, to, clearance);
        let mut dict = VarDictionary::new();
        dict.set("hit", r.hit);
        dict.set("position", r.position);
        dict.set("distance", r.distance);
        dict.set("penetration", r.penetration);
        dict
    }

    #[func]
    fn get_terrain_height(&self, x: f32, z: f32) -> f32 {
        self.get_terrain_height_impl(x, z)
    }

    #[func]
    fn terrain_shadow_depth(&self, point: Vector2, origin: Vector2, slope: f32) -> f32 {
        self.terrain_shadow_depth_impl(point, origin, slope)
    }

    #[func]
    fn is_terrain_shadowed(&self, point: Vector2, origin: Vector2, slope: f32) -> bool {
        self.is_terrain_shadowed_impl(point, origin, slope)
    }

    #[func]
    fn get_nearest_island(&self, position: Vector2) -> VarDictionary {
        self.get_nearest_island_impl(position)
    }

    #[func]
    fn compute_cover_zone(
        &self,
        island_id: i32,
        threat_direction: Vector2,
        ship_clearance: f32,
        turning_radius: f32,
        // Part of the bound API (navigation_map_manager.gd passes it) but the
        // C++ never reads it, so it stops here.
        _max_engagement_range: f32,
    ) -> VarDictionary {
        self.compute_cover_zone_internal(island_id, threat_direction, ship_clearance, turning_radius)
            .to_dictionary()
    }

    #[func]
    fn find_cover_candidates(
        &self,
        island_id: i32,
        threat_positions: PackedVector2Array,
        danger_center: Vector2,
        ship_position: Vector2,
        ship_clearance: f32,
        gun_range: f32,
        #[opt(default = 20)] max_results: i32,
        #[opt(default = 200)] max_candidates: i32,
    ) -> Array<VarDictionary> {
        self.find_cover_candidates_impl(
            island_id,
            threat_positions,
            danger_center,
            ship_position,
            ship_clearance,
            gun_range,
            max_results,
            max_candidates,
        )
    }

    #[func]
    fn safe_nav_point(
        &self,
        ship_position: Vector2,
        candidate: Vector2,
        clearance: f32,
        turning_radius: f32,
    ) -> VarDictionary {
        let original = candidate;
        let position = self.safe_nav_point_internal(ship_position, candidate, clearance, turning_radius);
        let mut dict = VarDictionary::new();
        dict.set("position", position);
        dict.set("adjusted", position != original);
        dict
    }

    #[func]
    fn validate_destination(
        &self,
        ship_position: Vector2,
        destination: Vector2,
        clearance: f32,
        turning_radius: f32,
    ) -> VarDictionary {
        let original = destination;
        let position = self.validate_destination_internal(ship_position, destination, clearance, turning_radius);
        let mut dict = VarDictionary::new();
        dict.set("position", position);
        dict.set("adjusted", position != original);
        dict
    }

    #[func]
    fn find_path(
        &self,
        from: Vector2,
        to: Vector2,
        clearance: f32,
        #[opt(default = 0.0)] turning_radius: f32,
    ) -> PackedVector2Array {
        let result = self.find_path_internal(from, to, clearance, turning_radius);
        let mut out = PackedVector2Array::new();
        for wp in &result.waypoints {
            out.push(*wp);
        }
        out
    }
}
