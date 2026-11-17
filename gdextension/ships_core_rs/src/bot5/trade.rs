//! v4's trade: the range to fight an enemy at, from both sides' kill rates by range (mains, secondaries, torpedoes).

use super::snapshot::ShipState;
use super::station::Fire;

pub const POINT_BLANK_M: f32 = 100.0;
pub const STEP_M: f32 = 250.0;
const WIN_TIE: f32 = 0.05;
/// The band runs over the ranges trading within this share of the chosen one.
const BAND_TIE: f32 = 0.1;
const BAND_MIN_M: f32 = 1000.0;
const EVEN_TRADE: f32 = 0.8;
const AGGRESSION_TRADE: f32 = 0.5;
const LOSE_MARGIN_M: f32 = 500.0;
pub const TTK_BUDGET_SHARE: f32 = 1.0 / 6.0;
const HURT_PUSH: f32 = 1.0;
const TORP_LANE_RAD: f32 = 0.012;
const TORP_DODGE_KEEP: f32 = 0.2;
const TORP_COURSE_SHIFTS: f32 = 6.0;
/// Secondaries this share of the mains at half their range make a brawler.
const BRAWLER_SEC_SHARE: f32 = 0.75;
pub const BRAWL_RANGE_M: f32 = 4000.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Desire {
    Win,
    Even,
    Lose,
}

#[derive(Clone, Copy, Debug)]
pub struct Trade {
    pub range: f32,
    pub desire: Desire,
    pub band: (f32, f32),
}

pub fn reach(s: &ShipState) -> f32 {
    s.gun_range.max(s.torp_range)
}

/// Damage one spread from `shooter` lands on `target` at `r` (v4 torpedo_curve): the lanes its width fills, dodged
/// as far as the warning outruns its rudder, fading with the run.
pub fn torp_salvo(shooter: &ShipState, target: &ShipState, r: f32) -> f32 {
    if shooter.torp_range <= 0.0 || r > shooter.torp_range || shooter.torp_speed <= 0.0 {
        return 0.0;
    }
    let width = target.length * target.guns_bear.to_radians().sin() + target.beam;
    let shift_s = (2.0 * target.turn_radius * target.length).sqrt() / target.max_speed.max(1.0);
    let lanes = 1.0 + width / (r * TORP_LANE_RAD).max(1.0);
    let tubes = shooter.torp_tubes.min(lanes);
    let warn = r.min(shooter.torp_detect) / shooter.torp_speed;
    let reactable = ((warn - target.rudder_lag) / shift_s.max(0.1)).clamp(0.0, 1.0);
    let keep = 1.0 + (TORP_DODGE_KEEP - 1.0) * reactable;
    tubes * shooter.torp_damage * keep * (-r / shooter.torp_speed / (TORP_COURSE_SHIFTS * shift_s).max(1.0)).exp()
}

/// Share of `hp` the torpedoes take per second at `r`: the first spread loaded, then whole reloads.
pub fn torp_rate(shooter: &ShipState, target: &ShipState, r: f32, hp: f32) -> f32 {
    let salvo = torp_salvo(shooter, target, r);
    if salvo <= 0.0 {
        return 0.0;
    }
    1.0 / (shooter.torp_bear_s + r / shooter.torp_speed + shooter.torp_reload * (hp / salvo - 1.0).max(0.0))
}

/// Guns per minute at `r` on a hull lying at `aspect`: mains only inside their range, secondaries inside theirs.
pub fn guns_at(f: &Fire, r: f32, aspect: f32) -> f32 {
    let sec = f.sec_at(r);
    let mains = if r <= f.gun_range() { (f.at(r, aspect) - sec).max(0.0) } else { 0.0 };
    mains + sec
}

/// Secondaries at half their range carry BRAWLER_SEC_SHARE of the mains there, on a hull lying as `f`'s does.
pub fn brawler(f: &Fire, me: &ShipState, aspect: f32) -> bool {
    if me.sec_range <= 0.0 || me.sec_dpm <= 0.0 {
        return false;
    }
    let r = 0.5 * me.sec_range;
    let mains = (f.at(r, aspect) - f.sec_at(r)).max(0.0);
    me.sec_dpm >= BRAWLER_SEC_SHARE * mains
}

pub struct Side<'a> {
    pub ship: &'a ShipState,
    pub fire: Option<&'a Fire<'a>>,
    /// Calibration on this side's gun damage.
    pub k: f32,
    pub hp: f32,
}

