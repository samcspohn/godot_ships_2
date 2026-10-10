use std::cell::RefCell;
use std::collections::HashMap;
use std::f64::consts::{PI, TAU};

use godot::builtin::AnyArray;
use godot::classes::{Node3D, Object, Resource};
use godot::prelude::*;

use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2 as Drag;
use crate::names::names;
use crate::variant_cast::VariantCast;

names!(
    traverse_speed, elevation_speed, _range, slew_limits_enabled, slew_min_angle, slew_max_angle, fire_arcs,
    min_angle, max_angle, disabled, base_rotation, can_fire, _valid_target, _aim_point, barrel, muzzles;
);

thread_local! {
    // Dropping StringNames after engine shutdown panics.
    static NAMES: std::mem::ManuallyDrop<Names> = std::mem::ManuallyDrop::new(Names::new());
    static GOALS: RefCell<HashMap<InstanceId, Goal>> = RefCell::new(HashMap::new());
}

/// What a gun's last solve wanted; frames between solves only rotate toward it.
struct Goal {
    dir: Vector2,
    elev: f64,
    slew: Slew,
    barrel: Gd<Node3D>,
    can_fire: bool,
    valid: bool,
}

const SLEW_BOUNDARY_EPS: f64 = 1.0e-4;
const MIN_ELEVATION_ANGLE: f64 = -5.0 * PI / 180.0;
const CMP_EPSILON: f64 = 0.00001;

fn is_equal_approx(a: f64, b: f64) -> bool {
    if a == b {
        return true;
    }
    (a - b).abs() < (CMP_EPSILON * a.abs()).max(CMP_EPSILON)
}

pub(crate) fn wrapf(value: f64, min: f64, max: f64) -> f64 {
    let range = max - min;
    if range.abs() < CMP_EPSILON {
        return min;
    }
    let result = value - range * ((value - min) / range).floor();
    if is_equal_approx(result, max) {
        return min;
    }
    result
}

fn sgn(x: f64) -> f64 {
    if x > 0.0 {
        1.0
    } else if x < 0.0 {
        -1.0
    } else {
        0.0
    }
}

fn shortest(a: f64) -> f64 {
    if a.abs() > PI { -sgn(a) * (TAU - a.abs()) } else { a }
}

fn elevation_of(b: &Basis) -> f64 {
    let z = b.col_c();
    (-z.y as f64).atan2(Vector2::new(-z.x, -z.z).length() as f64)
}

/// Steps the barrel toward `desired` (NaN: down); whether it is laid, or as laid as it can be.
fn elevate(barrel: &Gd<Node3D>, desired: f64, max_elev: f64) -> bool {
    let mut barrel = barrel.clone();
    let err_pre = if desired.is_nan() { f64::INFINITY } else { desired - elevation_of(&barrel.get_global_transform().basis) };
    let step = if desired.is_nan() { -max_elev } else { err_pre.clamp(-max_elev, max_elev) };
    if step.abs() > 0.0001 {
        barrel.rotate(Vector3::RIGHT, step as f32);
        let mut r = barrel.get_rotation();
        r.x = (r.x as f64).max(MIN_ELEVATION_ANGLE) as f32;
        barrel.set_rotation(r);
    }
    if desired.is_nan() {
        return false;
    }
    let err = desired - elevation_of(&barrel.get_global_transform().basis);
    let at_min_depression = (barrel.get_rotation().x as f64) <= MIN_ELEVATION_ANGLE + 0.001 && err < 0.0;
    // Ship roll outruns elevation speed in turns; the shell launches from _aim_point, not the barrel.
    let chasing_at_rate = err_pre.abs() > max_elev && sgn(step) == sgn(err_pre) && err.abs() < 0.05;
    err.abs() < 0.015 || at_min_depression || chasing_at_rate
}

fn launch(from: Vector3, to: Vector3, shell: &Gd<Resource>) -> Option<Vector3> {
    let sol = Drag::calculate_launch_vector_impl(from, to, shell);
    sol.at(0).try_to::<Vector3>().ok()
}

pub(crate) struct GunStats {
    pub traverse: f64,
    elev_speed: f64,
    pub range: f64,
}

impl GunStats {
    pub(crate) fn of(params: &Gd<Resource>) -> Self {
        NAMES.with(|n| Self {
            traverse: params.get(&n.traverse_speed).to_f64(),
            elev_speed: params.get(&n.elevation_speed).to_f64(),
            range: params.get(&n._range).to_f64(),
        })
    }
}

#[derive(Clone)]
struct Slew {
    on: bool,
    min: f64,
    max: f64,
    arcs: Vec<(f64, f64)>,
}

