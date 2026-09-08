use crate::variant_cast::VariantCast;
use godot::classes::multiplayer_api::RpcMode;
use godot::classes::multiplayer_peer::TransferMode;
use godot::classes::{Os, PhysicsRayQueryParameters3D, ProjectSettings, ResourceLoader, Script};
use godot::prelude::*;

use super::{hit_result as rpc_hit, ProjectileManager, SHELL_GRID_DIM};
use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2;
use crate::nav::map::NavigationMap;
use crate::projectile::armor::{hit_result as armor_hit, NativeArmorInteraction};
use crate::projectile::data::ProjectileData;

impl ProjectileManager {
    /// Deferred from `_ready` via a 0.5 s SceneTreeTimer so the particle system
    /// is guaranteed to exist by the time we look for it.
    pub(crate) fn init_compute_trails_impl(&mut self) {
        godot_print!("ProjectileManager: Initializing compute trails...");

        self.compute_particle_system = self.find_particle_system();

        let Some(mut cps) = self.compute_particle_system.clone() else {
            godot_warn!("ProjectileManager: UnifiedParticleSystem not found, trails disabled");
            return;
        };

        godot_print!("ProjectileManager: Found UnifiedParticleSystem");

        // The template is pre-registered by ParticleSystemInit with
        // align_to_velocity = true; register it here and take its id.
        let Some(tpl) = self.trail_template.clone() else {
            godot_warn!("ProjectileManager: trail_template not set, trails disabled");
            return;
        };
        let registered_id = cps
            .call("ensure_template_registered", &[tpl.to_variant()])
            .to_i32();
        godot_print!("ProjectileManager: trail template registered with id = {}", registered_id);
        if registered_id < 0 {
            godot_warn!("ProjectileManager: Failed to register trail template, trails disabled");
            return;
        }

        let final_id = tpl.get("template_id").try_to::<i32>().unwrap_or(-1);
        godot_print!("ProjectileManager: Using compute shader trails (template_id={})", final_id);
    }

    fn find_particle_system(&self) -> Option<Gd<Node>> {
        if !self.base().is_inside_tree() {
            godot_warn!("ProjectileManager: Not in scene tree, cannot find particle system");
            return None;
        }
        let root = self.base().get_tree().get_root();

        if root.has_node("UnifiedParticleSystem") {
            return root.get_node_or_null("UnifiedParticleSystem");
        }

        // Search root children, then one level deeper.
        for child in root.get_children().iter_shared() {
            if child.get_class() == GString::from("UnifiedParticleSystem") {
                return Some(child);
            }
            for grandchild in child.get_children().iter_shared() {
                if grandchild.get_class() == GString::from("UnifiedParticleSystem") {
                    return Some(grandchild);
                }
            }
        }
        None
    }