/// v4 _desired_by_trade. `us` fires on `them` and they on us; `hp_frac` our HP share; `budget_s` time to kill in.
pub fn desired(us: &Side, them: &Side, hp_frac: f32, aggression: f32, budget_s: f32) -> Trade {
    let (me, en) = (us.ship, them.ship);
    let rate = |s: &Side, t: &Side, r: f32| {
        s.fire.map_or(0.0, |f| guns_at(f, r, t.ship.guns_bear) * s.k / t.hp / 60.0) + torp_rate(s.ship, t.ship, r, t.hp)
    };
    let both = reach(me).min(reach(en));
    let n = if both >= POINT_BLANK_M { ((both - POINT_BLANK_M) / STEP_M) as usize + 1 } else { 0 };
    let even_trade = EVEN_TRADE * (-AGGRESSION_TRADE * aggression).exp();
    let (mut best, mut best_r, mut even, mut even_fast, mut fastest, mut fastest_out) = (0.0f32, -1.0f32, -1.0f32, -1.0f32, -1.0f32, 0.0f32);
    let mut rows = Vec::with_capacity(n);
    for k in 0..n {
        let r = POINT_BLANK_M + k as f32 * STEP_M;
        let (out, theirs) = (rate(us, them, r), rate(them, us, r));
        let ratio = if theirs > 0.0 { out / theirs } else if out > 0.0 { f32::INFINITY } else { 0.0 };
        rows.push((r, out, ratio));
        if ratio > best {
            best = ratio;
            best_r = r;
        }
        if ratio >= even_trade {
            even = r;
            if out * budget_s >= 1.0 {
                even_fast = r;
            } else if out > fastest_out {
                fastest_out = out;
                fastest = r;
            }
        }
    }
    if even_fast < 0.0 {
        even_fast = fastest;
    }
    let hurt = HURT_PUSH * (1.0 - hp_frac.clamp(0.0, 1.0));
    let edge = (en.gun_range + LOSE_MARGIN_M).min(me.gun_range);
    let eased = |at: f32| at + (at.max(edge) - at) * hurt;
    let around = |at: f32, desire: Desire| {
        let band = if rows.is_empty() { (at, at) } else {
            let k = (((at - POINT_BLANK_M) / STEP_M).round().max(0.0) as usize).min(rows.len() - 1);
            let floor = rows[k].2 * (1.0 - BAND_TIE);
            let lo = (0..=k).rev().take_while(|&j| rows[j].2 >= floor).last().unwrap_or(k);
            let hi = (k..rows.len()).take_while(|&j| rows[j].2 >= floor).last().unwrap_or(k);
            (rows[lo].0.min(at), rows[hi].0.max(at))
        };
        let pad = (BAND_MIN_M - (band.1 - band.0)).max(0.0);
        Trade { range: at, desire, band: (band.0, band.1 + pad) }
    };
    if best > 1.0 {
        let win = rows.iter().filter(|(_, out, ratio)| *ratio >= best * (1.0 - WIN_TIE) && out * budget_s >= 1.0)
            .map(|r| r.0).fold(best_r, f32::max);
        return around(eased(win), Desire::Win);
    }
    let past = reach(en) + STEP_M;
    if past <= reach(me) && rate(us, them, past) > 0.0 {
        return Trade { range: past, desire: Desire::Win, band: (past, reach(me).max(past + BAND_MIN_M)) };
    }
    if even > 0.0 {
        return around(eased(even_fast), Desire::Even);
    }
    if best_r > 0.0 {
        return around(eased(best_r), Desire::Lose);
    }
    let r = en.gun_range + LOSE_MARGIN_M;
    Trade { range: r, desire: Desire::Lose, band: (r, r + BAND_MIN_M) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::snapshot::{Snapshot, STRIDE};

    fn ship(id: i64, gun: f32, conceal: f32) -> ShipState {
        let mut r = [0.0f32; STRIDE];
        (r[1], r[9], r[11], r[12], r[13], r[15], r[16], r[19], r[23], r[41], r[42]) =
            (1.0, 1.0, 15.0, 100.0, 12.0, gun, 1000.0, 600.0, conceal, 60.0, 4.0);
        let mut s = Snapshot::default();
        s.load(&[id], &r);
        s.ships[0]
    }

    #[test]
    fn torpedoes_reach_and_fade() {
        let mut dd = ship(1, 10000.0, 6000.0);
        (dd.torp_range, dd.torp_speed, dd.torp_damage, dd.torp_reload, dd.torp_tubes, dd.torp_detect, dd.torp_bear_s) =
            (8000.0, 30.0, 10000.0, 60.0, 5.0, 1200.0, 8.0);
        let bb = ship(2, 20000.0, 15000.0);
        let (near, far) = (torp_salvo(&dd, &bb, 1000.0), torp_salvo(&dd, &bb, 7000.0));
        assert!(near > far && far > 0.0, "{near} {far}");
        assert_eq!(torp_salvo(&dd, &bb, 9000.0), 0.0);
        assert!(torp_rate(&dd, &bb, 1000.0, 50000.0) > torp_rate(&dd, &bb, 7000.0, 50000.0));
    }

    #[test]
    fn outranged_without_guns_stays_past_their_reach() {
        let mut dd = ship(1, 10000.0, 6000.0);
        (dd.torp_range, dd.torp_speed, dd.torp_damage, dd.torp_reload, dd.torp_tubes, dd.torp_detect, dd.torp_bear_s) =
            (8000.0, 30.0, 10000.0, 60.0, 5.0, 1200.0, 8.0);
        let bb = ship(2, 20000.0, 15000.0);
        let us = Side { ship: &dd, fire: None, k: 1.0, hp: 1000.0 };
        let them = Side { ship: &bb, fire: None, k: 1.0, hp: 1000.0 };
        let t = desired(&us, &them, 1.0, 0.0, 200.0);
        assert_eq!(t.desire, Desire::Win);
        assert!(t.range <= 8000.0, "{t:?}");
    }
}