/// Turret/Gun script state, read on first use and written back by `store` if changed.
pub(crate) struct Turret {
    node: Gd<Node3D>,
    slew: std::cell::OnceCell<Slew>,
    disabled: bool,
    base_rotation: f64,
    pub can_fire: bool,
    pub valid: bool,
    loaded: (bool, bool),
    aim_point: Option<Vector3>,
}

impl Turret {
    pub(crate) fn load(node: Gd<Node3D>) -> Self {
        NAMES.with(|n| {
            let (can_fire, valid) = (node.get(&n.can_fire).to_bool(), node.get(&n._valid_target).to_bool());
            Self {
                slew: std::cell::OnceCell::new(),
                disabled: node.get(&n.disabled).to_bool(),
                base_rotation: node.get(&n.base_rotation).to_f64(),
                can_fire,
                valid,
                loaded: (can_fire, valid),
                aim_point: None,
                node,
            }
        })
    }

    fn slew(&self) -> &Slew {
        self.slew.get_or_init(|| NAMES.with(|n| {
            let o = &self.node;
            Slew {
                on: o.get(&n.slew_limits_enabled).to_bool(),
                min: o.get(&n.slew_min_angle).to_f64(),
                max: o.get(&n.slew_max_angle).to_f64(),
                arcs: o.get(&n.fire_arcs).to_any_array().iter_shared()
                    .filter_map(|a| a.try_to::<Gd<Object>>().ok())
                    .map(|a| (a.get(&n.min_angle).to_f64(), a.get(&n.max_angle).to_f64()))
                    .collect(),
            }
        }))
    }

    pub(crate) fn store(&self) {
        NAMES.with(|n| {
            let mut o = self.node.clone().upcast::<Object>();
            if self.can_fire != self.loaded.0 {
                o.set(&n.can_fire, &self.can_fire.to_variant());
            }
            if self.valid != self.loaded.1 {
                o.set(&n._valid_target, &self.valid.to_variant());
            }
            if let Some(p) = self.aim_point {
                o.set(&n._aim_point, &p.to_variant());
            }
        })
    }

    fn arc_width(&self) -> f64 {
        wrapf(self.slew().max - self.slew().min, 0.0, TAU)
    }

    fn offset(&self, angle: f64) -> f64 {
        wrapf(angle - self.slew().min, 0.0, TAU)
    }

    pub(crate) fn rot_y(&self) -> f64 {
        self.node.get_rotation().y as f64
    }

    pub(crate) fn angle_to_target(&self, target: Vector3) -> f64 {
        let xf = self.node.get_global_transform();
        let fwd = -xf.basis.col_c().normalized_or_zero();
        let f2 = Vector2::new(fwd.x, fwd.z).normalized_or_zero();
        let td = (target - xf.origin).normalized_or_zero();
        let t2 = Vector2::new(td.x, td.z).normalized_or_zero();
        t2.cross(f2).atan2(t2.dot(f2)) as f64
    }

    pub(crate) fn is_disabled(&self) -> bool {
        self.disabled
    }

    pub(crate) fn in_fire_arcs(&self, angle: f64) -> bool {
        let slew = self.slew();
        if slew.arcs.is_empty() {
            return !slew.on || self.offset(angle) <= self.arc_width();
        }
        slew.arcs.iter().any(|&(lo, hi)| {
            let width = wrapf(hi - lo, 0.0, TAU);
            width == 0.0 || wrapf(angle - lo, 0.0, TAU) <= width
        })
    }

    /// Turret.is_aimpoint_valid with the horizontal range already checked.
    pub(crate) fn bearing_valid(&self, target: Vector3) -> bool {
        !self.slew().on || self.in_fire_arcs(self.rot_y() + self.angle_to_target(target))
    }

    fn clamp_to_rotation_limits(&mut self) {
        if !self.slew().on {
            return;
        }
        let mut rot = self.node.get_rotation();
        let off = self.offset(rot.y as f64);
        let arc = self.arc_width();
        if off <= arc {
            return;
        }
        rot.y = if TAU - off <= off - arc { self.slew().min + SLEW_BOUNDARY_EPS } else { self.slew().max - SLEW_BOUNDARY_EPS } as f32;
        self.node.set_rotation(rot);
    }

    /// The delta the mount may legally rotate by toward `desired_delta`.
    pub(crate) fn apply_rotation_limits(&self, current: f64, desired_delta: f64) -> f64 {
        if !self.slew().on || desired_delta == 0.0 {
            return desired_delta;
        }
        let arc = self.arc_width();
        let mut off = self.offset(current);
        if off > arc {
            if off - arc < SLEW_BOUNDARY_EPS {
                off = arc;
            } else if TAU - off < SLEW_BOUNDARY_EPS {
                off = 0.0;
            } else {
                // Saturated so the caller's rate clamp always takes a full corrective step.
                let target = wrapf(off + desired_delta, 0.0, TAU);
                let via_min_shorter = if target <= arc {
                    (TAU - off) + target <= (off - arc) + (arc - target)
                } else {
                    TAU - off <= off - arc
                };
                return if via_min_shorter { TAU } else { -TAU };
            }
        }
        let target = off + desired_delta;
        if (0.0..=arc).contains(&target) {
            return desired_delta;
        }
        let alt = desired_delta + if desired_delta < 0.0 { TAU } else { -TAU };
        if (0.0..=arc).contains(&(off + alt)) {
            return alt;
        }
        let wrapped = wrapf(target, 0.0, TAU);
        if TAU - wrapped <= wrapped - arc { -off } else { arc - off }
    }