    pub(crate) fn ready_impl(&mut self) {
        crate::panic_guard::install();
        godot_print!("[ProjectileManager] _ready: begin");
        // The C++ constructor calls `ray_query.instantiate()`, `mesh_ray_query.instantiate()`
        // and sizes `shell_grid`; mod.rs::init() (this port's constructor equivalent) can't do
        // that itself (building `PhysicsRayQueryParameters3D` needs `NewGd`, and the fields
        // stay `None`/empty there), so do it here once, before anything reads them.
        if self.ray_query.is_none() {
            self.ray_query = Some(PhysicsRayQueryParameters3D::new_gd());
        }
        if self.mesh_ray_query.is_none() {
            self.mesh_ray_query = Some(PhysicsRayQueryParameters3D::new_gd());
        }
        if self.shell_grid.is_empty() {
            self.shell_grid = vec![Vec::new(); (SHELL_GRID_DIM * SHELL_GRID_DIM) as usize];
        }

        // Run penetration formula validation on startup
        self.validate_penetration_formula_impl();

        let is_server = Os::singleton().get_cmdline_args().contains("--server");
        self.current_time = 0.0;

        if is_server {
            godot_print!("running server");

            let ray_query = self.ray_query.as_mut().unwrap();
            ray_query.set_collide_with_areas(true);
            ray_query.set_collide_with_bodies(true);
            ray_query.set_collision_mask(1 | (1 << 1)); // world and detailed mesh collision
            ray_query.set_hit_back_faces(true);

            // Configure mesh ray query for detailed armor intersection
            let mesh_ray_query = self.mesh_ray_query.as_mut().unwrap();
            mesh_ray_query.set_collide_with_areas(false);
            mesh_ray_query.set_collide_with_bodies(true);
            mesh_ray_query.set_collision_mask(1 << 1); // Second physics layer for detailed mesh collision
            mesh_ray_query.set_hit_back_faces(true);

            // Cache armor-related autoload references. Projectile simulation uses the native
            // armor path directly; ArmorInteraction is kept cached for legacy/debug callers.
            if self.base().has_node("/root/ArmorInteraction") {
                self.armor_interaction = self.base().get_node_or_null("/root/ArmorInteraction");
                godot_print!("Cached ArmorInteraction autoload");
            } else {
                godot_warn!("ArmorInteraction autoload not found!");
            }
            if self.base().has_node("/root/PrecisionPhysicsWorld") {
                self.precision_physics_world = self.base().get_node_or_null("/root/PrecisionPhysicsWorld");
                godot_print!("Cached PrecisionPhysicsWorld autoload");
            } else {
                godot_warn!("PrecisionPhysicsWorld autoload not found!");
            }
            if self.base().has_node("/root/NavigationMapManager") {
                self.navigation_map_manager = self.base().get_node_or_null("/root/NavigationMapManager");
                let map_var = self.navigation_map_manager.as_mut().unwrap().call("get_map", &[]);
                self.navigation_map = map_var.try_to::<Gd<NavigationMap>>().ok();
                godot_print!("Cached NavigationMapManager autoload");
            } else {
                godot_warn!("NavigationMapManager autoload not found!");
            }

            // Cache TcpThreadPool autoload reference
            if self.base().has_node("/root/TcpThreadPool") {
                self.tcp_thread_pool = self.base().get_node_or_null("/root/TcpThreadPool");
                godot_print!("Cached TcpThreadPool autoload");
            } else {
                godot_warn!("TcpThreadPool autoload not found!");
            }
        } else {
            godot_print!("running client");

            // Cache SoundEffectManager autoload reference
            if self.base().has_node("/root/SoundEffectManager") {
                self.sound_effect_manager = self.base().get_node_or_null("/root/SoundEffectManager");
                godot_print!("Cached SoundEffectManager autoload");
            } else {
                godot_warn!("SoundEffectManager autoload not found!");
            }

            // Initialize GPU-based renderer
            let gpu_renderer_script =
                ResourceLoader::singleton().load("res://src/artillary/GPUProjectileRenderer.gd");
            if let Some(script_res) = gpu_renderer_script {
                if let Ok(mut script) = script_res.try_cast::<Script>() {
                    let instance = script.call("new", &[]);
                    if let Some(mut node) = instance.try_to::<Gd<Node>>().ok() {
                        node.call("set_time_multiplier", &[self.shell_time_multiplier.to_variant()]);
                        self.base_mut().add_child(&node);
                        godot_print!("Using GPU-based projectile rendering");
                        self.gpu_renderer = Some(node);
                    }
                }
            }

            // C++ additionally defers `_init_compute_trails` via a 0.5s SceneTreeTimer
            // connected by method-name string (`timer->connect("timeout", Callable(this,
            // "_init_compute_trails"))`). That method (and `_find_particle_system`, only
            // reachable from it) is out of scope for this port and unbound in mod.rs, so
            // there is nothing for the timer to call; skipped rather than wiring a Callable
            // to a nonexistent method.
        }

        let mut sync_time_rpc = VarDictionary::new();
        sync_time_rpc.set("rpc_mode", RpcMode::AUTHORITY);
        sync_time_rpc.set("transfer_mode", TransferMode::UNRELIABLE_ORDERED);
        sync_time_rpc.set("call_local", false);
        sync_time_rpc.set("channel", 0);
        self.base_mut().rpc_config("sync_time", &sync_time_rpc.to_variant());

        self.projectiles = Self::single_nil_slot_array();
        // Deferred so the UnifiedParticleSystem is guaranteed to exist
        // (projectile_manager.cpp:318-319). Connected BY NAME, as the C++ does.
        let mut timer = self.base().get_tree().create_timer(0.5);
        let cb = Callable::from_object_method(&self.to_gd(), "_init_compute_trails");
        timer.connect("timeout", &cb);

        self.base_mut().set_process(false);
        self.base_mut().set_physics_process(false);

        godot_print!(
            "[ProjectileManager] _ready: done | shell_time_multiplier={} | gpu_renderer={} \
compute_particle_system={} camera={} trail_template={}",
            self.shell_time_multiplier,
            self.gpu_renderer.is_some(),
            self.compute_particle_system.is_some(),
            self.camera.is_some(),
            self.trail_template.is_some()
        );
        godot_print!(
            "[ProjectileManager] _ready: autoloads | armor_interaction={} armor_sim_logger={} \
precision_physics_world={} navigation_map_manager={} navigation_map={} tcp_thread_pool={} \
sound_effect_manager={}",
            self.armor_interaction.is_some(),
            self.armor_sim_logger.is_some(),
            self.precision_physics_world.is_some(),
            self.navigation_map_manager.is_some(),
            self.navigation_map.is_some(),
            self.tcp_thread_pool.is_some(),
            self.sound_effect_manager.is_some()
        );
        godot_print!(
            "[ProjectileManager] _ready: state | ray_query={} mesh_ray_query={} projectiles={} \
shell_grid_cells={}",
            self.ray_query.is_some(),
            self.mesh_ray_query.is_some(),
            self.projectiles.len(),
            self.shell_grid.len()
        );
    }

