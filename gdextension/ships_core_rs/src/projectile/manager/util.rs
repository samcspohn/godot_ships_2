use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::{Engine, Node, PhysicsDirectSpaceState3D, Resource};

use super::{ProjectileManager, SHELL_GRID_CELL, SHELL_GRID_MIN, SHELL_GRID_DIM};
use crate::projectile::armor::{NativeArmorInteraction, RaycastCache};
use crate::nav::map::NavigationMap;
use crate::projectile::data::ProjectileData;

impl ProjectileManager {
    pub(crate) fn calculate_penetration_power_impl(&self, shell_params: Option<&Gd<Resource>>, velocity: f64) -> f64 {
        // `Gd<Resource>` cannot be null the way `Ref<>` can in C++, so the
        // `shell_params.is_valid()` early-return in the source is unreachable here.

        // Get shell parameters
        // C++ guards `if (!shell_params.is_valid()) return 0.0;`
        let Some(shell_params) = shell_params else {
            return 0.0;
        };
        let weight_kg: f64 = shell_params.get("mass").to_f64();
        let caliber_mm: f64 = shell_params.get("caliber").to_f64();
        let velocity_ms: f64 = velocity;
        let shell_type: i32 = shell_params.get("type").to_i32();
        let penetration_modifier: f64 = shell_params.get("penetration_modifier").to_f64();

        // Modified naval armor penetration formula based on historical data
        // This version uses empirically derived constants for realistic results
        // Penetration (mm) = K * W^0.55 * V^1.1 / D^0.65
        let naval_constant_metric: f64 = 0.55664;

        // std::pow, not powi: each exponent is a double literal, matching the
        // C++ libm pow() call bit-for-bit.
        let base_penetration = naval_constant_metric * weight_kg.powf(0.55) * velocity_ms.powf(1.1)
            / caliber_mm.powf(0.65);

        // Apply shell type modifiers
        let mut shell_quality_factor: f64;
        if shell_type == 1 {
            // AP shell (assuming AP = 1)
            shell_quality_factor = 1.0; // AP shells are the baseline
        } else {
            // HE shell
            shell_quality_factor = 0.4; // HE shells have much reduced penetration
        }

        // Apply shell-specific penetration modifier
        shell_quality_factor *= penetration_modifier;

        base_penetration * shell_quality_factor
    }

    pub(crate) fn calculate_impact_angle_impl(&self, velocity: Vector3, surface_normal: Vector3) -> f64 {
        // gdext's Vector3::angle_to delegates to glam's angle_between, which uses
        // a DIFFERENT formula from godot-cpp's `atan2(cross.length(), dot)` and
        // differs at f32 epsilon. Spell out the godot-cpp form so the result
        // matches. Still f32 throughout (angle_to returns real_t), widened after.
        let v = velocity.normalized();
        let angle_rad: f64 = v.cross(surface_normal).length().atan2(v.dot(surface_normal)) as f64;
        angle_rad.min(std::f64::consts::PI - angle_rad)
    }

    pub(crate) fn next_pow_of_2(value: i32) -> i32 {
        if value <= 0 {
            return 1;
        }

        // Bit manipulation to find next power of 2.
        // value > 0 is guaranteed here, so `result` starts >= 0 and the shifts
        // below are never shifts of a negative value (which would be UB in
        // C++); wrapping_sub/add just guard the rare overflow case at the
        // top of the i32 range without altering behavior for any in-range value.
        let mut result = value;
        result = result.wrapping_sub(1);
        result |= result >> 1;
        result |= result >> 2;
        result |= result >> 4;
        result |= result >> 8;
        result |= result >> 16;
        result = result.wrapping_add(1);
        result
    }

    pub(crate) fn find_ship_impl(&self, node: Option<Gd<Node>>) -> Option<Gd<Object>> {
        Self::find_ship_rec(node)
    }

    /// Recursive walk-up-the-tree helper. The C++ `find_ship(Node*)` is
    /// naturally recursive with a `nullptr` base case; `find_ship_impl`'s
    /// entry parameter is a non-optional `Gd<Node>` (per the fixed stub
    /// signature), so this helper carries the `Option` for the recursion.
    fn find_ship_rec(node: Option<Gd<Node>>) -> Option<Gd<Object>> {
        let node = node?;
        if node.get_class() == GString::from("Ship") {
            return Some(node.upcast::<Object>());
        }
        Self::find_ship_rec(node.get_parent())
    }

