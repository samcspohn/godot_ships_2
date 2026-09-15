//! The plate walk: one shell through one ship's armour mesh. No Godot objects
//! are touched, so live shells and worker threads baking tables run the same
//! code.

use crate::variant_cast::VariantCast;
use godot::prelude::*;
use godot::classes::Resource;

use super::mesh::{ArmorMesh, Hit, V3};
use super::{
    hit_result, ArmorResult, NativeArmorInteraction, ShellState, DEFLECTION_GAMMA, EPSILON,
    K_NOSE_APC, K_NOSE_COMMON, MIN_VELOCITY, TD_ENGAGE_POWER, TD_ENGAGE_REF, TD_MOD_MAX,
    TD_MOD_ONSET, TD_MOD_SCALE,
};

const DEG_TO_RAD: f64 = std::f64::consts::PI / 180.0;
const MAX_ITERATIONS: i32 = 20;

fn clampd(v: f64, lo: f64, hi: f64) -> f64 {
    lo.max(v.min(hi))
}

/// Everything the walk reads off a ShellParams, read once.
#[derive(Clone, Copy, Debug)]
pub struct ShellSpec {
    pub mass: f64,
    pub caliber: f64,
    pub pen_mod: f64,
    pub fuze_delay: f64,
    pub arming_threshold: f64,
    pub auto_bounce: f64,
    pub overmatch: f64,
    pub is_he: bool,
    pub k_nose: f64,
}

impl ShellSpec {
    pub fn from_params(p: &Gd<Resource>) -> Self {
        let is_he = p.get("type").to_i32() == 0;
        Self {
            mass: p.get("mass").to_f64(),
            caliber: p.get("caliber").to_f64(),
            pen_mod: p.get("penetration_modifier").to_f64(),
            fuze_delay: p.get("fuze_delay").to_f64(),
            arming_threshold: p.get("arming_threshold").to_f64(),
            auto_bounce: p.get("auto_bounce").to_f64(),
            overmatch: p.get("overmatch").to_f64(),
            is_he,
            k_nose: if is_he { K_NOSE_COMMON } else { K_NOSE_APC },
        }
    }
}

/// One plate met, ship-local.
#[derive(Clone, Copy, Debug)]
pub struct StepLog {
    pub result: ArmorResult,
    pub is_citadel: bool,
    pub armor_mm: f64,
    pub effective_mm: f64,
    pub impact_angle: f64,
    pub pen: f64,
    pub integrity: f64,
    pub pos: Vector3,
    pub vel: Vector3,
    pub impact_vel: Vector3,
    pub part: usize,
}

#[derive(Clone, Debug)]
pub struct WalkOut {
    /// A `hit_result::*` code.
    pub damage_result: i32,
    pub first_part: usize,
    pub final_part: Option<usize>,
    pub overmatch_first_armor: bool,
    /// Ship-local, leaving the last plate.
    pub velocity: Vector3,
    pub end_position: Vector3,
    pub integrity: f64,
    pub steps: Vec<StepLog>,
}