    pub(crate) fn process_impl(&mut self, delta: f64) {
        let this = self as *mut Self;
        // SAFETY: single-threaded Godot main loop; the closure is the only user
        // of `this` and does not outlive this call.
        crate::panic_guard::guard("_ProjectileManager::_process", || unsafe {
            (*this).process_inner(delta)
        });
    }

    fn process_inner(&mut self, delta: f64) {
        if self.camera.is_none() {
            return;
        }
        let physics_fps = ProjectSettings::singleton()
            .get_setting("physics/common/physics_ticks_per_second")
            .to_i32();

        // Update shell positions in GPU renderer and trail particles
        self.process_trails_only_impl(self.client_time);

        // Predict current_time for the next physics step to reduce perceived latency.
        let predicted_time = self.current_time + 1.0 / physics_fps as f64;
        if self.client_time > predicted_time {
            self.client_time += (delta / (1.0 + self.client_time - self.current_time).powf(2.0))
                .min(self.client_time - self.current_time);
        } else if self.client_time < predicted_time {
            // Increment client_time faster as the difference increases, to catch up to
            // current_time, avoiding long delays.
            self.client_time += (delta * (1.0 + self.current_time - self.client_time).powf(2.0))
                .min(predicted_time - self.client_time);
        }
    }

    pub(crate) fn process_trails_only_impl(&mut self, current_time: f64) {
        let physics_fps = ProjectSettings::singleton()
            .get_setting("physics/common/physics_ticks_per_second")
            .to_i32();
        // Matches a dead C++ local: `step_size` is computed but only consumed by the
        // trail-popping smoothing code, which is commented out in the source.
        let _step_size = 1.0 / physics_fps as f64;

        let len = self.projectiles.len();
        for i in 0..len {
            let Some(mut p) = self.projectile_at(i) else {
                continue;
            };

            // `p` is a Rust-native ProjectileData, so read its fields through
            // `bind()` instead of the dynamic `get("name")` property path; this
            // mirrors the C++ `p->get_params()` / `p->get_start_time()` direct
            // member calls. The guard is kept short-lived because it must not be
            // held across any call that re-enters the same object.
            let (params_opt, start_time, start_position, launch_velocity, frame_count, mut emitter_id) = {
                let b = p.bind();
                (b.params.clone(), b.start_time, b.start_position, b.launch_velocity, b.frame_count, b.emitter_id)
            };

            let Some(shell_params) = params_opt else {
                continue;
            };
            let t = (current_time - start_time) * self.shell_time_multiplier;

            // Calculate position for rendering and trail emission using the native
            // ProjectilePhysicsWithDragV2 static method directly.
            let new_position = ProjectilePhysicsWithDragV2::calculate_position_at_time_impl(
                start_position,
                launch_velocity,
                t,
                &shell_params,
            );
            p.bind_mut().position = new_position;

            // Update GPU renderer with new position
            let gpu_id = frame_count; // GPU slot ID stored in frame_count
            if let Some(gpu) = self.gpu_renderer.as_mut() {
                if gpu_id >= 0 {
                    gpu.call("update_shell_position", &[gpu_id.to_variant(), new_position.to_variant()]);
                }
            }

            // `position` was just assigned `new_position` and the setter is a plain
            // field write, so re-reading the field here would return the same value.
            if emitter_id < 0
                && (new_position - start_position).length_squared() > 15.0 * 15.0
            {
                // Allocate GPU emitter for trail emission
                let current_trail_id = self
                    .trail_template
                    .as_ref()
                    .map(|t| t.get("template_id").to_i32())
                    .unwrap_or(-1);
                if let Some(cps) = self.compute_particle_system.as_mut() {
                    if current_trail_id >= 0 {
                        // `size` lives on the GDScript ShellParams resource, so this
                        // one stays a dynamic property read.
                        let size: f64 = shell_params.get("size").to_f64();
                        let width_scale = size * 0.9;
                        // emit_rate = 0.05 means 1 particle per 20 units (matching old step_size)
                        let new_emitter_id = cps
                            .call(
                                "allocate_emitter",
                                &[
                                    current_trail_id.to_variant(), // template_id
                                    new_position.to_variant(),     // starting_position
                                    width_scale.to_variant(),      // size_multiplier
                                    0.05f64.to_variant(),           // emit_rate
                                    1.0f64.to_variant(),            // speed_scale
                                    0.0f64.to_variant(),            // velocity_boost
                                ],
                            )
                            .to_i32();
                        p.bind_mut().emitter_id = new_emitter_id;
                        emitter_id = new_emitter_id;
                    }
                }
            }

            // Use GPU emitter system for trails if available
            if let Some(cps) = self.compute_particle_system.as_mut() {
                if emitter_id >= 0 {
                    // Simply update the emitter position - GPU handles emission automatically
                    cps.call(
                        "update_emitter_position",
                        &[emitter_id.to_variant(), new_position.to_variant()],
                    );
                }
            }
        }
    }