    pub(crate) fn armor_ray_cache_key(&self, projectile: &Gd<ProjectileData>) -> u64 {
        // `projectile.is_valid()` in C++ is likewise always true here; see the
        // `&Gd<Resource>` note above.
        let owner = projectile.bind().owner.clone();
        match owner {
            // `InstanceId::to_u64` is a private godot-core method; `to_i64() as u64`
            // reinterprets the same bits, matching C++'s `(uint64_t)get_instance_id()`.
            Some(owner) => owner.instance_id().to_i64() as u64,
            None => 0u64,
        }
    }

    /// C++ returns `RaycastCache&`; Rust hands back a mutable borrow from the map.
    pub(crate) fn get_armor_ray_cache(&mut self, projectile: &Gd<ProjectileData>) -> &mut RaycastCache {
        let key = self.armor_ray_cache_key(projectile);
        let entry = self.armor_ray_cache.entry(key).or_default();
        if entry.rays.terrain_ray.is_none() || entry.rays.obb_ray.is_none() || entry.rays.water_ray.is_none() {
            NativeArmorInteraction::configure_raycast_cache(
                projectile,
                self.precision_physics_world.as_ref(),
                &mut entry.rays,
            );
        }
        entry.last_used_frame = Engine::singleton().get_physics_frames();
        &mut entry.rays
    }

    pub(crate) fn shell_grid_index(&self, wx: f32, wz: f32) -> i32 {
        let mut gx = ((wx - SHELL_GRID_MIN) / SHELL_GRID_CELL) as i32;
        let mut gz = ((wz - SHELL_GRID_MIN) / SHELL_GRID_CELL) as i32;
        gx = 0.max(gx.min(SHELL_GRID_DIM - 1));
        gz = 0.max(gz.min(SHELL_GRID_DIM - 1));
        gz * SHELL_GRID_DIM + gx
    }

    pub(crate) fn shell_grid_insert(&mut self, shell_id: i32, wx: f32, wz: f32) {
        let idx = self.shell_grid_index(wx, wz);
        self.shell_grid[idx as usize].push(shell_id);
    }

    pub(crate) fn shell_grid_remove(&mut self, shell_id: i32) {
        let Some(entry) = self.shell_landings.get(&shell_id) else {
            return;
        };
        let (landing_x, landing_z) = (entry.landing_x, entry.landing_z);

        let idx = self.shell_grid_index(landing_x, landing_z) as usize;
        let cell = &mut self.shell_grid[idx];
        for i in 0..cell.len() {
            if cell[i] == shell_id {
                let last = *cell.last().unwrap();
                cell[i] = last;
                cell.pop();
                break;
            }
        }
        self.shell_landings.remove(&shell_id);
    }

    pub(crate) fn get_shells_near_position_impl(&self, position: Vector2, radius: f32, exclude_team_id: i32) -> VarArray {
        let mut result = VarArray::new();

        let min_gx = 0.max(((position.x - radius - SHELL_GRID_MIN) / SHELL_GRID_CELL) as i32);
        let max_gx = (SHELL_GRID_DIM - 1).min(((position.x + radius - SHELL_GRID_MIN) / SHELL_GRID_CELL) as i32);
        let min_gz = 0.max(((position.y - radius - SHELL_GRID_MIN) / SHELL_GRID_CELL) as i32);
        let max_gz = (SHELL_GRID_DIM - 1).min(((position.y + radius - SHELL_GRID_MIN) / SHELL_GRID_CELL) as i32);

        let radius_sq = radius * radius;

        for gz in min_gz..=max_gz {
            for gx in min_gx..=max_gx {
                let cell = &self.shell_grid[(gz * SHELL_GRID_DIM + gx) as usize];
                for &sid in cell {
                    let Some(e) = self.shell_landings.get(&sid) else {
                        continue;
                    };

                    if e.team_id == exclude_team_id {
                        continue;
                    }

                    let dx = e.landing_x - position.x;
                    let dz = e.landing_z - position.y;
                    if dx * dx + dz * dz > radius_sq {
                        continue;
                    }

                    // fire_time and time_to_impact are both raw seconds; no scaling needed
                    let time_remaining = e.fire_time + e.time_to_impact - self.current_time as f32;
                    if time_remaining <= 0.0 {
                        continue;
                    }

                    let mut d = VarDictionary::new();
                    d.set("shell_id", e.shell_id);
                    d.set("landing_x", e.landing_x);
                    d.set("landing_z", e.landing_z);
                    d.set("time_remaining", time_remaining);
                    d.set("caliber", e.caliber);
                    d.set("landing_vx", e.landing_vx);
                    d.set("landing_vz", e.landing_vz);
                    d.set("threat_half_len", e.threat_half_len);
                    result.push(&d.to_variant());
                }
            }
        }
        result
    }

