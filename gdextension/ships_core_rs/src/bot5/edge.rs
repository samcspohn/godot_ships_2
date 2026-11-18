//! Exact checks against the island colliders, off Godot physics: eye-height sight lines and shells flown along the
//! drag solver's low arc. The matrix's edge cells and their quarters are settled with these, as v4's EdgeSim did.

use godot::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;

use crate::ballistics::drag_v2::{ProjectilePhysicsWithDragV2 as P, GRAVITY};
use crate::projectile::armor::mesh::{PartMesh, Tri, V3};

/// Spotting rays run 1 m over the water at both ends.
const EYE_H: f64 = 1.0;
const CHORD_M: f64 = 150.0;
const CACHE_MAX: usize = 200_000;
const KEY_M: f32 = 25.0;

pub struct IslandMesh {
    mesh: PartMesh,
    top: f64,
    pub sig: usize,
}

impl IslandMesh {
    pub fn build(tris: &[[Vector3; 3]]) -> Self {
        let v = |p: Vector3| V3::new(p.x as f64, p.y as f64, p.z as f64);
        let top = tris.iter().flatten().map(|p| p.y as f64).fold(0.0, f64::max);
        let tris = tris.iter().map(|t| Tri { v0: v(t[0]), v1: v(t[1]), v2: v(t[2]), thickness: 0.0 }).collect();
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);
        IslandMesh { mesh: PartMesh::new(tris, 0, false, Transform3D::IDENTITY), top, sig: NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed) }
    }

    /// Eye-height line of sight from `a` to `b` misses every island.
    pub fn los(&self, a: Vector2, b: Vector2) -> bool {
        !self.mesh.hits(V3::new(a.x as f64, EYE_H, a.y as f64), V3::new(b.x as f64, EYE_H, b.y as f64))
    }

    /// A shell from guns at `from` lands at the waterline on `to` without touching an island; false out of range.
    pub fn shot(&self, g: &Flight, from: Vector2, to: Vector2) -> bool {
        let key = (self.sig, g.key, (from.x / KEY_M) as i32, (from.y / KEY_M) as i32, (to.x / KEY_M) as i32, (to.y / KEY_M) as i32);
        if let Some(&c) = CACHE.with(|c| c.borrow().get(&key).copied()).as_ref() {
            return c;
        }
        let c = self.fly(g, from, to);
        CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            if cache.len() >= CACHE_MAX {
                cache.clear();
            }
            cache.insert(key, c);
        });
        c
    }

    fn fly(&self, g: &Flight, from: Vector2, to: Vector2) -> bool {
        let r = from.distance_to(to) as f64;
        if r < 1.0 {
            return true;
        }
        let Some(theta) = g.theta(r) else { return false };
        let n = (r / CHORD_M).ceil().max(4.0) as usize;
        let (dx, dz) = ((to.x - from.x) as f64 / r, (to.y - from.y) as f64 / r);
        let at = |i: usize| {
            let x = r * i as f64 / n as f64;
            let y = if i == n { 0.0 } else { g.gun_h + g.y(theta, x) };
            V3::new(from.x as f64 + dx * x, y, from.y as f64 + dz * x)
        };
        let mut a = at(0);
        for i in 1..=n {
            let b = at(i);
            if a.y.min(b.y) <= self.top && self.mesh.hits(a, b) {
                return false;
            }
            a = b;
        }
        true
    }
}

thread_local! {
    static CACHE: RefCell<HashMap<(usize, i64, i32, i32, i32, i32), bool>> = RefCell::new(HashMap::new());
}

/// One gun's flight: the drag model the gun matrix and RBlockTable use.
#[derive(Clone, Copy, Debug)]
pub struct Flight {
    v0: f64,
    beta: f64,
    vt: f64,
    tau: f64,
    gun_h: f64,
    range: f64,
    theta_max: f64,
    key: i64,
}

impl Flight {
    pub fn new(speed: f32, drag: f32, gun_h: f32, range: f32) -> Option<Self> {
        if speed <= 0.0 || drag <= 0.0 || range <= 0.0 {
            return None;
        }
        let (v0, beta) = (speed as f64, drag as f64);
        let vt = (GRAVITY / beta).sqrt();
        let mut a = Flight { v0, beta, vt, tau: vt / GRAVITY, gun_h: gun_h as f64, range: range as f64, theta_max: 0.0,
            key: ((speed.to_bits() as i64) << 32) ^ (drag.to_bits() as i64) ^ ((gun_h * 10.0) as i64) << 20 ^ range as i64 };
        let (mut best, mut deg) = (0.0f64, 0.5f64);
        while deg <= 70.0 {
            let r = a.reach(deg.to_radians());
            if r > best {
                best = r;
                a.theta_max = deg.to_radians();
            }
            deg += 0.5;
        }
        Some(a)
    }

    fn y(&self, theta: f64, x: f64) -> f64 {
        P::vertical_position(theta.sin(), P::time_from_x(x, theta, self.v0, self.beta), self.v0, self.vt, self.tau)
    }

    fn reach(&self, theta: f64) -> f64 {
        let (mut lo, mut hi) = (0.0f64, 1000.0f64);
        while self.y(theta, hi) > -self.gun_h && hi < 200_000.0 {
            hi *= 2.0;
        }
        for _ in 0..40 {
            let mid = 0.5 * (lo + hi);
            if self.y(theta, mid) > -self.gun_h { lo = mid } else { hi = mid }
        }
        lo
    }

    /// The low-arc launch angle onto the waterline `r` away.
    fn theta(&self, r: f64) -> Option<f64> {
        if r > self.range || self.y(self.theta_max, r) < -self.gun_h {
            return None;
        }
        let (mut lo, mut hi) = (0.0f64, self.theta_max);
        for _ in 0..40 {
            let mid = 0.5 * (lo + hi);
            if self.y(mid, r) < -self.gun_h { lo = mid } else { hi = mid }
        }
        Some(hi)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wall(x: f32, h: f32) -> IslandMesh {
        let (a, b, c, d) = (Vector3::new(x, -10.0, -500.0), Vector3::new(x, -10.0, 500.0), Vector3::new(x, h, 500.0), Vector3::new(x, h, -500.0));
        IslandMesh::build(&[[a, b, c], [a, c, d]])
    }

    #[test]
    fn arcs_clear_low_walls_and_not_high_ones() {
        let g = Flight::new(800.0, 0.0001, 10.0, 15000.0).unwrap();
        let (from, to) = (Vector2::new(0.0, 0.0), Vector2::new(10000.0, 0.0));
        assert!(wall(5000.0, 30.0).shot(&g, from, to));
        assert!(!wall(9900.0, 60.0).shot(&g, from, to));
        assert!(!wall(5000.0, 30.0).los(from, to));
        assert!(wall(5000.0, 30.0).los(from, Vector2::new(4000.0, 0.0)));
        assert!(!g.theta(20000.0).is_some());
    }
}
