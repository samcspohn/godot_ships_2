use godot::prelude::*;
use godot::classes::{Camera3D, Node, PhysicsRayQueryParameters3D, Resource, INode};
use std::collections::BTreeMap;

use crate::nav::map::NavigationMap;
use crate::projectile::armor::RaycastCache;
use crate::projectile::data::ProjectileData;

mod fire;
mod lifecycle;
mod util;

/// Matches GDScript HitResult.
pub mod hit_result {
    pub const PENETRATION: i32 = 0;
    pub const RICOCHET: i32 = 1;
    pub const OVERPENETRATION: i32 = 2;
    pub const SHATTER: i32 = 3;
    pub const NOHIT: i32 = 4;
    pub const CITADEL: i32 = 5;
    pub const WATER: i32 = 6;
}

pub const SHELL_GRID_CELL: f32 = 500.0;
pub const SHELL_GRID_MIN: f32 = -17500.0;
pub const SHELL_GRID_MAX: f32 = 17500.0;
pub const SHELL_GRID_DIM: i32 = 70;

/// Predicted impact record, used for bot shell dodging.
#[derive(Clone, Copy, Debug, Default)]
pub struct ShellLandingEntry {
    pub shell_id: i32,
    pub landing_x: f32,
    pub landing_z: f32,
    /// Total flight time in shell-time units.
    pub time_to_impact: f32,
    /// current_time when the shell was fired.
    pub fire_time: f32,
    pub caliber: f32,
    /// Firing team, -1 if unknown.
    pub team_id: i32,
    pub landing_vx: f32,
    pub landing_vz: f32,
    /// Half-length of the danger line (steeper = shorter).
    pub threat_half_len: f32,
}

#[derive(Default)]
pub struct ArmorRayCacheEntry {
    pub rays: RaycastCache,
    pub last_used_frame: u64,
}

#[derive(GodotClass)]
#[class(base = Node, rename = _ProjectileManager)]
pub struct ProjectileManager {
    base: Base<Node>,

    #[var(get = get_shell_time_multiplier, set = set_shell_time_multiplier)]
    pub(crate) shell_time_multiplier: f64,
    pub(crate) current_time: f64,
    pub(crate) client_time: f64,

    #[var(get = get_next_id, set = set_next_id)]
    pub(crate) next_id: i32,
    /// VarArray, not Array<Gd<ProjectileData>>: the C++ uses null Refs as empty
    /// slots (see the `!p.is_valid()` skip in _physics_process) and gdext's
    /// typed array cannot hold nil. This also matches the C++
    /// ADD_PROPERTY(Variant::ARRAY, "projectiles") declaration.
    #[var(get = get_projectiles, set = set_projectiles)]
    pub(crate) projectiles: VarArray,
    #[var(get = get_ids_reuse, set = set_ids_reuse)]
    pub(crate) ids_reuse: VarArray,
    #[var(get = get_shell_param_ids, set = set_shell_param_ids)]
    pub(crate) shell_param_ids: VarDictionary,
    #[var(get = get_bullet_id, set = set_bullet_id)]
    pub(crate) bullet_id: i32,
    /// Monotonically-increasing unique shell identifier.
    pub(crate) next_shell_uid: u32,

    #[var(get = get_gpu_renderer, set = set_gpu_renderer)]
    pub(crate) gpu_renderer: Option<Gd<Node>>,

    pub(crate) ray_query: Option<Gd<PhysicsRayQueryParameters3D>>,
    pub(crate) mesh_ray_query: Option<Gd<PhysicsRayQueryParameters3D>>,

    #[var(get = get_compute_particle_system, set = set_compute_particle_system)]
    pub(crate) compute_particle_system: Option<Gd<Node>>,
    #[var(get = get_trail_template, set = set_trail_template)]
    pub(crate) trail_template: Option<Gd<Resource>>,
    #[var(get = get_camera, set = set_camera)]
    pub(crate) camera: Option<Gd<Camera3D>>,

