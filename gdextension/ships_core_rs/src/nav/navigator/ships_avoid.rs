use godot::prelude::*;

use super::arc::obb_obb_overlap_2d;
use super::{ShipNavigator, SteeringChoice};
use crate::nav::types::{angle_difference, ArcPoint};

/// Other ships are only avoided this far ahead; past it, re-steering every frame handles them.
pub const SHIP_HORIZON_S: f32 = 25.0;
const HEADING_STEP: f32 = std::f32::consts::PI / 36.0;
/// Within this of the chosen heading the rudder eases off instead of holding hard over.
const EASE_RUDDER: f32 = 0.17;
const EXTEND_DT: f32 = 1.0;

impl ShipNavigator {
    /// This frame's ships: near enough to meet within the horizon, and friendly or spotted.
    pub(crate) fn refresh_ships(&mut self) {
        self.ships.clear();
        let Some(list) = self.ship_source.as_ref() else { return };
        let reach_v = self.params.max_speed.max(self.state.current_speed.abs());
        let me = self.state.position;
        for s in list.read().unwrap().iter() {
            if s.id == self.own_ship_id || (s.team != self.own_team && !s.seen) {
                continue;
            }
            let reach = (reach_v + s.speed.abs()) * SHIP_HORIZON_S + s.half_len + self.params.ship_length * 0.5;
            if s.pos.distance_squared_to(me) <= reach * reach {
                self.ships.push(*s);
            }
        }
    }

    /// Where the bow is steering: stance's heading, else the waypoint, else (arrived) where it points.
    pub(crate) fn steer_goal(&self) -> f32 {
        let wp = if self.path_valid && self.current_wp_index < self.current_path.waypoints.len() as i32 {
            self.current_path.waypoints[self.current_wp_index as usize]
        } else {
            self.target.position
        };
        let to = wp - self.state.position;
        let arrived = to.length() < self.target.hold_radius.max(self.params.ship_beam * 2.0);
        if self.target.heading_weight >= 0.5 {
            self.target.heading
        } else if arrived || to.length() < 1.0 {
            self.state.heading
        } else {
            to.x.atan2(to.y)
        }
    }

    /// Hard over toward `h` the short way (bow `h` while backing), then on along it, to the horizon.
    fn heading_path(&self, h: f32, throttle: i32) -> (Vec<ArcPoint>, f32) {
        let diff = angle_difference(self.state.heading, h);
        let astern = throttle < 0;
        // Negative rudder raises heading going ahead and lowers it going astern.
        let side = if diff > 0.0 { -1.0 } else { 1.0 };
        let rudder = if diff.abs() < 0.02 { 0.0 } else if astern { -side } else { side };
        let dir = Vector2::new(h.sin(), h.cos());
        let target = if astern { self.state.position - dir * 1.0e5 } else { self.state.position + dir * 1.0e5 };
        let mut arc = self.predict_arc_to_heading(rudder, throttle, target, f32::MAX, SHIP_HORIZON_S, astern);
        let last = *arc.last().unwrap();
        let fwd = Vector2::new(last.heading.sin(), last.heading.cos());
        let mut t = last.time;
        while t + EXTEND_DT <= SHIP_HORIZON_S {
            t += EXTEND_DT;
            arc.push(ArcPoint::new(last.position + fwd * (last.speed * (t - last.time)), last.heading, last.speed, t));
        }
        (arc, rudder)
    }

    /// First moment `arc` meets a ship, INF if never.
    fn ship_contact(&self, arc: &[ArcPoint]) -> f32 {
        let margin = self.params.ship_beam * 0.5;
        let (hl, hb) = (self.params.ship_length * 0.5 + margin, self.params.ship_beam * 0.5 + margin);
        for pt in arc {
            for s in &self.ships {
                let (p, sh) = s.pose_at(pt.time);
                if obb_obb_overlap_2d(pt.position, pt.heading, hl, hb, p, sh, s.half_len, s.half_beam) {
                    return pt.time;
                }
            }
        }
        f32::INFINITY
    }

    fn aground(&self, arc: &[ArcPoint], hard_clearance: f32) -> bool {
        let Some(map) = self.map.as_ref() else { return false };
        let mb = map.bind();
        mb.is_built() && arc.iter().any(|p| mb.get_distance_impl(p.position.x, p.position.y) < hard_clearance)
    }

    /// None when the way to the goal heading meets no ship. Else the heading
    /// nearest the goal whose turn and run stay clear of ships and land, steered
    /// for; with none clear, the one meeting a ship latest.
    pub(crate) fn steer_around_ships(&mut self, throttle: i32, hard_clearance: f32) -> Option<SteeringChoice> {
        if self.ships.is_empty() || self.skip_ship_obstacles {
            return None;
        }
        let goal = self.steer_goal();
        let (arc, _) = self.heading_path(goal, throttle);
        if self.ship_contact(&arc).is_infinite() {
            return None;
        }
        let prefer = if self.turn_latch != 0.0 { self.turn_latch } else { self.state.current_rudder.signum() };
        let mut fallback: Option<(f32, f32, f32)> = None;
        let steps = (std::f32::consts::PI / HEADING_STEP).round() as i32;
        for k in 1..=steps {
            // Sides in rudder terms: the latched or current turn is tried first at each step.
            for side in [prefer, -prefer] {
                let side = if side == 0.0 { 1.0 } else { side };
                let h = goal - side * k as f32 * HEADING_STEP;
                let (arc, rudder) = self.heading_path(h, throttle);
                if self.aground(&arc, hard_clearance) {
                    continue;
                }
                let contact = self.ship_contact(&arc);
                if contact.is_infinite() {
                    return Some(self.steer_to(h, rudder, throttle));
                }
                if fallback.is_none_or(|f| contact > f.0) {
                    fallback = Some((contact, h, rudder));
                }
            }
        }
        fallback.map(|(_, h, rudder)| self.steer_to(h, rudder, throttle))
    }

    fn steer_to(&self, h: f32, rudder: f32, throttle: i32) -> SteeringChoice {
        let off = angle_difference(self.state.heading, h).abs();
        let rudder = if off < EASE_RUDDER { self.compute_rudder_to_heading(h, throttle < 0) } else { rudder };
        SteeringChoice { rudder, throttle, collision_imminent: true }
    }
}