    pub(crate) fn sync_time_impl(&mut self, server_time: f64) {
        self.current_time = server_time;
    }

    pub(crate) fn clear_all_impl(&mut self) {
        // Destroy visuals for every active projectile before clearing data
        let len = self.projectiles.len();
        for i in 0..len {
            let Some(p) = self.projectile_at(i) else {
                continue;
            };

            // Remove GPU renderer shell sprite
            let gpu_id = p.bind().frame_count;
            if let Some(gpu) = self.gpu_renderer.as_mut() {
                if gpu_id >= 0 {
                    gpu.call("destroy_shell", &[gpu_id.to_variant()]);
                }
            }

            // Free trail emitter
            let emitter_id = p.bind().emitter_id;
            if let Some(cps) = self.compute_particle_system.as_mut() {
                if emitter_id >= 0 {
                    cps.call("free_emitter", &[emitter_id.to_variant()]);
                }
            }
        }

        // Clear all projectile data
        self.projectiles = Self::single_nil_slot_array(); // clear() + resize(1), matching _ready's initial state
        self.ids_reuse.clear();
        self.shell_param_ids.clear();
        self.next_id = 0;
        self.bullet_id = 0;
        self.next_shell_uid = 1;

        // Clear shell landing grid
        self.shell_landings.clear();
        self.armor_ray_cache.clear();
        for cell in self.shell_grid.iter_mut() {
            cell.clear();
        }

        godot_print!("ProjectileManager: cleared all projectiles and visuals");
    }