    /// Fill in the armour-path autoloads if they are not cached yet.
    ///
    /// `ready_impl` caches these once, inside its server branch, which is right
    /// for the live simulation - only the server walks shells. Everything else
    /// that wants to ask the armour a question (the bot gunnery survey, the probe
    /// rig) then has to make sure they are there first, because their absence is
    /// not an error anywhere downstream: it just makes every shell miss.
    pub(crate) fn ensure_armor_autoloads(&mut self) {
        if self.precision_physics_world.is_none() {
            self.precision_physics_world = self.base().get_node_or_null("/root/PrecisionPhysicsWorld");
        }
        if self.navigation_map.is_none() {
            if self.navigation_map_manager.is_none() {
                self.navigation_map_manager = self.base().get_node_or_null("/root/NavigationMapManager");
            }
            if let Some(mgr) = self.navigation_map_manager.as_mut() {
                let map_var = mgr.call("get_map", &[]);
                self.navigation_map = map_var.try_to::<Gd<NavigationMap>>().ok();
            }
        }
    }

    /// Walk one shell through the armour exactly as a live shell is walked, and
    /// hand the outcome back to GDScript as a Dictionary.
    ///
    /// The bot gunnery solver scores an aim point by firing a test shell at it
    /// and paying what the game would pay for the result, which is only a
    /// measurement of the game if it is the game's own armour path. There are
    /// two, and they do not agree: this one, and the legacy GDScript
    /// `ArmorInteraction` autoload that predates the native port. Live shells
    /// have gone through here since the cutover, so anything asking "what would
    /// this shell do" has to come through here too.
    ///
    /// Everything the walk needs beyond the shell itself - the precision world,
    /// the navigation map that gates the terrain raycast, the cached ray query
    /// objects - already hangs off this node, which is why the entry point is
    /// here rather than on a free function.
    ///
    /// `space_state` is the caller's, NOT the live one: the solver walks in a
    /// space holding a copy of the target's broadphase box and nothing else (see
    /// BotGunnery._survey_space). Only the broadphase reads it - the armour
    /// itself is found through the precision world either way - so the walk is
    /// the real one even though the space is not.
    pub(crate) fn sim_process_travel_impl(
        &mut self,
        projectile: Gd<ProjectileData>,
        prev_pos: Vector3,
        t: f64,
        space_state: Option<Gd<PhysicsDirectSpaceState3D>>,
        log_armor: bool,
    ) -> VarDictionary {
        let mut out = VarDictionary::new();
        let Some(mut space_state) = space_state else {
            out.set("hit", false);
            return out;
        };

        // The armour walk is nothing without the precision world: with it unset,
        // find_valid_obb_hit() returns empty and every shell reports a clean miss
        // rather than an error. `ready_impl` only caches it on the SERVER branch,
        // and a caller asking what a shell would do is not necessarily one - the
        // probe rig is a plain scene run. Resolve it here rather than let a whole
        // survey come back silently zero.
        self.ensure_armor_autoloads();

        // Cloned up front for the same reason lifecycle.rs clones them:
        // `get_armor_ray_cache` needs `&mut self` and Rust will not let that
        // coexist with other borrows of `self` in the same call.
        let precision_physics_world = self.precision_physics_world.clone();
        let navigation_map = self.navigation_map.clone();
        let armor_rays = self.get_armor_ray_cache(&projectile);
        let res = NativeArmorInteraction::process_travel(
            &projectile,
            prev_pos,
            t,
            Some(&mut space_state),
            precision_physics_world.as_ref(),
            &navigation_map,
            armor_rays,
            log_armor,
        );

        out.set("hit", res.hit);
        out.set("result_type", res.result_type);
        out.set("explosion_position", res.explosion_position);
        out.set("velocity", res.velocity);
        out.set("collision_normal", res.collision_normal);
        out.set("shell_integrity", res.shell_integrity);
        out.set("overmatch_first_armor", res.overmatch_first_armor);
        out.set(
            "armor_part",
            &res.armor_part.map(|p| p.to_variant()).unwrap_or_else(Variant::nil),
        );
        out.set(
            "ship",
            &res.ship.map(|s| s.to_variant()).unwrap_or_else(Variant::nil),
        );
        // Plate-by-plate detail, only when asked for. The probe rig prints it;
        // the solver walks thousands of shells a second and never wants it, which
        // is why the whole Dictionary/Array churn is behind the flag.
        if log_armor {
            out.set("log_valid", res.log_valid);
            out.set("log_steps", &res.log_steps);
            out.set("log_final_pos", res.log_final_pos);
        }
        out
    }
}
