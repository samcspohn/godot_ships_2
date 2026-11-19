use godot::prelude::*;

use super::snapshot::HullClass;

/// One enemy a torpedo boat may take as its target: seen now, or held on a fresh last-known position.
#[derive(Clone, Copy, Debug)]
pub struct Cand {
    pub id: i64,
    pub pos: Vector2,
    /// Bow bearing (radians, atan2(x, z)) as believed.
    pub heading: f32,
    pub length: f32,
    pub class: HullClass,
    pub lkp: bool,
    /// Our guns' target.
    pub gun_target: bool,
    /// Our guns clear terrain to it.
    pub clear: bool,
}

pub struct Ctx {
    pub my: Vector2,
    pub gun_range: f32,
    pub torp_range: f32,
    pub torp_boat: bool,
    pub detected: bool,
    pub own_spawn: Option<Vector2>,
    pub enemy_spawn: Option<Vector2>,
    pub team_avg: Option<Vector2>,
}

/// A torpedo target rule: the chosen candidate's id.
pub type Pick = fn(&Ctx, &[Cand]) -> Option<i64>;

/// SHIPS_BOT5_TORP_PICK: "v4" (default) or "gun".
pub fn by_name(name: &str) -> Pick {
    match name {
        "gun" => gun,
        _ => v4,
    }
}

/// Our gun target, else the nearest seen.
pub fn gun(c: &Ctx, cands: &[Cand]) -> Option<i64> {
    cands.iter().filter(|e| !e.lkp)
        .min_by(|a, b| (!a.gun_target).cmp(&!b.gun_target).then(a.pos.distance_to(c.my).total_cmp(&b.pos.distance_to(c.my))))
        .map(|e| e.id)
}

const PROXIMITY_M: f32 = 2500.0;
const OVEREXT_W: f32 = 0.3;
const OVEREXT_BONUS: f32 = 1.8;
const IN_RANGE: f32 = 10.0;
const FLANK_MULT: f32 = 6.0;
const LKP_MULT: f32 = 0.85;
const DEEP_FLANK: f32 = 0.3;
const FLANK: f32 = 0.5;
const MIN_SPAWN_M: f32 = 5000.0;

/// v4 BotBehavior spawn axis: (enemy - enemy spawn) projected on enemy spawn - own spawn, over its length.
fn penetration(c: &Ctx, p: Vector2) -> Option<f32> {
    let (own, foe) = (c.own_spawn?, c.enemy_spawn?);
    let axis = foe - own;
    let len = axis.length();
    (len >= 1.0).then(|| (p - foe).dot(axis / len) / len)
}

/// v4 _get_flanking_info: (flanking, depth).
fn flanking(c: &Ctx, p: Vector2) -> (bool, f32) {
    let (Some(own), Some(r)) = (c.own_spawn, penetration(c, p)) else { return (false, 0.0) };
    let to_own = p.distance_to(own);
    if to_own > MIN_SPAWN_M * 2.0 && r < FLANK {
        return (false, 0.0);
    }
    let remap = |x: f32, a: f32, b: f32, lo: f32, hi: f32| lo + (x - a) / (b - a) * (hi - lo);
    let (on, mut depth) = if r >= DEEP_FLANK {
        (true, remap(r, DEEP_FLANK, 1.0, 0.5, 1.0).clamp(0.5, 1.0))
    } else if r >= FLANK {
        (true, remap(r, FLANK, DEEP_FLANK, 0.0, 0.5).clamp(0.0, 0.5))
    } else {
        (false, 0.0)
    };
    if on && c.team_avg.is_some_and(|a| to_own < a.distance_to(own)) {
        depth = (depth + 0.25).min(1.0);
    }
    (on, depth)
}

/// v4 DDBehavior.pick_target: hidden, a torpedo boat scores lie (45 degrees off the bow best) and size over distance,
/// blended with nearness in tube range, battleships doubled; lit or a gunboat, nearness in gun range. In range x10,
/// flankers x6 by depth, last-known x0.85, overextension and close quarters on top; a shootable one beats any other.
pub fn v4(c: &Ctx, cands: &[Cand]) -> Option<i64> {
    let mut rows: Vec<(i64, f32, f32, f32, bool)> = Vec::with_capacity(cands.len());
    let (mut max_over, mut close) = (0.0f32, false);
    for e in cands {
        let disp = e.pos - c.my;
        let dist = disp.length().max(1.0);
        let fwd = Vector2::new(e.heading.sin(), e.heading.cos());
        let angle = fwd.angle_to(disp).abs() - std::f32::consts::FRAC_PI_4;
        let mut p = if c.torp_boat && !c.detected {
            let mut p = angle.cos() * e.length / dist;
            if c.torp_range > 0.0 {
                p = p * 0.3 + (1.0 - dist / c.torp_range) * 0.7;
            }
            if e.class == HullClass::Bb {
                p *= 2.0;
            }
            p
        } else {
            1.0 - dist / c.gun_range.max(1.0)
        };
        if dist <= c.gun_range || (c.torp_range > 0.0 && dist <= c.torp_range) {
            p *= IN_RANGE;
        }
        let (fl, depth) = flanking(c, e.pos);
        if fl {
            p *= FLANK_MULT * (1.0 + depth);
        }
        let over = penetration(c, e.pos).map_or(0.0, |r| r.clamp(0.0, 1.0));
        max_over = max_over.max(over);
        close |= dist < PROXIMITY_M;
        if e.lkp {
            p *= LKP_MULT;
        }
        let shootable = (if c.torp_boat { c.detected } else { !e.lkp }) && dist <= c.gun_range && e.clear;
        rows.push((e.id, p, dist, over, shootable));
    }
    let mut best: [Option<(i64, f32)>; 2] = [None, None];
    for (id, mut p, dist, over, shootable) in rows {
        if max_over > 0.0 {
            let rel = over / max_over;
            p += rel * OVEREXT_W;
            if !close && rel > 0.9 {
                p *= OVEREXT_BONUS;
            }
        }
        if dist < PROXIMITY_M {
            p *= 1.0 + 2.0 * (1.0 - dist / PROXIMITY_M);
        }
        let slot = &mut best[!shootable as usize];
        if slot.is_none_or(|b| p > b.1) {
            *slot = Some((id, p));
        }
    }
    best[0].or(best[1]).map(|b| b.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand(id: i64, x: f32, z: f32, class: HullClass) -> Cand {
        Cand { id, pos: Vector2::new(x, z), heading: 0.0, length: 200.0, class, lkp: false, gun_target: false, clear: true }
    }

    fn ctx(detected: bool) -> Ctx {
        Ctx { my: Vector2::ZERO, gun_range: 8000.0, torp_range: 12000.0, torp_boat: true, detected, own_spawn: None,
            enemy_spawn: None, team_avg: None }
    }

    #[test]
    fn hidden_torpedo_boat_prefers_the_battleship() {
        let cs = [cand(1, 0.0, 9000.0, HullClass::Ca), cand(2, 0.0, 10000.0, HullClass::Bb)];
        assert_eq!(v4(&ctx(false), &cs), Some(2));
    }

    #[test]
    fn lit_takes_the_nearest_it_can_shoot() {
        let mut far = cand(2, 0.0, 6000.0, HullClass::Bb);
        far.clear = false;
        let cs = [cand(1, 0.0, 7000.0, HullClass::Ca), far];
        assert_eq!(v4(&ctx(true), &cs), Some(1));
    }
}