    fn turret_aim(&mut self, aim_point: Vector3, delta: f64, return_to_base: bool, traverse_speed: f64) -> f64 {
        if self.disabled {
            return f64::INFINITY;
        }
        let max_delta = traverse_speed.to_radians() * delta;
        let desired = self.angle_to_target(aim_point);
        let rot_y = self.rot_y();
        let adjusted = self.apply_rotation_limits(rot_y, desired);
        self.valid = self.in_fire_arcs(rot_y + desired);
        let mut step = adjusted.clamp(-max_delta, max_delta);
        if return_to_base && !self.valid {
            step = shortest(self.base_rotation - rot_y).clamp(-max_delta, max_delta);
        }
        if step.abs() > 0.001 {
            self.node.rotate(Vector3::UP, step as f32);
            self.clamp_to_rotation_limits();
        }
        desired
    }

    fn turret_home(&mut self, delta: f64, traverse_speed: f64) -> bool {
        if self.disabled {
            return false;
        }
        self.can_fire = false;
        self.valid = false;
        let max_delta = traverse_speed.to_radians() * delta;
        let step = shortest(self.base_rotation - self.rot_y()).clamp(-max_delta, max_delta);
        if step.abs() < 0.001 {
            return false;
        }
        self.node.rotate(Vector3::UP, step as f32);
        true
    }

    fn barrel(&self) -> Option<Gd<Node3D>> {
        NAMES.with(|n| self.node.get(&n.barrel).try_to::<Gd<Node3D>>().ok())
    }

    pub(crate) fn muzzles_position(&self) -> Vector3 {
        let muzzles = NAMES.with(|n| self.node.get(&n.muzzles).to_any_array());
        let mut sum = Vector3::ZERO;
        for m in muzzles.iter_shared() {
            if let Ok(m) = m.try_to::<Gd<Node3D>>() {
                sum += m.get_global_position();
            }
        }
        sum / muzzles.len() as f32
    }

    /// Gun.return_to_base: true once the barrel is off the level stop, matching the old script.
    pub(crate) fn gun_home(&mut self, delta: f64, traverse_speed: f64) -> bool {
        GOALS.with(|g| g.borrow_mut().remove(&self.node.instance_id()));
        self.turret_home(delta, traverse_speed);
        let Some(mut barrel) = self.barrel() else { return true };
        let mut r = barrel.get_rotation();
        if (r.x as f64).abs() < 0.001 {
            r.x = (r.x as f64 * (1.0 - delta * 5.0)) as f32;
            barrel.set_rotation(r);
            return false;
        }
        true
    }

    pub(crate) fn gun_aim(&mut self, aim_point: Vector3, delta: f64, return_to_base: bool, clamp_aim: bool, ship_pos: Vector3,
            stats: &GunStats, shell: &Gd<Resource>) -> f64 {
        if self.disabled {
            GOALS.with(|g| g.borrow_mut().remove(&self.node.instance_id()));
            return f64::INFINITY;
        }
        self.turret_aim(aim_point, delta, return_to_base, stats.traverse);
        let desired = self.angle_to_target(aim_point);
        let muzzles = self.muzzles_position();
        let mut sol = launch(muzzles, aim_point, shell);
        let aim = if sol.is_some() && (((aim_point - ship_pos).length() as f64) < stats.range || !clamp_aim) {
            aim_point
        } else {
            let gp = self.node.get_global_position();
            let g = Vector3::new(gp.x, 0.0, gp.z);
            let dir = (Vector3::new(aim_point.x, 0.0, aim_point.z) - g).normalized_or_zero();
            let p = g + dir * (stats.range - 500.0) as f32;
            sol = launch(muzzles, p, shell);
            p
        };
        self.aim_point = Some(aim);

        let Some(barrel) = self.barrel() else {
            self.can_fire = false;
            return desired;
        };
        let desired_elev = sol.map_or(f64::NAN, |v| (v.y as f64).atan2(Vector2::new(v.x, v.z).length() as f64));
        let elevated = elevate(&barrel, desired_elev, stats.elev_speed.to_radians() * delta);
        self.can_fire = elevated && desired.abs() < 0.02 && self.valid;
        let to = self.node.get_global_position();
        let dir = Vector2::new(aim_point.x - to.x, aim_point.z - to.z).normalized_or_zero();
        let goal = Goal { dir, elev: desired_elev, slew: self.slew().clone(), barrel, can_fire: self.can_fire, valid: self.valid };
        GOALS.with(|g| g.borrow_mut().insert(self.node.instance_id(), goal));
        desired
    }