    pub(crate) fn set_shell_time_multiplier_impl(&mut self, value: f64) {
        self.shell_time_multiplier = value;
    }

    pub(crate) fn physics_process_impl(&mut self, delta: f64) {
        let this = self as *mut Self;
        // SAFETY: single-threaded Godot main loop; the closure is the only user
        // of `this` and does not outlive this call.
        crate::panic_guard::guard("_ProjectileManager::_physics_process", || unsafe {
            (*this).physics_process_inner(delta)
        });
    }

    fn physics_process_inner(&mut self, delta: f64) {
        let sync_time_arg = self.current_time.to_variant();
        let _ = self.base_mut().rpc("sync_time", &[sync_time_arg]);
        self.current_time += delta; // raw wall-clock seconds; scaling applied at physics call sites

        if self.navigation_map.is_none() {
            if let Some(mgr) = self.navigation_map_manager.as_mut() {
                let map_var = mgr.call("get_map", &[]);
                self.navigation_map = map_var.try_to::<Gd<NavigationMap>>().ok();
            }
        }

        let tree = self.base().get_tree();
        let root = tree.get_root();
        let Some(world) = root.get_world_3d() else {
            return;
        };

        let mut space_state = world.get_direct_space_state();
        if space_state.is_none() {
            godot_warn!("ProjectileManager: No PhysicsDirectSpaceState3D available");
        }

        // Resolved lazily: ArmorSimLogger is registered after ProjectileManager in the
        // autoload list, so it does not exist yet at _ready() time.
        if self.armor_sim_logger.is_none() && self.base().has_node("/root/ArmorSimLogger") {
            self.armor_sim_logger = self.base().get_node_or_null("/root/ArmorSimLogger");
        }
        // Only build the per-plate armor log payload while a match recording has an
        // open .armorlog companion file; queried once per frame, not per projectile.
        let log_armor = match self.armor_sim_logger.as_mut() {
            Some(logger) => logger.call("is_logging", &[]).to_bool(),
            None => false,
        };

        let projectiles_len = self.projectiles.len();
        for i in 0..projectiles_len {
            let Some(mut p) = self.projectile_at(i) else {
                continue;
            };
            // Every path through the C++ loop body increments `id` exactly once per
            // iteration (including every `continue`), so `id` is always equal to the
            // loop index; use it directly instead of tracking a parallel counter.
            let id = i as i32;

            // Native-field reads via `bind()` rather than the dynamic `get("name")`
            // path — see process_trails_only_impl. The guard is dropped before
            // `process_travel`, which binds `p` itself.
            let (start_time, prev_position, params_opt, start_position, launch_velocity) = {
                let b = p.bind();
                (b.start_time, b.position, b.params.clone(), b.start_position, b.launch_velocity)
            };

            let t = (self.current_time - start_time) * self.shell_time_multiplier;

            self.ray_query.as_mut().unwrap().set_from(prev_position);

            // Calculate new position using native ProjectilePhysicsWithDragV2 static method
            let Some(params) = params_opt else {
                godot_warn!("ProjectileManager: Projectile has invalid shell_params, skipping");
                continue;
            };
            let new_position = ProjectilePhysicsWithDragV2::calculate_position_at_time_impl(
                start_position,
                launch_velocity,
                t,
                &params,
            );
            p.bind_mut().position = new_position;
            self.ray_query.as_mut().unwrap().set_to(new_position);
            p.bind_mut().increment_frame_count();

            // Process travel through the native armor interaction path. Ray query objects
            // are cached per owner/exclude set; only from/to is updated per projectile.
            // Clone the autoload/nav-map handles up front: `get_armor_ray_cache` needs
            // `&mut self`, and Rust (unlike C++) won't let that coexist with other
            // borrows of `self` in the same call.
            let precision_physics_world = self.precision_physics_world.clone();
            let navigation_map = self.navigation_map.clone();
            let from_pos = self.ray_query.as_ref().unwrap().get_from();
            let armor_rays = self.get_armor_ray_cache(&p);
            let hit_result = NativeArmorInteraction::process_travel(
                &p,
                from_pos,
                t,
                space_state.as_mut(),
                precision_physics_world.as_ref(),
                &navigation_map,
                armor_rays,
                log_armor,
            );

            if !hit_result.hit {
                // If the shell is underwater and process_travel returned null,
                // destroy it — it should not survive to the next frame.
                if new_position.y < 0.0 {
                    godot_print!("ProjectileManager: Shell is underwater with no hit result, destroying");
                    self.destroy_bullet_rpc_impl(
                        id,
                        new_position,
                        rpc_hit::WATER,
                        Vector3::new(0.0, 1.0, 0.0),
                    );
                }
                continue;
            }

            // NativeArmorInteraction::HitResult enum values:
            // PENETRATION=0, PARTIAL_PEN=1, RICOCHET=2, OVERPENETRATION=3, SHATTER=4,
            // CITADEL=5, CITADEL_OVERPEN=6, WATER=7, TERRAIN=8
            // _ProjectileManager::HitResult enum values (for RPC):
            // PENETRATION=0, RICOCHET=1, OVERPENETRATION=2, SHATTER=3, NOHIT=4, CITADEL=5, WATER=6

            // Mirror the armor interaction into the .armorlog companion file that the
            // shell/match replay tools read back. Done here rather than inside the
            // armor sim so the native path stays free of script calls.
            if hit_result.log_valid {
                if let Some(victim) = hit_result.ship.clone().and_then(|s| s.try_cast::<Node3D>().ok()) {
                    if let Some(logger) = self.armor_sim_logger.as_mut() {
                        let log_type = params.get("type").to_i32();
                        let log_caliber = params.get("caliber").to_f64();
                        let log_shell_uid = p.bind().shell_uid as i64;
                        let log_owner = p.bind().owner.clone();
                        logger.call(
                            "record_hit",
                            &[
                                log_shell_uid.to_variant(),
                                hit_result.result_type.to_variant(),
                                log_owner.to_variant(),
                                victim.to_variant(),
                                victim.get_global_position().to_variant(),
                                victim.get_rotation().y.to_variant(),
                                log_type.to_variant(),
                                log_caliber.to_variant(),
                                hit_result.log_steps.to_variant(),
                                hit_result.log_final_pos.to_variant(),
                                params.to_variant(),
                            ],
                        );
                    }
                }
            }

            let armor_result_type = hit_result.result_type;
            let explosion_position = hit_result.explosion_position;
            let collision_normal = hit_result.collision_normal;
            let ship_opt = hit_result.ship.clone();
            let armor_part_var = hit_result.armor_part.clone();
            let ricochet_velocity = hit_result.velocity;
            let owner = p.bind().owner.clone();

            if let Some(owner_obj) = owner.clone() {
                let stats_var = owner_obj.get("stats");
                if !stats_var.is_nil() {
                    if let Ok(stats) = stats_var.try_to::<Gd<Object>>() {
                        let base_damage = params.get("damage").to_f64();
                        let caliber = params.get("caliber").to_f64();
                        let mut stats = stats;
                        stats.call(
                            "record_potential_damage",
                            &[base_damage.to_variant(), explosion_position.to_variant(), caliber.to_variant()],
                        );
                    }
                }
            }

            // Handle water and terrain hits (no ship involved)
            if armor_result_type == armor_hit::WATER {
                self.destroy_bullet_rpc_impl(id, explosion_position, rpc_hit::WATER, collision_normal);
                continue;
            } else if armor_result_type == armor_hit::TERRAIN {
                self.destroy_bullet_rpc_impl(id, explosion_position, rpc_hit::PENETRATION, collision_normal);
                continue;
            }

            // Any non-null, non-WATER, non-TERRAIN result means the shell interacted
            // with armor and must be destroyed regardless of whether damage is applied.
            // Determine the RPC result type and whether this is a ricochet (spawns new shell).
            let mut damage: f64 = 0.0;
            let mut rpc_result_type = rpc_hit::NOHIT;
            let mut damage_type: i32 = 0; // SHELL
            let mut damage_level: i32 = 0; // LIGHT
            let mut is_ricochet = false;

            // Handle ship hits — only apply damage if we have a valid ship and owner
            if let (Some(ship), Some(owner_obj)) = (ship_opt.clone(), owner.clone()) {
                let exclude = p.bind().exclude.clone();

                if !NativeArmorInteraction::is_owner_or_excluded(&ship_opt, &owner, &exclude) {
                    let base_damage = params.get("damage").to_f64();

                    // Map ArmorInteraction result to damage and RPC result type
                    match armor_result_type {
                        armor_hit::PENETRATION => {
                            damage = base_damage / 3.0;
                            rpc_result_type = rpc_hit::PENETRATION;
                            damage_level = 1; // MEDIUM
                        }
                        armor_hit::PARTIAL_PEN => {
                            damage = base_damage * 0.0667;
                            rpc_result_type = rpc_hit::PENETRATION;
                            damage_level = 1; // MEDIUM
                        }
                        armor_hit::CITADEL => {
                            damage = base_damage;
                            rpc_result_type = rpc_hit::CITADEL;
                            damage_level = 2; // HEAVY
                        }
                        armor_hit::CITADEL_OVERPEN => {
                            damage = base_damage * 0.5;
                            rpc_result_type = rpc_hit::PENETRATION;
                            damage_level = 2; // HEAVY
                        }
                        armor_hit::OVERPENETRATION => {
                            damage = base_damage * 0.1;
                            rpc_result_type = rpc_hit::OVERPENETRATION;
                            damage_level = 0; // LIGHT
                        }
                        armor_hit::SHATTER => {
                            damage = 0.0;
                            rpc_result_type = rpc_hit::SHATTER;
                            damage_level = 0; // LIGHT
                        }
                        armor_hit::RICOCHET => {
                            damage = 0.0;
                            rpc_result_type = rpc_hit::RICOCHET;

                            // Don't spawn ricochet shells underwater — a shell
                            // bouncing off submerged armor has no meaningful trajectory.
                            if explosion_position.y >= 0.0 {
                                is_ricochet = true;
                                let ricochet_position = explosion_position
                                    + collision_normal * 0.2
                                    + ricochet_velocity.normalized() * 0.2;

                                // Create ricochet projectile with ship added to exclude list.
                                // C++ passes `nullptr` for owner here; fire_bullet_impl's
                                // `owner` parameter is non-optional (`Gd<Object>`, not
                                // `Option`), so the original shell's owner (known to be
                                // `Some` in this branch) is passed instead. See report.
                                let mut new_exclude = exclude.duplicate_shallow();
                                new_exclude.push(&ship.to_variant());
                                let ricochet_id = self.fire_bullet_impl(
                                    ricochet_velocity,
                                    ricochet_position,
                                    &params,
                                    self.current_time,
                                    Some(owner_obj.clone()),
                                    new_exclude,
                                );

                                // Send ricochet RPC via TcpThreadPool
                                if let Some(pool) = self.tcp_thread_pool.as_mut() {
                                    pool.call(
                                        "send_ricochet",
                                        &[
                                            id.to_variant(),
                                            ricochet_id.to_variant(),
                                            ricochet_position.to_variant(),
                                            ricochet_velocity.to_variant(),
                                            self.current_time.to_variant(),
                                        ],
                                    );
                                }
                            }
                        }
                        _ => {}
                    }

                    // Apply damage to ship if alive
                    let health_controller_var = ship.get("health_controller");
                    if !health_controller_var.is_nil() {
                        if let Ok(health_controller) = health_controller_var.try_to::<Gd<Object>>() {
                            let mut health_controller = health_controller;
                            if health_controller.call("is_alive", &[]).to_bool() {
                                let team = ship
                                    .get("team")
                                    .try_to::<Gd<Object>>()
                                    .expect("ProjectileManager: ship has no team object");
                                let owner_team = owner_obj
                                    .get("team")
                                    .try_to::<Gd<Object>>()
                                    .expect("ProjectileManager: owner has no team object");
                                let owner_team_id = owner_team.get("team_id").to_i32();
                                let team_id = team.get("team_id").to_i32();

                                // Skip damage for friendly fire, but still let the shell be destroyed below
                                if team_id != owner_team_id {
                                    let is_penetration =
                                        rpc_result_type == rpc_hit::PENETRATION || rpc_result_type == rpc_hit::CITADEL;
                                    let is_secondary = params.get("_secondary").to_bool();
                                    damage_type = if is_secondary { 4 } else { 0 }; // 0 = SHELL, 4 = SECONDARY
                                    let dmg_sunk = health_controller
                                        .call(
                                            "apply_damage",
                                            &[
                                                damage.to_variant(),
                                                base_damage.to_variant(),
                                                armor_part_var.to_variant(),
                                                is_penetration.to_variant(),
                                                damage_type.to_variant(),
                                                damage_level.to_variant(),
                                                owner_obj.to_variant(),
                                            ],
                                        )
                                        .to_any_array();

                                    // Apply fire damage
                                    self.apply_fire_damage_impl(&p, Some(ship.clone()), explosion_position);

                                    // Delegate all stat tracking to GDScript Stats.record_hit()
                                    if dmg_sunk.len() > 0 {
                                        let stats_var = owner_obj.get("stats");
                                        if !stats_var.is_nil() {
                                            if let Ok(stats) = stats_var.try_to::<Gd<Object>>() {
                                                let mut stats = stats;
                                                let is_secondary = params.get("_secondary").to_bool();
                                                let sunk = dmg_sunk.len() > 1 && dmg_sunk.at(1).to_bool();
                                                let hit_damage = dmg_sunk.at(0).to_f64();

                                                // Use the surface contact point (explosion_position from
                                                // ArmorInteraction) rather than the ship centre so replay
                                                // hit effects land on the hull.
                                                stats.call(
                                                    "record_hit",
                                                    &[
                                                        armor_result_type.to_variant(),
                                                        hit_damage.to_variant(),
                                                        is_secondary.to_variant(),
                                                        explosion_position.to_variant(),
                                                        sunk.to_variant(),
                                                        ship.to_variant(),
                                                    ],
                                                );
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        godot_error!("ProjectileManager: Ship does NOT have health_controller member variable");
                    }
                }
            }

            let _ = is_ricochet; // matches a dead C++ local: set but never read afterward

            // Always destroy the shell when process_travel returned a non-null result.
            // Damage may or may not have been applied above, but the shell is consumed.
            self.destroy_bullet_rpc_impl(id, explosion_position, rpc_result_type, collision_normal);
        }
    }

    /// Godot's typed arrays tolerate nil holes: the C++ `projectiles.resize(1)` in the
    /// constructor/`_ready`/`clear_all` leaves slot 0 nil until `fire_bullet` overwrites it.
    /// gdext's safe `Array<Gd<T>>::resize`/`push` require a real `Gd<T>` fill value and can't
    /// reproduce that. Build the hole through the untyped view instead: `Gd<T>: Element`
    /// doesn't validate elements when an `Array<Variant>` is re-tagged as `Array<Gd<T>>` (see
    /// `debug_validate_elements`), so this mirrors exactly what the engine does internally.
    /// `clear() + resize(1)` matching the C++ initial state: one NIL slot.
    /// A nil element is representable directly now that `projectiles` is a
    /// VarArray, so no type re-tagging is needed.
    fn single_nil_slot_array() -> VarArray {
        let mut a = VarArray::new();
        a.push(&Variant::nil());
        a
    }

    /// `Array<Gd<T>>::get`/`at` panic on a nil in-bounds slot, since they convert through
    /// `Gd::from_variant`; the C++ instead reads a `Variant` and checks `get_type() == NIL` /
    /// `Ref::is_valid()`. Route through the untyped view so a nil or wrongly-typed slot reads
    /// as `None` here too, combining both C++ checks into one.
    fn projectile_at(&self, index: usize) -> Option<Gd<ProjectileData>> {
        let v = self.projectiles.at(index);
        if v.is_nil() {
            None
        } else {
            v.try_to::<Gd<ProjectileData>>().ok()
        }
    }
}