    // Cached autoload references. `Option<Gd<Node>>` rather than the C++ raw
    // `Node*`, so a freed autoload is a checked failure instead of a dangling
    // dereference in _physics_process.
    pub(crate) armor_interaction: Option<Gd<Node>>,
    pub(crate) armor_sim_logger: Option<Gd<Node>>,
    pub(crate) precision_physics_world: Option<Gd<Node>>,
    pub(crate) navigation_map_manager: Option<Gd<Node>>,
    pub(crate) navigation_map: Option<Gd<NavigationMap>>,
    pub(crate) tcp_thread_pool: Option<Gd<Node>>,
    pub(crate) sound_effect_manager: Option<Gd<Node>>,

    /// Shell landing spatial grid, for bot shell dodging.
    pub(crate) shell_grid: Vec<Vec<i32>>,
    /// BTreeMap, not HashMap: get_shells_near_position iterates this and Rust's
    /// HashMap randomises order per process.
    pub(crate) shell_landings: BTreeMap<i32, ShellLandingEntry>,
    pub(crate) armor_ray_cache: BTreeMap<u64, ArmorRayCacheEntry>,
}

#[godot_api]
impl INode for ProjectileManager {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            shell_time_multiplier: 1.0,
            current_time: 0.0,
            client_time: 0.0,
            next_id: 0,
            projectiles: VarArray::new(),
            ids_reuse: VarArray::new(),
            shell_param_ids: VarDictionary::new(),
            bullet_id: 0,
            next_shell_uid: 0,
            gpu_renderer: None,
            ray_query: None,
            mesh_ray_query: None,
            compute_particle_system: None,
            trail_template: None,
            camera: None,
            armor_interaction: None,
            armor_sim_logger: None,
            precision_physics_world: None,
            navigation_map_manager: None,
            navigation_map: None,
            tcp_thread_pool: None,
            sound_effect_manager: None,
            shell_grid: Vec::new(),
            shell_landings: BTreeMap::new(),
            armor_ray_cache: BTreeMap::new(),
        }
    }

    fn ready(&mut self) {
        self.ready_impl();
    }

    fn process(&mut self, delta: f64) {
        self.process_impl(delta);
    }

    fn physics_process(&mut self, delta: f64) {
        self.physics_process_impl(delta);
    }
}

// The C++ additionally binds _init_compute_trails and _find_particle_system
// (neither has any caller — _find_particle_system is only reachable from
// _init_compute_trails, which is itself never invoked) and next_pow_of_2 (whose
// binding is unused, though the function is live internally).
#[godot_api]
impl ProjectileManager {
    #[func] pub(crate) fn get_shell_time_multiplier(&self) -> f64 { self.shell_time_multiplier }
    #[func] pub(crate) fn set_shell_time_multiplier(&mut self, value: f64) { self.set_shell_time_multiplier_impl(value); }
    #[func] pub(crate) fn get_current_time(&self) -> f64 { self.current_time }
    #[func] pub(crate) fn get_next_id(&self) -> i32 { self.next_id }
    #[func] pub(crate) fn set_next_id(&mut self, value: i32) { self.next_id = value; }
    #[func] pub(crate) fn get_projectiles(&self) -> VarArray { self.projectiles.clone() }
    #[func] pub(crate) fn set_projectiles(&mut self, value: VarArray) { self.projectiles = value; }
    #[func] pub(crate) fn get_ids_reuse(&self) -> VarArray { self.ids_reuse.clone() }
    #[func] pub(crate) fn set_ids_reuse(&mut self, value: VarArray) { self.ids_reuse = value; }
    #[func] pub(crate) fn get_shell_param_ids(&self) -> VarDictionary { self.shell_param_ids.clone() }
    #[func] pub(crate) fn set_shell_param_ids(&mut self, value: VarDictionary) { self.shell_param_ids = value; }
    #[func] pub(crate) fn get_bullet_id(&self) -> i32 { self.bullet_id }
    #[func] pub(crate) fn set_bullet_id(&mut self, value: i32) { self.bullet_id = value; }
    #[func] pub(crate) fn get_last_shell_uid(&self) -> u32 { self.next_shell_uid }
    #[func] pub(crate) fn get_gpu_renderer(&self) -> Option<Gd<Node>> { self.gpu_renderer.clone() }
    #[func] pub(crate) fn set_gpu_renderer(&mut self, value: Option<Gd<Node>>) { self.gpu_renderer = value; }
    #[func] pub(crate) fn get_compute_particle_system(&self) -> Option<Gd<Node>> { self.compute_particle_system.clone() }
    #[func] pub(crate) fn set_compute_particle_system(&mut self, value: Option<Gd<Node>>) { self.compute_particle_system = value; }
    #[func] pub(crate) fn get_trail_template(&self) -> Option<Gd<Resource>> { self.trail_template.clone() }
    #[func] pub(crate) fn set_trail_template(&mut self, value: Option<Gd<Resource>>) { self.trail_template = value; }
    #[func] pub(crate) fn get_camera(&self) -> Option<Gd<Camera3D>> { self.camera.clone() }
    #[func] pub(crate) fn set_camera(&mut self, value: Option<Gd<Camera3D>>) { self.camera = value; }

