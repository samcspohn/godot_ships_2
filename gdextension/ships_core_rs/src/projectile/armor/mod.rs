use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::{CollisionObject3D, Node, PhysicsDirectSpaceState3D, PhysicsRayQueryParameters3D, Resource};

use crate::nav::map::NavigationMap;
use crate::projectile::data::ProjectileData;

mod travel;

/// `Math::PI` in the C++ is a double constant; this mirrors it exactly (not the
/// float `f32::consts::PI`).
const DEG_TO_RAD: f64 = std::f64::consts::PI / 180.0;

/// Mirrors the C++ anonymous-namespace `clampd(v, lo, hi) = std::max(lo, std::min(v, hi))`.
fn clampd(v: f64, lo: f64, hi: f64) -> f64 {
    lo.max(v.min(hi))
}

/// `RaycastCache::obb_excludes` is stored as an untyped `VarArray` (matching the
/// C++ `Array`), but `PhysicsRayQueryParameters3D::set_exclude` in this gdext
/// version is statically typed to `Array<Rid>`. Bridges the two; no semantic
/// change, just an engine-binding type-strictness difference.
fn variant_array_to_rid_array(values: &VarArray) -> Array<Rid> {
    let mut out: Array<Rid> = Array::new();
    for v in values.iter_shared() {
        out.push(v.to::<Rid>());
    }
    out
}

pub const DE_MARRE_K: f64 = 0.06;
pub const MIN_VELOCITY: f64 = 10.0;
pub const DEFLECTION_ALPHA: f64 = 0.35;
pub const OBLIQUITY_ALPHA: f64 = 1.0;
pub const DEFLECTION_GAMMA: f64 = 3.0;
pub const K_NOSE_APC: f64 = 0.06;
pub const K_NOSE_COMMON: f64 = 0.10;
pub const TD_MOD_SCALE: f64 = 0.3;
pub const TD_MOD_ONSET: f64 = 0.5;
pub const TD_MOD_MAX: f64 = 1.5;
pub const TD_ENGAGE_REF: f64 = 0.5;
pub const TD_ENGAGE_POWER: f64 = 1.5;
pub const DEFLECTION_RICOCHET_THRESHOLD: f64 = 1.15;
pub const WATER_DRAG: f64 = 2500.0;
pub const EPSILON: f64 = 0.0002;
pub const OBB_COLLISION_LAYER: u32 = 1 << 4;

pub mod hit_result {
    pub const PENETRATION: i32 = 0;
    pub const PARTIAL_PEN: i32 = 1;
    pub const RICOCHET: i32 = 2;
    pub const OVERPENETRATION: i32 = 3;
    pub const SHATTER: i32 = 4;
    pub const CITADEL: i32 = 5;
    pub const CITADEL_OVERPEN: i32 = 6;
    pub const WATER: i32 = 7;
    pub const TERRAIN: i32 = 8;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArmorResult {
    Ricochet = 0,
    Overpen = 1,
    Pen = 2,
    PartialPen = 3,
    Shatter = 4,
}

#[derive(Clone, Debug)]
pub struct ArmorHitResult {
    pub hit: bool,
    pub result_type: i32,
    pub explosion_position: Vector3,
    pub armor_part: Option<Gd<Object>>,
    pub velocity: Vector3,
    pub ship: Option<Gd<Object>>,
    pub collision_normal: Vector3,
    pub shell_integrity: f64,
    pub overmatch_first_armor: bool,
    /// Armor-sim log payload. Only populated when process_travel is called with
    /// log_armor = true (i.e. while a match recording is active), so the normal
    /// path pays nothing for the Dictionary/Array churn.
    pub log_valid: bool,
    pub log_steps: VarArray,
    pub log_final_pos: Vector3,
}

impl Default for ArmorHitResult {
    fn default() -> Self {
        Self {
            hit: false,
            result_type: 0,
            explosion_position: Vector3::ZERO,
            armor_part: None,
            velocity: Vector3::ZERO,
            ship: None,
            collision_normal: Vector3::ZERO,
            shell_integrity: 1.0,
            overmatch_first_armor: false,
            log_valid: false,
            log_steps: VarArray::new(),
            log_final_pos: Vector3::ZERO,
        }
    }
}

#[derive(Default)]
pub struct RaycastCache {
    pub terrain_ray: Option<Gd<PhysicsRayQueryParameters3D>>,
    pub obb_ray: Option<Gd<PhysicsRayQueryParameters3D>>,
    pub water_ray: Option<Gd<PhysicsRayQueryParameters3D>>,
    pub obb_excludes: VarArray,
}

#[derive(Clone, Debug, Default)]
pub struct ShellState {
    pub position: Vector3,
    pub end_position: Vector3,
    pub velocity: Vector3,
    pub params: Option<Gd<Resource>>,
    pub fuze: f64,
    pub pen: f64,
    pub integrity: f64,
}

#[derive(Clone, Copy, Debug)]
pub struct ArmorEval {
    pub result: ArmorResult,
    pub pen_ratio: f64,
    pub deflection_mult: f64,
    pub energy_loss_fraction: f64,
    pub physics_armor: f64,
}

impl Default for ArmorEval {
    fn default() -> Self {
        Self { result: ArmorResult::Shatter, pen_ratio: 0.0, deflection_mult: 1.0,
               energy_loss_fraction: 0.0, physics_armor: 0.0 }
    }
}

/// Plain C++ class, not a Godot class — no bindings, called only from
/// ProjectileManager.
pub struct NativeArmorInteraction;

impl ShellState {
    pub fn calc_end_position(&mut self) {
        let mut fuze_left = if let Some(p) = &self.params {
            p.get("fuze_delay").to_f64() - self.fuze
        } else {
            0.0
        };
        if self.fuze < 0.0 {
            fuze_left = 1.0;
        }
        self.end_position = self.position + self.velocity * (fuze_left as f32);
    }

