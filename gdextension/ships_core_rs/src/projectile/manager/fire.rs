use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::{Object, Resource, StreamPeerBuffer};

use super::ProjectileManager;
use super::hit_result::{CITADEL, NOHIT, OVERPENETRATION, PENETRATION, RICOCHET, SHATTER, WATER};
use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2;
use crate::projectile::data::ProjectileData;
use super::ShellLandingEntry;

impl ProjectileManager {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn fire_bullet_impl(&mut self, vel: Vector3, pos: Vector3, shell: &Gd<Resource>,
                                   t: f64, owner: Option<Gd<Object>>, exclude: VarArray) -> i32 {
        let id = if let Some(reused) = self.ids_reuse.pop() {
            reused.to_i32()
        } else {
            let id = self.next_id;
            self.next_id += 1;
            id
        };

        if id >= self.projectiles.len() as i32 {
            let np2 = Self::next_pow_of_2(id + 1);
            self.projectiles.resize(np2 as usize, &Variant::nil());
        }

        let mut bullet = ProjectileData::new_gd();
        // `initialize` is a private method on `ProjectileData` (not visible from
        // this module), but it is also a `#[func]`, so it is invoked the same
        // way any other GDScript-exposed engine method is.
        bullet.call(
            "initialize",
            &[pos.to_variant(), vel.to_variant(), t.to_variant(), shell.to_variant(), owner.to_variant(), exclude.to_variant()],
        );
        bullet.bind_mut().shell_uid = self.next_shell_uid;
        self.next_shell_uid += 1;

        self.projectiles.set(id as usize, &bullet.to_variant());

        // Register in shell landing grid for bot shell-dodging.
        //
        // C++ guards this whole block on `shell.is_valid()`. `shell` here is
        // `&Gd<Resource>`, which can never be a null/invalid reference, so
        // that guard is unconditionally true and is omitted.
        let impact = ProjectilePhysicsWithDragV2::calculate_impact_position_impl(pos, vel, shell);
        let vx = vel.x as f64;
        let vz = vel.z as f64;
        let vy0 = vel.y as f64;
        let v_horiz = (vx * vx + vz * vz).sqrt();
        let theta = if v_horiz > 1e-10 { vy0.atan2(v_horiz) } else { 0.0 };
        let flight_time = ProjectilePhysicsWithDragV2::time_of_flight_impl(theta, shell, (-pos.y) as f64);

        if !flight_time.is_nan() && flight_time > 0.0 {
            let caliber = shell.get("caliber").to_f32();
            // C++: `if (owner != nullptr)` — `owner` here is `Gd<Object>`, never
            // null, so that outer guard is unconditionally true and omitted;
            // only the inner "team" property nil-check remains meaningful.
            let team_id: i32 = match owner.as_ref().map_or(Variant::nil(), |o| o.get("team")).try_to::<Gd<Object>>() {
                Ok(team_obj) => team_obj.get("team_id").to_i32(),
                Err(_) => -1,
            };

            let mut entry = ShellLandingEntry::default();
            entry.shell_id = id;
            entry.landing_x = impact.x;
            entry.landing_z = impact.z;
            entry.time_to_impact = (flight_time / self.shell_time_multiplier) as f32;
            entry.fire_time = self.current_time as f32;
            entry.caliber = caliber;
            entry.team_id = team_id;

            let impact_vel = ProjectilePhysicsWithDragV2::calculate_velocity_at_time_impl(vel, flight_time, shell);
            entry.landing_vx = impact_vel.x;
            entry.landing_vz = impact_vel.z;

            // NOTE: `impact_vel.x`/`.z`/`.y` are `real_t` (f32). The C++ computes
            // `sqrt`/`abs` in float precision here and only widens to double at
            // the point of assignment to `horiz_speed`/`vert_speed` — unlike the
            // `v_horiz` computation above, where the operands were widened to
            // double *before* the sqrt.
            let horiz_speed = (impact_vel.x * impact_vel.x + impact_vel.z * impact_vel.z).sqrt() as f64;
            let vert_speed = impact_vel.y.abs() as f64;
            // angle_from_vertical: 0 = plunging, PI/2 = flat
            let flatness = if horiz_speed + vert_speed > 1e-10 { horiz_speed.atan2(vert_speed) } else { 0.0 };
            // Map flatness to threat_length: flat trajectory = long line, plunging = short
            const THREAT_LINE_MAX_HALF_LEN: f32 = 50.0;
            const THREAT_LINE_MIN_HALF_LEN: f32 = 15.0;
            let t_factor = flatness.sin(); // 0 for plunging, 1 for flat
            entry.threat_half_len = (THREAT_LINE_MIN_HALF_LEN as f64
                + (THREAT_LINE_MAX_HALF_LEN - THREAT_LINE_MIN_HALF_LEN) as f64 * t_factor) as f32;

            self.shell_landings.insert(id, entry);
            self.shell_grid_insert(id, impact.x, impact.z);
        }

        id
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn fire_bullet_client_impl(&mut self, pos: Vector3, vel: Vector3, t: f64, id: i32,
                                          shell: &Gd<Resource>, owner: Option<Gd<Object>>,
                                          muzzle_blast: bool, basis: Basis) {
        self.fire_bullet_client_core(pos, vel, t, id, shell, owner, muzzle_blast, basis);
    }

    /// Shared body for [`fire_bullet_client_impl`] and the ricochet path.
    ///
    /// C++'s `create_ricochet_rpc` calls `fire_bullet_client(.., nullptr, false)`
    /// — i.e. with a null `owner`. `fire_bullet_client_impl`'s contractual
    /// signature takes `owner: Gd<Object>` (never null, matching every
    /// GDScript/RPC caller), and `ProjectileData::initialize`'s signature is
    /// likewise a mandatory `Gd<Object>` — neither can represent "no owner".
    /// This internal core takes `Option<Gd<Object>>` so the ricochet path can
    /// still end up with `bullet.owner == None`: it passes a transient handle
    /// to this manager itself into `initialize()` (never stored, immediately
    /// overwritten by `None` right after) purely to satisfy that mandatory
    /// parameter. Judgement call — see report.
    #[allow(clippy::too_many_arguments)]
    fn fire_bullet_client_core(&mut self, pos: Vector3, vel: Vector3, t: f64, id: i32,
                               shell: &Gd<Resource>, owner: Option<Gd<Object>>,
                               muzzle_blast: bool, basis: Basis) {
        let mut bullet = ProjectileData::new_gd();

        // C++ guards shell-dependent reads on `shell.is_valid()`; `shell` here
        // is `&Gd<Resource>` and can never be invalid, so those guards are
        // omitted (see judgement calls in the report).
        let shell_type = shell.get("type").to_i32();
        let shell_color = if shell_type == 1 {
            Color::from_rgba(0.05, 0.1, 1.0, 1.0) // Blue for AP
        } else {
            Color::from_rgba(1.0, 0.2, 0.05, 1.0) // Orange for HE
        };

        // Fire shell through GPU renderer (it manages its own IDs internally)
        let mut gpu_id: i32 = -1;
        if let Some(gpu) = self.gpu_renderer.as_mut() {
            let drag = shell.get("drag").to_f64();
            let size = shell.get("size").to_f64();
            gpu_id = gpu
                .call(
                    "fire_shell",
                    &[
                        pos.to_variant(),
                        vel.to_variant(),
                        drag.to_variant(),
                        size.to_variant(),
                        shell_type.to_variant(),
                        shell_color.to_variant(),
                    ],
                )
                .to_i32();
        }

        // Still track in projectiles array for trail emission and ID mapping
        if id >= self.projectiles.len() as i32 {
            let np2 = Self::next_pow_of_2(id + 1);
            self.projectiles.resize(np2 as usize, &Variant::nil());
        }

        // `initialize` is private but is also a `#[func]`; call it dynamically
        // (see the note on `fire_bullet_client_core` above).
        match owner {
            Some(owner) => {
                bullet.call(
                    "initialize",
                    &[pos.to_variant(), vel.to_variant(), t.to_variant(), shell.to_variant(), owner.to_variant(), VarArray::new().to_variant()],
                );
            }
            None => {
                let placeholder = self.to_gd().upcast::<Object>();
                bullet.call(
                    "initialize",
                    &[pos.to_variant(), vel.to_variant(), t.to_variant(), shell.to_variant(), placeholder.to_variant(), VarArray::new().to_variant()],
                );
                bullet.bind_mut().owner = None;
            }
        }
        bullet.bind_mut().frame_count = gpu_id; // Store GPU renderer ID in frame_count for mapping

        self.projectiles.set(id as usize, &bullet.to_variant());

        if muzzle_blast {
            // Call HitEffects.muzzle_blast_effect - this is a GDScript autoload
            if self.base().has_node("/root/HitEffects") {
                if let Some(mut hit_effects) = self.base().get_node_or_null("/root/HitEffects") {
                    let caliber = shell.get("caliber").to_f64();
                    hit_effects.call(
                        "muzzle_blast_effect",
                        &[pos.to_variant(), basis.to_variant(), caliber.to_variant()],
                    );
                }
            }

            // Sound-effect-on-fire code is commented out in the C++ source;
            // not ported (dead code).
        }
    }

    pub(crate) fn destroy_bullet_rpc_impl(&mut self, id: i32, position: Vector3, hit_result: i32, normal: Vector3) {
        // --- Replay recording ---------------------------------------------------
        // Read owner/params BEFORE the slot is cleared so we can identify the shell.
        // hit_result uses the C++ RPC enum:
        //   PENETRATION=0, RICOCHET=1, OVERPENETRATION=2, SHATTER=3,
        //   NOHIT=4, CITADEL=5, WATER=6
        if self.base().has_node("/root/ReplayRecorder") {
            if let Some(bullet_var) = self.projectiles.get(id as usize) {
                // `!bullet_var.is_nil()` == C++ `bullet_var.get_type() != Variant::NIL`;
                // `try_to` failing == C++ `!bullet.is_valid()` (wrong dynamic type).
                if !bullet_var.is_nil() {
                    if let Ok(bullet) = bullet_var.try_to::<Gd<ProjectileData>>() {
                        if let Some(mut rr) = self.base().get_node_or_null("/root/ReplayRecorder") {
                            let owner_obj = bullet.bind().owner.clone();
                            let uid = bullet.bind().shell_uid;
                            // victim = null → stored as 255 in the replay file (no target ship).
                            let no_victim: Option<Gd<Object>> = None;
                            rr.call(
                                "record_shell_hit",
                                &[
                                    owner_obj.to_variant(),
                                    no_victim.to_variant(),
                                    hit_result.to_variant(),
                                    position.to_variant(),
                                    (uid as i64).to_variant(),
                                ],
                            );
                        }
                    }
                }
            }
        }
        // ------------------------------------------------------------------------

        self.projectiles.set(id as usize, &Variant::nil());
        self.shell_grid_remove(id);
        self.ids_reuse.push(&id.to_variant());

        // Send destroy message through TcpThreadPool
        if let Some(tcp_pool) = self.tcp_thread_pool.as_mut() {
            tcp_pool.call(
                "send_destroy_shell",
                &[id.to_variant(), position.to_variant(), hit_result.to_variant(), normal.to_variant()],
            );
        } else {
            godot_warn!("TcpThreadPool not found, cannot send destroy_shell message");
        }
    }

    pub(crate) fn destroy_bullet_rpc2_impl(&mut self, id: i32, pos: Vector3, hit_result: i32, normal: Vector3) {
        let Some(bullet_var) = self.projectiles.get(id as usize) else {
            godot_print!("bullet is null: {}", id);
            return;
        };
        if bullet_var.is_nil() {
            godot_print!("bullet is null: {}", id);
            return;
        }
        let Ok(mut bullet) = bullet_var.try_to::<Gd<ProjectileData>>() else {
            godot_print!("bullet is null: {}", id);
            return;
        };

        let mut radius = 1.0_f64;
        if let Some(params) = bullet.bind().params.clone() {
            radius = params.get("size").to_f64();
        }

        // Free the GPU emitter if one was allocated
        let emitter_id = bullet.bind().emitter_id;
        if emitter_id >= 0 {
            if let Some(cps) = self.compute_particle_system.as_mut() {
                cps.call("free_emitter", &[emitter_id.to_variant()]);
                bullet.bind_mut().emitter_id = -1;
            }
        }

        // Destroy in GPU renderer
        let gpu_id = bullet.bind().frame_count; // GPU renderer ID was stored here
        if let Some(gpu) = self.gpu_renderer.as_mut() {
            gpu.call("destroy_shell", &[gpu_id.to_variant()]);
        }

        self.projectiles.set(id as usize, &Variant::nil());

        // Create hit effects
        if self.base().has_node("/root/HitEffects") {
            if let Some(mut hit_effects) = self.base().get_node_or_null("/root/HitEffects") {
                match hit_result {
                    WATER => {
                        hit_effects.call("splash_effect", &[pos.to_variant(), radius.to_variant()]);
                    }
                    PENETRATION => {
                        hit_effects.call(
                            "he_explosion_effect",
                            &[pos.to_variant(), (radius * 0.8).to_variant(), normal.to_variant()],
                        );
                        hit_effects.call(
                            "sparks_effect",
                            &[pos.to_variant(), (radius * 0.5).to_variant(), normal.to_variant()],
                        );
                        if let Some(sem) = self.sound_effect_manager.as_mut() {
                            let volume = (radius / 8.0 / 10.0) as f32;
                            let pitch = (1.3 / (radius * 0.4)) as f32;
                            sem.call(
                                "play_explosion",
                                &[pos.to_variant(), pitch.to_variant(), volume.to_variant()],
                            );
                        }
                    }
                    CITADEL => {
                        hit_effects.call(
                            "he_explosion_effect",
                            &[pos.to_variant(), (radius * 1.2).to_variant(), normal.to_variant()],
                        );
                        hit_effects.call(
                            "sparks_effect",
                            &[pos.to_variant(), (radius * 0.6).to_variant(), normal.to_variant()],
                        );
                        if let Some(sem) = self.sound_effect_manager.as_mut() {
                            let volume = (radius / 4.0 / 10.0) as f32;
                            let pitch = (1.0 / (radius * 0.45)) as f32;
                            sem.call(
                                "play_explosion",
                                &[pos.to_variant(), pitch.to_variant(), volume.to_variant()],
                            );
                        }
                    }
                    RICOCHET | OVERPENETRATION | SHATTER => {
                        hit_effects.call(
                            "sparks_effect",
                            &[pos.to_variant(), (radius * 0.5).to_variant(), normal.to_variant()],
                        );
                        if let Some(sem) = self.sound_effect_manager.as_mut() {
                            let volume = ((0.1 + radius / 15.0) / 15.0) as f32;
                            let pitch = (2.0 / (radius * 0.4)) as f32;
                            sem.call(
                                "play_explosion",
                                &[pos.to_variant(), pitch.to_variant(), volume.to_variant()],
                            );
                        }
                    }
                    NOHIT => {
                        // No explosion for NOHIT
                    }
                    _ => {}
                }
            }
        } else {
            godot_warn!("HitEffects not found, cannot create hit effects");
        }
    }

    pub(crate) fn destroy_bullet_rpc3_impl(&mut self, data: PackedByteArray) {
        if data.len() < 17 {
            godot_print!("Invalid data size for destroy_bullet_rpc3");
            return;
        }

        let mut stream = StreamPeerBuffer::new_gd();
        stream.set_data_array(&data);

        let id = stream.get_32();
        let px = stream.get_float();
        let py = stream.get_float();
        let pz = stream.get_float();
        let pos = Vector3::new(px, py, pz);
        let hit_result = stream.get_8() as i32;
        let nx = stream.get_float();
        let ny = stream.get_float();
        let nz = stream.get_float();
        let normal = Vector3::new(nx, ny, nz);

        self.destroy_bullet_rpc2_impl(id, pos, hit_result, normal);
    }

    pub(crate) fn create_ricochet_rpc_impl(&mut self, original_shell_id: i32, new_shell_id: i32,
                                           ricochet_position: Vector3, ricochet_velocity: Vector3, ricochet_time: f64) {
        let Some(original_var) = self.projectiles.get(original_shell_id as usize) else {
            godot_print!("Warning: Could not find original shell with ID {} for ricochet", original_shell_id);
            return;
        };
        // `is_nil()` == C++ `p_var.get_type() == Variant::NIL`; `try_to` failing
        // == C++ `!p.is_valid()` (wrong dynamic type).
        if original_var.is_nil() {
            godot_print!("Warning: Could not find original shell with ID {} for ricochet", original_shell_id);
            return;
        }
        let Ok(original) = original_var.try_to::<Gd<ProjectileData>>() else {
            godot_print!("Warning: Could not find original shell with ID {} for ricochet", original_shell_id);
            return;
        };
        // Every live `ProjectileData` was written by `fire_bullet_impl`/
        // `fire_bullet_client_core`, both of which call `initialize()` with a
        // mandatory (never-null) shell resource, so `params` is always `Some`
        // here. C++'s `p->get_params()` has no corresponding validity check
        // either — it is passed straight into `fire_bullet_client`.
        let shell_params = original.bind().params.clone()
            .expect("live ProjectileData always has params set by initialize()");

        self.fire_bullet_client_core(
            ricochet_position,
            ricochet_velocity,
            ricochet_time,
            new_shell_id,
            &shell_params,
            None,
            false,
            Basis::IDENTITY,
        );
    }

    pub(crate) fn create_ricochet_rpc2_impl(&mut self, data: PackedByteArray) {
        if data.len() < 32 {
            godot_print!("Warning: Invalid ricochet data size");
            return;
        }

        let mut stream = StreamPeerBuffer::new_gd();
        stream.set_data_array(&data);

        let original_shell_id = stream.get_32();
        let new_shell_id = stream.get_32();
        let px = stream.get_float();
        let py = stream.get_float();
        let pz = stream.get_float();
        let ricochet_position = Vector3::new(px, py, pz);
        let vx = stream.get_float();
        let vy = stream.get_float();
        let vz = stream.get_float();
        let ricochet_velocity = Vector3::new(vx, vy, vz);
        let ricochet_time = stream.get_double();

        self.create_ricochet_rpc_impl(original_shell_id, new_shell_id, ricochet_position, ricochet_velocity, ricochet_time);
    }

    pub(crate) fn apply_fire_damage_impl(&mut self, projectile: &Gd<ProjectileData>, ship: Option<Gd<Object>>, hit_position: Vector3) {
        // C++: `if (!projectile.is_valid() || ship == nullptr) return;` —
        // `projectile: &Gd<ProjectileData>` and `ship: Gd<Object>` can never be
        // null/invalid in Rust, so this guard is unconditionally false and is
        // omitted.
        let Some(params) = projectile.bind().params.clone() else {
            return;
        };

        let fire_buildup = params.get("fire_buildup").to_f64();
        if fire_buildup <= 0.0 {
            return;
        }

        // Get fire manager from ship
        // C++ guards `if (ship == nullptr) return;`
        let Some(ship) = ship else {
            return;
        };
        let fire_manager_var = ship.get("fire_manager");
        let Ok(fire_manager) = fire_manager_var.try_to::<Gd<Object>>() else {
            return;
        };

        // Find closest fire. `fires` is a GDScript `Array[Fire]`, so it must be
        // read as AnyArray — see VariantCast::to_any_array.
        let fires = fire_manager.get("fires").to_any_array();
        let mut closest_fire: Option<Gd<Object>> = None;
        let mut closest_fire_dist = 1e9_f64;

        for i in 0..fires.len() {
            let Ok(f) = fires.at(i).try_to::<Gd<Object>>() else {
                continue;
            };
            let fire_pos = f.get("global_position").to::<Vector3>();
            let dist = fire_pos.distance_squared_to(hit_position) as f64;
            if dist < closest_fire_dist {
                closest_fire_dist = dist;
                closest_fire = Some(f);
            }
        }

        if let Some(mut closest_fire) = closest_fire {
            let owner = projectile.bind().owner.clone();
            closest_fire.call("_apply_build_up", &[fire_buildup.to_variant(), owner.to_variant()]);
        }
    }

    pub(crate) fn print_armor_debug_impl(&self, armor_result: VarDictionary, ship: Option<Gd<Object>>) {
        // C++: `if (ship == nullptr) return;` — `ship: Gd<Object>` can never be
        // null in Rust, so this guard is unconditionally false and is omitted.
        let mut ship_class = "Unknown".to_string();
        let Some(ship) = ship else {
            return;
        };
        if let Ok(health_controller) = ship.get("health_controller").try_to::<Gd<Object>>() {
            let max_hp = health_controller.get("max_hp").to_f64();
            ship_class = if max_hp > 40000.0 {
                "Battleship".to_string()
            } else if max_hp > 15000.0 {
                "Cruiser".to_string()
            } else {
                "Destroyer".to_string()
            };
        }

        let result_type = armor_result.get("result_type").map(|v| v.to_i32()).unwrap_or(0);
        let result_name = match result_type {
            PENETRATION => "PENETRATION",
            RICOCHET => "RICOCHET",
            OVERPENETRATION => "OVERPENETRATION",
            SHATTER => "SHATTER",
            NOHIT => "NOHIT",
            CITADEL => "CITADEL",
            WATER => "WATER",
            _ => "UNKNOWN",
        };

        // NOTE (suspected C++ bug, preserved verbatim): Godot's `String::replace`
        // replaces *all* occurrences of the pattern. The first `.replace("%s",
        // result_name)` therefore consumes *both* "%s" placeholders, and the
        // second `.replace("%s", ship_class)` is a no-op — `ship_class` never
        // actually appears in the printed message.
        let msg = "Armor Debug: %s vs %s".replace("%s", result_name).replace("%s", &ship_class);
        godot_print!("{}", msg);
    }

    pub(crate) fn validate_penetration_formula_impl(&self) {
        godot_print!("=== Penetration Formula Validation ===");

        // Create test shell params using Resource
        // Note: In real usage, these would be ShellParams resources

        // Test 380mm BB shell
        let bb_caliber = 380.0_f64;
        let bb_mass = 800.0_f64;
        let bb_velocity = 820.0_f64;

        let bb_penetration =
            0.55664 * bb_mass.powf(0.55) * bb_velocity.powf(1.1) / bb_caliber.powf(0.65);

        godot_print!("380mm AP shell at 820 m/s: {}mm penetration", bb_penetration);
        godot_print!("Expected: ~700-800mm for battleship shells");

        // Test 203mm CA shell
        let ca_caliber = 203.0_f64;
        let ca_mass = 118.0_f64;
        let ca_velocity = 760.0_f64;

        let ca_penetration =
            0.55664 * ca_mass.powf(0.55) * ca_velocity.powf(1.1) / ca_caliber.powf(0.65);

        godot_print!("203mm AP shell at 760 m/s: {}mm penetration", ca_penetration);
        godot_print!("Expected: ~200-300mm for cruiser shells");

        godot_print!("=== End of Penetration Formula Validation ===");
    }
}