/// Walk `spec` from `first` (the plate the shell arrives at, ship-local) with
/// `impact_velocity` (ship-local) until it stops, and classify the outcome.
pub fn walk_plates(
    mesh: &ArmorMesh, spec: &ShellSpec, first: &Hit, impact_velocity: Vector3, fuze: f64,
    hit_water: bool, log: bool,
) -> WalkOut {
    let mut part = first.part;
    let mut face = first.face;
    let mut hit_position: Vector3 = first.pos.to_godot();
    let mut hit_normal: Vector3 = first.normal.to_godot().normalized();

    let mut shell = ShellState {
        position: hit_position,
        end_position: Vector3::ZERO,
        velocity: impact_velocity,
        fuze_delay: spec.fuze_delay,
        fuze,
        pen: 0.0,
        integrity: 1.0,
    };
    shell.calc_end_position();

    let mut out = WalkOut {
        damage_result: hit_result::WATER,
        first_part: part,
        final_part: None,
        overmatch_first_armor: false,
        velocity: impact_velocity,
        end_position: hit_position,
        integrity: 1.0,
        steps: Vec::new(),
    };

    if hit_water && spec.is_he {
        return out;
    }

    if spec.is_he {
        let armor_mm = mesh.thickness(part, face);
        let he_citadel = mesh.is_citadel(part);
        let he_pens = spec.overmatch >= armor_mm;
        out.damage_result = if he_pens {
            if he_citadel { hit_result::CITADEL } else { hit_result::PENETRATION }
        } else {
            hit_result::SHATTER
        };
        if log {
            out.steps.push(StepLog {
                result: if he_pens { ArmorResult::Pen } else { ArmorResult::Shatter },
                is_citadel: he_citadel,
                armor_mm,
                effective_mm: armor_mm,
                impact_angle: NativeArmorInteraction::calculate_impact_angle(impact_velocity.normalized(), hit_normal),
                pen: spec.overmatch,
                integrity: 1.0,
                pos: hit_position,
                vel: impact_velocity,
                impact_vel: impact_velocity,
                part,
            });
        }
        return out;
    }

    let mut result = ArmorResult::Overpen;
    let mut hit_cit = false;
    let mut over_pen = false;
    let mut iteration: i32 = 0;
    let mut offset = Vector3::ZERO;

    while shell.fuze <= spec.fuze_delay && result != ArmorResult::Shatter && iteration < MAX_ITERATIONS {
        iteration += 1;
        let armor_mm = mesh.thickness(part, face);
        let speed = shell.get_speed();
        let impact_angle = NativeArmorInteraction::calculate_impact_angle(shell.velocity.normalized(), hit_normal);
        let e_armor = NativeArmorInteraction::calculate_effective_thickness(armor_mm, impact_angle);
        shell.pen = NativeArmorInteraction::calculate_de_marre_penetration(spec.mass, speed, spec.caliber) * spec.pen_mod;
        shell.position = hit_position + offset;
        offset = Vector3::ZERO;
        let log_impact_vel = shell.velocity;
        let is_cit = mesh.is_citadel(part);

        if armor_mm <= spec.overmatch {
            if is_cit {
                hit_cit = true;
            }
            result = ArmorResult::Overpen;
            over_pen = true;
            if iteration == 1 {
                out.overmatch_first_armor = true;
            }
            let pen_ratio = e_armor / shell.pen.max(1.0);
            shell.velocity *= (1.0 - pen_ratio) as f32;
            shell.integrity = NativeArmorInteraction::calculate_shell_integrity(pen_ratio, shell.integrity);
            if shell.velocity.length_squared() > 0.0 {
                offset += shell.velocity.normalized() * (EPSILON as f32);
            }
            if shell.fuze < 0.0 && e_armor >= spec.arming_threshold {
                shell.fuze = 0.0;
            }
        } else if impact_angle >= spec.auto_bounce {
            result = ArmorResult::Ricochet;
            let cos_a = impact_angle.cos().max(0.05);
            let tan_a = clampd(impact_angle, 0.0, 89.0 * DEG_TO_RAD).tan();
            let td_ratio = armor_mm / spec.caliber.max(1.0);
            let engagement = clampd(td_ratio / TD_ENGAGE_REF, 0.0, 1.0).powf(TD_ENGAGE_POWER);
            let f_td = 1.0 + TD_MOD_SCALE * clampd(td_ratio - TD_MOD_ONSET, 0.0, TD_MOD_MAX);
            let deflection_mult = 1.0 + engagement * spec.k_nose * tan_a.powf(DEFLECTION_GAMMA) * f_td;
            let physics_armor = e_armor * deflection_mult;
            let energy_loss = clampd(shell.pen * cos_a / physics_armor.max(0.1), 0.0, 0.8);
            shell.velocity = NativeArmorInteraction::calculate_ricochet_velocity(shell.velocity, hit_normal, energy_loss);
            offset += hit_normal * (EPSILON as f32);
            if shell.fuze < 0.0 && impact_angle > 70.0 * DEG_TO_RAD {
                shell.fuze = 0.0;
            }
        } else {
            let interaction = NativeArmorInteraction::evaluate_armor_interaction(&shell, spec, impact_angle, armor_mm, e_armor);
            result = interaction.result;
            match result {
                ArmorResult::Ricochet => {
                    shell.velocity = NativeArmorInteraction::calculate_ricochet_velocity(
                        shell.velocity, hit_normal, interaction.energy_loss_fraction);
                    offset += hit_normal * (EPSILON as f32);
                    if shell.fuze < 0.0 && impact_angle > 70.0 * DEG_TO_RAD {
                        shell.fuze = 0.0;
                    }
                }
                ArmorResult::Shatter => {
                    shell.velocity = Vector3::ZERO;
                    shell.fuze = spec.fuze_delay;
                    shell.position += hit_normal * (EPSILON as f32);
                }
                ArmorResult::PartialPen => {
                    shell.velocity *= 0.1_f64 as f32;
                    shell.integrity *= 0.5;
                    if shell.velocity.length_squared() > 0.0 {
                        offset += shell.velocity.normalized() * (EPSILON as f32);
                    }
                }
                ArmorResult::Pen | ArmorResult::Overpen => {
                    if is_cit {
                        hit_cit = true;
                    }
                    over_pen = true;
                    let exit_speed = NativeArmorInteraction::calculate_exit_velocity(speed, shell.pen, e_armor);
                    let exit_dir = NativeArmorInteraction::calculate_deflected_direction(
                        shell.velocity.normalized(), hit_normal, interaction.pen_ratio);
                    shell.velocity = exit_dir * (exit_speed as f32);
                    shell.integrity = NativeArmorInteraction::calculate_shell_integrity(interaction.pen_ratio, shell.integrity);
                    if shell.velocity.length_squared() > 0.0 {
                        offset += shell.velocity.normalized() * (EPSILON as f32);
                    }
                    if shell.fuze < 0.0 && e_armor >= spec.arming_threshold {
                        shell.fuze = 0.0;
                    }
                }
            }
        }

        if log {
            out.steps.push(StepLog {
                result,
                is_citadel: is_cit,
                armor_mm,
                effective_mm: e_armor,
                impact_angle,
                pen: shell.pen,
                integrity: shell.integrity,
                pos: hit_position,
                vel: shell.velocity,
                impact_vel: log_impact_vel,
                part,
            });
        }

        if result == ArmorResult::Shatter || result == ArmorResult::PartialPen || shell.get_speed() < MIN_VELOCITY {
            shell.calc_end_position();
            break;
        }

        let next_ray_from = shell.position + offset;
        shell.calc_end_position();
        let next_ray_to = shell.end_position;
        let Some(next) = mesh.raycast(V3::from_godot(next_ray_from), V3::from_godot(next_ray_to)) else {
            if shell.fuze >= 0.0 {
                shell.fuze = spec.fuze_delay;
            }
            break;
        };
        let old_pos = hit_position;
        part = next.part;
        face = next.face;
        hit_position = next.pos.to_godot();
        hit_normal = next.normal.to_godot().normalized();
        let fuze_elapsed = old_pos.distance_to(hit_position) as f64 / shell.get_speed().max(0.001);
        if shell.fuze >= 0.0 {
            shell.fuze += fuze_elapsed;
        }
    }

    let final_part = mesh.part_at(V3::from_godot(shell.end_position));
    out.final_part = final_part;
    out.damage_result = NativeArmorInteraction::resolve_hit_result(
        result, final_part.is_some(), final_part.map(|p| mesh.is_citadel(p)).unwrap_or(false), hit_cit, over_pen);
    out.velocity = shell.velocity;
    out.end_position = shell.end_position;
    out.integrity = shell.integrity;
    out
}