    pub fn get_speed(&self) -> f64 {
        self.velocity.length() as f64
    }
}

impl NativeArmorInteraction {
    pub fn make_result(
        result_type: i32, explosion_position: Vector3, armor_part: Option<Gd<Object>>,
        velocity: Vector3, ship: Option<Gd<Object>>, collision_normal: Vector3,
        shell_integrity: f64,
    ) -> ArmorHitResult {
        ArmorHitResult {
            hit: true,
            result_type,
            explosion_position,
            armor_part,
            velocity,
            ship,
            collision_normal,
            shell_integrity,
            ..Default::default()
        }
    }

    pub fn calculate_de_marre_penetration(mass_kg: f64, velocity_ms: f64, caliber_mm: f64) -> f64 {
        if velocity_ms < 1.0 {
            return 0.0;
        }
        DE_MARRE_K * mass_kg.powf(0.55) * velocity_ms.powf(1.43) / caliber_mm.powf(0.65)
    }

    pub fn calculate_effective_thickness(thickness_mm: f64, impact_angle_rad: f64) -> f64 {
        let cos_angle = impact_angle_rad.cos().max(0.05);
        thickness_mm / cos_angle
    }

    pub fn calculate_exit_velocity(entry_speed: f64, pen_capability_mm: f64, effective_armor_mm: f64) -> f64 {
        if pen_capability_mm <= 0.0 {
            return 0.0;
        }
        let pen_ratio = effective_armor_mm / pen_capability_mm;
        if pen_ratio >= 1.0 {
            return 0.0;
        }
        entry_speed * (1.0 - pen_ratio)
    }

    pub fn calculate_shell_integrity(pen_ratio: f64, current_integrity: f64) -> f64 {
        clampd(current_integrity - pen_ratio * 0.4, 0.1, 1.0)
    }

    pub fn calculate_deflected_direction(entry_dir: Vector3, armor_normal: Vector3, pen_ratio: f64) -> Vector3 {
        let deflection_amount = DEFLECTION_ALPHA * pen_ratio * 0.5;
        slerp_godot_cpp(entry_dir, -armor_normal, deflection_amount as f32).normalized()
    }

    pub fn calculate_ricochet_velocity(velocity: Vector3, normal: Vector3, energy_loss_fraction: f64) -> Vector3 {
        let n = normal.normalized();
        // dot() runs in f32 and is widened here, matching `double v_normal_mag = velocity.dot(n);`.
        let v_normal_mag = velocity.dot(n) as f64;
        // Narrowed back to f32 at the Vector3 scale, matching `n * v_normal_mag` (real_t operand).
        let v_normal = n * (v_normal_mag as f32);
        let v_tangential = velocity - v_normal;
        v_tangential + (-v_normal * ((1.0 - energy_loss_fraction) as f32))
    }

    pub fn calculate_impact_angle(velocity: Vector3, surface_normal: Vector3) -> f64 {
        // dot() and abs() both run in f32 (std::abs(float) picks the float overload);
        // only the assignment to `double cos_angle` widens.
        let cos_angle = velocity.dot(surface_normal).abs() as f64;
        clampd(cos_angle, 0.0, 1.0).acos()
    }