    /// Rotates toward the last solve's goal; false when there is none to follow.
    pub(crate) fn gun_track(node: &Gd<Node3D>, delta: f64, stats: &GunStats) -> bool {
        GOALS.with(|g| {
            let mut goals = g.borrow_mut();
            let Some(goal) = goals.get_mut(&node.instance_id()) else { return false };
            let fwd = -node.get_global_transform().basis.col_c();
            let f2 = Vector2::new(fwd.x, fwd.z).normalized_or_zero();
            let desired = goal.dir.cross(f2).atan2(goal.dir.dot(f2)) as f64;
            let mut t = Turret {
                node: node.clone(),
                slew: std::cell::OnceCell::from(goal.slew.clone()),
                disabled: false,
                base_rotation: 0.0,
                can_fire: goal.can_fire,
                valid: false,
                loaded: (goal.can_fire, goal.valid),
                aim_point: None,
            };
            let rot_y = t.rot_y();
            let max_delta = stats.traverse.to_radians() * delta;
            t.valid = t.in_fire_arcs(rot_y + desired);
            let step = t.apply_rotation_limits(rot_y, desired).clamp(-max_delta, max_delta);
            if step.abs() > 0.001 {
                t.node.rotate(Vector3::UP, step as f32);
                t.clamp_to_rotation_limits();
            }
            let elevated = elevate(&goal.barrel, goal.elev, stats.elev_speed.to_radians() * delta);
            t.can_fire = elevated && desired.abs() < 0.02 && t.valid;
            (goal.can_fire, goal.valid) = (t.can_fire, t.valid);
            t.store();
            true
        })
    }
}

/// Turret and Gun aiming math; the state stays in the scripts' vars.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct TurretCore {
    base: Base<RefCounted>,
}

#[godot_api]
impl TurretCore {
    #[func]
    fn angle_to_target(turret: Gd<Node3D>, target: Vector3) -> f64 {
        Turret::load(turret).angle_to_target(target)
    }

    #[func]
    fn in_fire_arcs(turret: Gd<Node3D>, angle: f64) -> bool {
        Turret::load(turret).in_fire_arcs(angle)
    }

    #[func]
    fn muzzles_position(gun: Gd<Node3D>) -> Vector3 {
        Turret::load(gun).muzzles_position()
    }

    /// Turret._aim: returns the pre-move bearing error.
    #[func]
    fn turret_aim(turret: Gd<Node3D>, aim_point: Vector3, delta: f64, return_to_base: bool, traverse_speed: f64) -> f64 {
        let mut t = Turret::load(turret);
        let err = t.turret_aim(aim_point, delta, return_to_base, traverse_speed);
        t.store();
        err
    }

    #[func]
    fn turret_home(turret: Gd<Node3D>, delta: f64, traverse_speed: f64) -> bool {
        let mut t = Turret::load(turret);
        let turning = t.turret_home(delta, traverse_speed);
        t.store();
        turning
    }

    #[func]
    fn gun_home(gun: Gd<Node3D>, delta: f64, traverse_speed: f64) -> bool {
        let mut t = Turret::load(gun);
        let r = t.gun_home(delta, traverse_speed);
        t.store();
        r
    }

    #[func]
    fn gun_aim(gun: Gd<Node3D>, aim_point: Vector3, delta: f64, return_to_base: bool, clamp_aim: bool, ship_pos: Vector3,
            params: Gd<Resource>, shell: Gd<Resource>) -> f64 {
        let mut t = Turret::load(gun);
        let err = t.gun_aim(aim_point, delta, return_to_base, clamp_aim, ship_pos, &GunStats::of(&params), &shell);
        t.store();
        err
    }

    /// ArtilleryController's per-tick loop: every gun of one battery at one point;
    /// without `solve` guns with a goal only rotate toward it.
    #[func]
    fn aim_guns(guns: AnyArray, aim_point: Vector3, delta: f64, ship_pos: Vector3, params: Gd<Resource>, shell: Gd<Resource>,
            solve: bool) {
        let stats = GunStats::of(&params);
        for v in guns.iter_shared() {
            if let Ok(g) = v.try_to::<Gd<Node3D>>() {
                if !solve && Turret::gun_track(&g, delta, &stats) {
                    continue;
                }
                let mut t = Turret::load(g);
                t.gun_aim(aim_point, delta, false, false, ship_pos, &stats, &shell);
                t.store();
            }
        }
    }
}
