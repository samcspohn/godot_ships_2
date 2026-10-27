use godot::prelude::*;
use std::f32::consts::PI;

use super::arc::SIM_DT;
use super::hull::rudder_to_heading;
use super::ShipNavigator;
use crate::nav::map::NavigationMap;
use crate::nav::types::{angle_difference, normalize_angle, throttle_to_speed_fraction, ArcPoint};

pub(crate) struct Rollout {
    pub points: Vec<ArcPoint>,
    /// First time the hull is inside `limit`, INF when never.
    pub hit_t: f32,
    /// A hit before this is one the ship can no longer steer out of.
    pub veto_t: f32,
    pub min_sdf: f32,
    /// Estimated seconds until the route is sailed.
    pub cost: f32,
    /// When the follower took over from the held command.
    pub commit_t: f32,
}

impl ShipNavigator {
    /// Holds (rudder, throttle) until the bow bears on the waypoint (or `aim`) plus
    /// `extra_hold`, then runs the heading follower along `route` (or at `aim`) at `follow_throttle`.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn rollout(
        &self,
        map: Option<&NavigationMap>,
        route: &[Vector2],
        rudder: f32,
        throttle: i32,
        extra_hold: f32,
        aim: Option<Vector2>,
        follow_throttle: i32,
        limit: f32,
    ) -> Rollout {
        let p = &self.params;
        let horizon = (2.0 * p.rudder_response_time + 0.5 * p.acceleration_time).clamp(30.0, 60.0);
        let reach = self.get_reach_radius();
        let astern = follow_throttle < 0;
        let (hold_power, follow_power) = (throttle_to_speed_fraction(throttle), throttle_to_speed_fraction(follow_throttle));
        let emit = self.get_ship_clearance();

        let mut h = self.hull_now();
        let mut out = Rollout { points: vec![ArcPoint::new(h.pos, h.heading, h.speed(), 0.0)], hit_t: f32::INFINITY, veto_t: 0.0, min_sdf: f32::INFINITY, cost: f32::INFINITY, commit_t: horizon };
        let (mut t, mut k, mut aligned_at, mut holding) = (0.0f32, 0usize, f32::INFINITY, extra_hold >= 0.0);
        if !holding {
            out.commit_t = 0.0;
        }
        let (mut travelled, mut next_emit) = (0.0f32, emit);
        let goal = |pos: Vector2, wp: Vector2| {
            let d = wp - pos;
            let b = d.x.atan2(d.y);
            if astern { normalize_angle(b + PI) } else { b }
        };

        while t < horizon {
            while aim.is_none() && k < route.len() && h.pos.distance_to(route[k]) < reach {
                k += 1;
            }
            if k == route.len() {
                out.cost = t;
                break;
            }
            let bow = goal(h.pos, aim.unwrap_or(route[k]));
            if holding {
                if aligned_at.is_infinite() && angle_difference(h.heading, bow).abs() < 0.087 {
                    aligned_at = t;
                }
                if t >= aligned_at + extra_hold {
                    holding = false;
                    out.commit_t = t;
                }
            }
            let (r, pw) = if holding { (rudder, hold_power) } else { (rudder_to_heading(&h, p, bow, astern), follow_power) };
            let prev = h.pos;
            h.step(p, r, pw, SIM_DT);
            t += SIM_DT;
            travelled += h.pos.distance_to(prev);

            let sdf = map.map_or(f32::INFINITY, |m| m.get_distance_impl(h.pos.x, h.pos.y));
            out.min_sdf = out.min_sdf.min(sdf);
            if sdf < limit && out.hit_t.is_infinite() {
                out.hit_t = t;
            }
            if travelled >= next_emit {
                out.points.push(ArcPoint::new(h.pos, h.heading, h.speed(), t));
                next_emit += emit;
            }
        }
        out.points.push(ArcPoint::new(h.pos, h.heading, h.speed(), t));
        // Past one rudder swing into the follower, the real navigator will have replanned.
        out.veto_t = out.commit_t.min(horizon) + p.rudder_response_time.max(8.0);

        if out.cost.is_infinite() {
            let cruise = (follow_power.abs() * p.max_speed).max(1.0);
            let mut remaining = h.pos.distance_to(route[k]);
            for w in route[k..].windows(2) {
                remaining += w[0].distance_to(w[1]);
            }
            let turn = angle_difference(h.heading, goal(h.pos, route[k])).abs() * p.turning_circle_radius / cruise;
            let way_on = if astern { -h.speed() } else { h.speed() };
            let spin_up = (cruise - way_on).max(0.0) / p.max_speed.max(0.1) * p.acceleration_time * 0.5;
            out.cost = t + remaining / cruise + turn + spin_up;
        }
        out
    }
}