    pub fn get_k_nose(params: &Option<Gd<Resource>>) -> f64 {
        if let Some(p) = params {
            if p.get("type").to_i32() == 0 {
                return K_NOSE_COMMON;
            }
        }
        K_NOSE_APC
    }

    pub fn evaluate_armor_interaction(
        shell: &ShellState, params: &Option<Gd<Resource>>, impact_angle: f64,
        armor_mm: f64, e_armor: f64,
    ) -> ArmorEval {
        let mut eval = ArmorEval::default();
        let caliber = params.as_ref().map(|p| p.get("caliber").to_f64()).unwrap_or(1.0);
        let k_nose = Self::get_k_nose(params);
        let cos_a = impact_angle.cos().max(0.05);
        let tan_a = clampd(impact_angle, 0.0, 89.0 * DEG_TO_RAD).tan();
        // `geometric` is computed and never used in the C++ source either --
        // dead code, kept for bit-exact transliteration.
        let _geometric = (1.0f64 / cos_a).powf(OBLIQUITY_ALPHA);
        let td_ratio = armor_mm / caliber.max(1.0);
        let engagement = clampd(td_ratio / TD_ENGAGE_REF, 0.0, 1.0).powf(TD_ENGAGE_POWER);
        let f_td = 1.0 + TD_MOD_SCALE * clampd(td_ratio - TD_MOD_ONSET, 0.0, TD_MOD_MAX);
        let raw_deflection = k_nose * tan_a.powf(DEFLECTION_GAMMA) * f_td;
        let deflection = 1.0 + engagement * raw_deflection;

        eval.deflection_mult = deflection;
        eval.physics_armor = e_armor * deflection;
        let pen_ratio = shell.pen / eval.physics_armor.max(0.1);

        if pen_ratio >= 1.0 {
            eval.result = ArmorResult::Pen;
            eval.pen_ratio = e_armor / shell.pen.max(0.1);
            return eval;
        }

        let would_pen_without_deflection = shell.pen >= e_armor;
        let is_deflection_dominated = deflection >= DEFLECTION_RICOCHET_THRESHOLD;
        if is_deflection_dominated && (would_pen_without_deflection || impact_angle > 55.0 * DEG_TO_RAD) {
            eval.result = ArmorResult::Ricochet;
            eval.pen_ratio = pen_ratio;
            eval.energy_loss_fraction =
                clampd(shell.pen * impact_angle.cos() / eval.physics_armor.max(0.1), 0.0, 0.8);
            return eval;
        }

        eval.result = ArmorResult::Shatter;
        eval.pen_ratio = shell.pen / e_armor.max(0.1);
        eval
    }

    pub fn same_object(a: &Option<Gd<Object>>, b: &Option<Gd<Object>>) -> bool {
        match (a, b) {
            (Some(a), Some(b)) => a.instance_id() == b.instance_id(),
            _ => false,
        }
    }

    pub fn object_array_contains(array: &VarArray, object: &Option<Gd<Object>>) -> bool {
        for i in 0..array.len() {
            let elem = array.at(i).try_to::<Gd<Object>>().ok();
            if Self::same_object(&elem, object) {
                return true;
            }
        }
        false
    }

    pub fn is_owner_or_excluded(ship: &Option<Gd<Object>>, owner: &Option<Gd<Object>>, exclude: &VarArray) -> bool {
        ship.is_none() || Self::same_object(ship, owner) || Self::object_array_contains(exclude, ship)
    }

    pub fn build_obb_excludes(projectile: &Gd<ProjectileData>, precision_physics_world: Option<&Gd<Node>>) -> VarArray {
        let mut obb_rids = VarArray::new();
        let Some(precision_physics_world) = precision_physics_world else {
            return obb_rids;
        };

        let append_ship_obb = |ship: &Option<Gd<Object>>, obb_rids: &mut VarArray| {
            let Some(ship) = ship else { return; };
            let mut pw = precision_physics_world.clone();
            let entry: VarDictionary = pw
                .call("get_ship_entry", &[ship.to_variant()])
                .try_to()
                .unwrap_or_default();
            if entry.is_empty() || !entry.contains_key("obb_body") {
                return;
            }
            let obb_body = entry.get("obb_body").unwrap().try_to::<Gd<CollisionObject3D>>().ok();
            if let Some(obb_body) = obb_body {
                obb_rids.push(&obb_body.get_rid().to_variant());
            }
        };

        let owner = projectile.bind().owner.clone();
        append_ship_obb(&owner, &mut obb_rids);
        let exclude = projectile.bind().exclude.clone();
        for i in 0..exclude.len() {
            let ship = exclude.at(i).try_to::<Gd<Object>>().ok();
            append_ship_obb(&ship, &mut obb_rids);
        }
        obb_rids
    }