    #[func] pub(crate) fn calculate_penetration_power(&self, shell_params: Gd<Resource>, velocity: f64) -> f64 {
        self.calculate_penetration_power_impl(&shell_params, velocity)
    }
    #[func] pub(crate) fn calculate_impact_angle(&self, velocity: Vector3, surface_normal: Vector3) -> f64 {
        self.calculate_impact_angle_impl(velocity, surface_normal)
    }
    #[func] pub(crate) fn find_ship(&self, node: Gd<Node>) -> Option<Gd<Object>> { self.find_ship_impl(node) }
    #[func(rename = findShip)]
    pub(crate) fn find_ship_camel(&self, node: Gd<Node>) -> Option<Gd<Object>> { self.find_ship_impl(node) }

    #[func] pub(crate) fn clear_all(&mut self) { self.clear_all_impl(); }
    #[func] pub(crate) fn sync_time(&mut self, server_time: f64) { self.sync_time_impl(server_time); }
    #[func] pub(crate) fn profiled_process(&mut self, delta: f64) { self.process_impl(delta); }
    #[func] pub(crate) fn profiled_physics_process(&mut self, delta: f64) { self.physics_process_impl(delta); }
    #[func] pub(crate) fn _process_trails_only(&mut self, current_time: f64) { self.process_trails_only_impl(current_time); }

    // Every GDScript caller passes all arguments, so the C++ DEFVALs on
    // fire_bullet/fire_bullet_client are not needed on the bindings.
    #[func] pub(crate) fn fire_bullet(&mut self, vel: Vector3, pos: Vector3, shell: Gd<Resource>, t: f64,
                           owner: Gd<Object>, exclude: VarArray) -> i32 {
        self.fire_bullet_impl(vel, pos, &shell, t, owner, exclude)
    }
    #[func(rename = fireBullet)]
    pub(crate) fn fire_bullet_camel(&mut self, vel: Vector3, pos: Vector3, shell: Gd<Resource>, t: f64,
                         owner: Gd<Object>, exclude: VarArray) -> i32 {
        self.fire_bullet_impl(vel, pos, &shell, t, owner, exclude)
    }
    #[func] pub(crate) fn fire_bullet_client(&mut self, pos: Vector3, vel: Vector3, t: f64, id: i32,
                                  shell: Gd<Resource>, owner: Gd<Object>,
                                  muzzle_blast: bool, basis: Basis) {
        self.fire_bullet_client_impl(pos, vel, t, id, &shell, owner, muzzle_blast, basis);
    }
    #[func(rename = fireBulletClient)]
    pub(crate) fn fire_bullet_client_camel(&mut self, pos: Vector3, vel: Vector3, t: f64, id: i32,
                                shell: Gd<Resource>, owner: Gd<Object>,
                                muzzle_blast: bool, basis: Basis) {
        self.fire_bullet_client_impl(pos, vel, t, id, &shell, owner, muzzle_blast, basis);
    }
    #[func(rename = destroyBulletRpc)]
    pub(crate) fn destroy_bullet_rpc_camel(&mut self, id: i32, position: Vector3, hit_result: i32, normal: Vector3) {
        self.destroy_bullet_rpc_impl(id, position, hit_result, normal);
    }
    #[func(rename = destroyBulletRpc2)]
    pub(crate) fn destroy_bullet_rpc2_camel(&mut self, id: i32, pos: Vector3, hit_result: i32, normal: Vector3) {
        self.destroy_bullet_rpc2_impl(id, pos, hit_result, normal);
    }
    #[func(rename = destroyBulletRpc3)]
    pub(crate) fn destroy_bullet_rpc3_camel(&mut self, data: PackedByteArray) {
        self.destroy_bullet_rpc3_impl(data);
    }
    #[func(rename = createRicochetRpc)]
    pub(crate) fn create_ricochet_rpc_camel(&mut self, original_shell_id: i32, new_shell_id: i32,
                                 ricochet_position: Vector3, ricochet_velocity: Vector3, ricochet_time: f64) {
        self.create_ricochet_rpc_impl(original_shell_id, new_shell_id, ricochet_position, ricochet_velocity, ricochet_time);
    }
    #[func(rename = createRicochetRpc2)]
    pub(crate) fn create_ricochet_rpc2_camel(&mut self, data: PackedByteArray) {
        self.create_ricochet_rpc2_impl(data);
    }

    #[func] pub(crate) fn destroy_bullet_rpc(&mut self, id: i32, position: Vector3, hit_result: i32, normal: Vector3) {
        self.destroy_bullet_rpc_impl(id, position, hit_result, normal);
    }
    #[func] pub(crate) fn destroy_bullet_rpc2(&mut self, id: i32, pos: Vector3, hit_result: i32, normal: Vector3) {
        self.destroy_bullet_rpc2_impl(id, pos, hit_result, normal);
    }
    #[func] pub(crate) fn destroy_bullet_rpc3(&mut self, data: PackedByteArray) {
        self.destroy_bullet_rpc3_impl(data);
    }
    #[func] pub(crate) fn create_ricochet_rpc(&mut self, original_shell_id: i32, new_shell_id: i32,
                                   ricochet_position: Vector3, ricochet_velocity: Vector3, ricochet_time: f64) {
        self.create_ricochet_rpc_impl(original_shell_id, new_shell_id, ricochet_position, ricochet_velocity, ricochet_time);
    }
    #[func] pub(crate) fn create_ricochet_rpc2(&mut self, data: PackedByteArray) {
        self.create_ricochet_rpc2_impl(data);
    }

    #[func] pub(crate) fn apply_fire_damage(&mut self, projectile: Gd<ProjectileData>, ship: Gd<Object>, hit_position: Vector3) {
        self.apply_fire_damage_impl(&projectile, ship, hit_position);
    }
    #[func] pub(crate) fn print_armor_debug(&self, armor_result: VarDictionary, ship: Gd<Object>) {
        self.print_armor_debug_impl(armor_result, ship);
    }
    #[func] pub(crate) fn validate_penetration_formula(&self) { self.validate_penetration_formula_impl(); }

    #[func] pub(crate) fn get_shells_near_position(&self, position: Vector2, radius: f32, exclude_team_id: i32) -> VarArray {
        self.get_shells_near_position_impl(position, radius, exclude_team_id)
    }
}
