use godot::prelude::*;

use crate::nav::types::{clamp_f, lerp_f, move_toward_f, normalize_angle, ShipParams};

/// Physics tick (project.godot physics_ticks_per_second).
pub const PHYSICS_DT: f32 = 1.0 / 12.0;
/// Project default linear damp, combined with the body's.
const WORLD_LINEAR_DAMP: f32 = 0.1;
/// ShipMovementV4 sets angular_damp 0.5 in REPLACE mode.
const ANGULAR_DAMP: f32 = 0.5;
const THRUST_GAIN: f32 = 0.2;
const BOW_PIVOT_LOW: f32 = 0.9;
const BOW_PIVOT_HIGH: f32 = 1.0;

/// Planar ShipMovementV4 + Godot rigid body step. Velocity is world-frame, so
/// the hull slides on its old course while it turns.
#[derive(Clone, Copy, Debug)]
pub struct Hull {
    pub pos: Vector2,
    pub vel: Vector2,
    pub heading: f32,
    pub yaw: f32,
    pub rudder: f32,
    pub power: f32,
}

impl Hull {
    pub fn fwd(&self) -> Vector2 {
        Vector2::new(self.heading.sin(), self.heading.cos())
    }

    pub fn speed(&self) -> f32 {
        self.vel.dot(self.fwd())
    }

    pub fn step(&mut self, p: &ShipParams, cmd_rudder: f32, target_power: f32, dt: f32) {
        let max = p.max_speed.max(0.1);
        self.rudder = if p.rudder_response_time > 0.001 {
            move_toward_f(self.rudder, cmd_rudder, dt / p.rudder_response_time)
        } else {
            cmd_rudder
        };
        let f = self.fwd();
        let right = Vector2::new(-f.y, f.x);
        let cs = clamp_f(self.vel.dot(f), -max, max);
        let ar = self.rudder.abs();
        let mut speed_ratio = clamp_f(cs.abs() / max, 0.0, 1.0);
        let mut drag_mult = 1.0;
        let mut accel = Vector2::ZERO;
        if ar > 0.01 && cs.abs() > 1.0 {
            speed_ratio = clamp_f(cs.abs() / (max * (1.0 - ar * p.turn_speed_loss)), 0.0, 1.0);
            let radius = p.turning_circle_radius * lerp_f(p.turn_tightening, 1.0, speed_ratio);
            self.yaw = cs / radius.max(1.0) * -self.rudder;
            let ds = clamp_f(cs.abs() / max, 0.0, 1.0);
            let target_lat = self.yaw * p.ship_length * 0.5 * lerp_f(BOW_PIVOT_LOW, BOW_PIVOT_HIGH, ds) * ds;
            accel += right * ((target_lat - self.vel.dot(right)) / p.rudder_response_time.max(0.01));
            drag_mult = 1.0 + p.turn_speed_loss * ar * 1.5;
        }
        let rudder_loss = if target_power > self.power {
            1.0 - ar * p.turn_speed_loss
        } else {
            1.0 + ar * p.turn_speed_loss * speed_ratio
        };
        self.power = move_toward_f(self.power, target_power, dt / p.acceleration_time.max(0.1) * rudder_loss);
        accel += f * (self.power * max * THRUST_GAIN);

        // Godot body integration: damp, then forces, then position.
        self.vel *= (1.0 - dt * (WORLD_LINEAR_DAMP + p.linear_drag * drag_mult)).max(0.0);
        self.yaw *= (1.0 - dt * ANGULAR_DAMP).max(0.0);
        self.vel += accel * dt;
        self.pos += self.vel * dt;
        self.heading = normalize_angle(self.heading + self.yaw * dt);
    }
}

/// Rudder that brings the bow onto `desired` with the least overshoot: full over
/// until the swing still to come while the rudder centres would carry it there.
pub fn rudder_to_heading(h: &Hull, p: &ShipParams, desired: f32, reverse: bool) -> f32 {
    let diff = normalize_angle(desired - h.heading);
    let drift = h.yaw * h.rudder.abs() * p.rudder_response_time;
    let eff = normalize_angle(desired - drift * 0.5 - h.heading);
    let mut rudder = if eff.abs() < 0.02 { 0.0 } else if eff > 0.0 { -1.0 } else { 1.0 };
    // Dead astern the side flips on noise; keep swinging the way the bow already is.
    const NEAR_PI_BAND: f32 = 0.09;
    if eff.abs() > std::f32::consts::PI - NEAR_PI_BAND && h.yaw.abs() > 0.001 {
        rudder = if h.yaw > 0.0 { -1.0 } else { 1.0 };
    }
    let lead = (h.yaw * p.rudder_response_time * 0.3).abs();
    if diff.abs() < lead {
        rudder *= diff.abs() / lead.max(0.01);
    }
    // Rudder authority follows the water over it, not the throttle order.
    let astern = if h.speed().abs() > 0.5 { h.speed() < 0.0 } else { reverse };
    if astern {
        rudder = -rudder;
    }
    clamp_f(rudder, -1.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params() -> ShipParams {
        ShipParams {
            turning_circle_radius: 350.0,
            rudder_response_time: 16.0,
            acceleration_time: 40.0,
            max_speed: 43.0,
            turn_speed_loss: 0.4,
            linear_drag: 0.1,
            ..ShipParams::default()
        }
    }

    #[test]
    fn reaches_max_speed_straight() {
        let p = params();
        let mut h = Hull { pos: Vector2::ZERO, vel: Vector2::ZERO, heading: 0.0, yaw: 0.0, rudder: 0.0, power: 0.0 };
        for _ in 0..(12 * 200) {
            h.step(&p, 0.0, 1.0, PHYSICS_DT);
        }
        assert!((h.speed() - 43.0).abs() < 1.0, "{}", h.speed());
    }

    #[test]
    fn slides_while_turning() {
        let p = params();
        let mut h = Hull { pos: Vector2::ZERO, vel: Vector2::new(0.0, 43.0), heading: 0.0, yaw: 0.0, rudder: 1.0, power: 1.0 };
        for _ in 0..(12 * 10) {
            h.step(&p, 1.0, 1.0, PHYSICS_DT);
        }
        let course = h.vel.x.atan2(h.vel.y);
        assert!(normalize_angle(course - h.heading).abs() > 0.05);
    }
}