    pub fn configure_raycast_cache(projectile: &Gd<ProjectileData>, precision_physics_world: Option<&Gd<Node>>, cache: &mut RaycastCache) {
        if cache.terrain_ray.is_none() {
            let mut ray = PhysicsRayQueryParameters3D::new_gd();
            ray.set_hit_back_faces(true);
            ray.set_hit_from_inside(false);
            ray.set_collision_mask(1);
            cache.terrain_ray = Some(ray);
        }
        if cache.obb_ray.is_none() {
            let mut ray = PhysicsRayQueryParameters3D::new_gd();
            ray.set_hit_back_faces(true);
            ray.set_hit_from_inside(true);
            ray.set_collision_mask(OBB_COLLISION_LAYER);
            cache.obb_ray = Some(ray);
        }
        if cache.water_ray.is_none() {
            let mut ray = PhysicsRayQueryParameters3D::new_gd();
            ray.set_hit_back_faces(true);
            ray.set_hit_from_inside(false);
            ray.set_collision_mask(1 << 3);
            cache.water_ray = Some(ray);
        }

        cache.obb_excludes = Self::build_obb_excludes(projectile, precision_physics_world);
        let rid_excludes = variant_array_to_rid_array(&cache.obb_excludes);
        cache.obb_ray.as_mut().unwrap().set_exclude(&rid_excludes);
    }

    pub fn duplicate_shell_params_with_drag(params: &Option<Gd<Resource>>, drag_multiplier: f64) -> Option<Gd<Resource>> {
        let params = params.as_ref()?;
        let mut dup = params.duplicate_ex().deep(true).done()?;
        let drag = dup.get("drag").to_f64();
        dup.set("drag", &(drag * drag_multiplier).to_variant());
        Some(dup)
    }

    pub fn handle_water_entry(water_hit: Vector3, entry_vel: Vector3, params: &Option<Gd<Resource>>) -> Vector3 {
        let Some(water_params) = Self::duplicate_shell_params_with_drag(params, WATER_DRAG) else {
            return water_hit;
        };
        let fuze_delay = water_params.get("fuze_delay").to_f64();
        crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2::calculate_position_at_time_impl(
            water_hit, entry_vel, fuze_delay, &water_params,
        )
    }

    /// C++ returns a Dictionary and writes the ship through an `Object **out_ship`
    /// out-param; Rust returns both as a tuple.
    pub fn find_valid_obb_hit(
        space_state: Option<&mut Gd<PhysicsDirectSpaceState3D>>,
        obb_ray: &Gd<PhysicsRayQueryParameters3D>,
        precision_physics_world: Option<&Gd<Node>>,
        owner: &Option<Gd<Object>>,
        exclude: &VarArray,
    ) -> (VarDictionary, Option<Gd<Object>>) {
        let (Some(space_state), Some(precision_physics_world)) = (space_state, precision_physics_world) else {
            return (VarDictionary::new(), None);
        };

        let mut ray = obb_ray.clone();
        let mut dynamic_excludes = ray.get_exclude();
        let mut pw = precision_physics_world.clone();

        for _ in 0..16 {
            let hit = space_state.intersect_ray(&ray);
            if hit.is_empty() {
                return (VarDictionary::new(), None);
            }

            let collider = hit.get("collider").unwrap();
            let ship_variant = pw.call("get_ship_from_obb", &[collider]);
            let ship = ship_variant.try_to::<Gd<Object>>().ok();

            if !Self::is_owner_or_excluded(&ship, owner, exclude) {
                return (hit, ship);
            }

            if hit.contains_key("rid") {
                let rid = hit.get("rid").unwrap().to::<Rid>();
                dynamic_excludes.push(rid);
                ray.set_exclude(&dynamic_excludes);
            } else {
                return (VarDictionary::new(), None);
            }
        }
        (VarDictionary::new(), None)
    }

    pub fn should_raycast_terrain(nav_map: &Option<Gd<NavigationMap>>, from: Vector3, to: Vector3) -> bool {
        let Some(nav_map) = nav_map else { return true; };
        let nav = nav_map.bind();
        if !nav.is_built() {
            return true;
        }

        let delta = to - from;
        // Each component is widened to f64 BEFORE squaring (`(double)delta.x * delta.x`
        // widens the operand, then the multiply runs in double), not squared in f32
        // then widened.
        let horizontal_len = ((delta.x as f64) * (delta.x as f64) + (delta.z as f64) * (delta.z as f64)).sqrt();
        let cell_size = nav.get_cell_size_value();
        let margin = 2.0f64.max(cell_size as f64 * 0.5);
        let terrain_step = 5.0f64.max(cell_size as f64 * 0.5);

        let start_sdf = nav.get_distance_impl(from.x, from.z);
        if (start_sdf as f64) > horizontal_len + margin {
            return false;
        }

        let steps: i32 = if horizontal_len > 0.001 {
            2.max((horizontal_len / terrain_step).ceil() as i32)
        } else {
            1
        };

        for i in 1..=steps {
            let alpha = i as f64 / steps as f64;
            // Vector3 * double narrows alpha to f32 at the multiply (real_t operand).
            let pos = from + delta * (alpha as f32);
            let sdf = nav.get_distance_impl(pos.x, pos.z);
            if (sdf as f64) > margin {
                continue;
            }

            let terrain_height = nav.get_terrain_height_impl(pos.x, pos.z);
            if terrain_height > 0.001f32 && (pos.y as f64) <= (terrain_height as f64) + margin {
                return true;
            }
        }
        false
    }

    pub fn is_citadel(part: &Option<Gd<Object>>) -> bool {
        match part {
            Some(p) => p.get("is_citadel").to_bool(),
            None => false,
        }
    }

    pub fn armor_type(part: &Option<Gd<Object>>) -> i32 {
        match part {
            Some(p) => p.get("type").to_i32(),
            None => -1,
        }
    }

    pub fn get_armor(armor_part: &Option<Gd<Object>>, face_index: i32) -> f64 {
        let Some(armor_part) = armor_part else { return 0.0; };
        let mut p = armor_part.clone();
        p.call("get_armor", &[face_index.to_variant()]).to_f64()
    }

    /// Returns a `hit_result::*` value.
    pub fn resolve_hit_result(armor_result: ArmorResult, final_part: &Option<Gd<Object>>,
                              hit_cit: bool, over_pen: bool) -> i32 {
        if armor_result == ArmorResult::Shatter {
            return hit_result::SHATTER;
        }
        if armor_result == ArmorResult::PartialPen {
            return hit_result::PARTIAL_PEN;
        }

        let in_citadel = final_part.is_some() && Self::armor_type(final_part) == 1;
        if in_citadel {
            return hit_result::CITADEL;
        }
        if hit_cit && over_pen {
            return hit_result::CITADEL_OVERPEN;
        }
        if final_part.is_some() {
            return hit_result::PENETRATION;
        }
        if over_pen {
            return hit_result::OVERPENETRATION;
        }
        if armor_result == ArmorResult::Ricochet {
            return hit_result::RICOCHET;
        }
        hit_result::OVERPENETRATION
    }
}

/// godot-cpp's `Vector3::slerp`, spelled out.
///
/// gdext's `slerp` internally calls its own `angle_to`, which delegates to
/// glam's `angle_between` — a different formula from godot-cpp's
/// `atan2(cross.length(), dot)`, differing at f32 epsilon. Since
/// NativeArmorInteraction has no Godot binding, the differential harness cannot
/// reach this path, so the divergence is corrected here rather than discovered.
fn slerp_godot_cpp(from: Vector3, to: Vector3, weight: f32) -> Vector3 {
    let start_length_sq = from.length_squared();
    let end_length_sq = to.length_squared();
    if start_length_sq == 0.0 || end_length_sq == 0.0 {
        // Zero-length vectors have no angle; lerp is the best available.
        return from.lerp(to, weight);
    }
    let mut axis = from.cross(to);
    let axis_length_sq = axis.length_squared();
    if axis_length_sq == 0.0 {
        // Collinear vectors have no rotation axis; lerp instead.
        return from.lerp(to, weight);
    }
    axis /= axis_length_sq.sqrt();
    let start_length = start_length_sq.sqrt();
    let result_length = start_length + (end_length_sq.sqrt() - start_length) * weight;
    let angle = from.cross(to).length().atan2(from.dot(to));
    from.rotated(axis, angle * weight) * (result_length / start_length)
}
