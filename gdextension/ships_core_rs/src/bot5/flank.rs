use godot::prelude::*;
use std::collections::HashSet;

use super::belief::Belief;
use super::params::Playstyle;

const LLOYD_ITERS: usize = 4;
const OWN_FLOOR: f32 = 0.25;
/// A flank is short-handed past this pressure, and only against one this many times calmer.
const REBALANCE_P: f32 = 1.5;
const REBALANCE_RATIO: f32 = 2.0;
const REBALANCE_GAP_S: f64 = 30.0;
const ROLE_HOLD_S: f64 = 60.0;
/// Aptitude level from which a bot leaves a live flank for a short-handed one, and for one nobody holds.
const REBALANCE_APT: i32 = 2;
const ABANDONED_APT: i32 = 1;
/// How far a seam ship's approach point sits from its own depth toward the anchor's.
const SEAM_DEPTH: f32 = 0.5;
pub const IMBALANCED: f32 = 2.0;
/// Neighbouring flanks closer than this across the front merge; a gap this wide inside one splits it.
const MERGE_M: f32 = 4000.0;
const SPLIT_GAP_M: f32 = 7000.0;
/// Each side of a split holds at least this much enemy (a full-HP ship is 1).
const SPLIT_MIN_W: f32 = 1.0;
const RESHAPE_S: f64 = 10.0;
const MAX_GROUPS: usize = 4;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Flank(usize),
    /// Between flanks j and j+1: fights either, from the side, for crossfire.
    Seam(usize),
}

impl Role {
    pub fn covers(self, g: usize) -> bool {
        match self {
            Role::Flank(f) => f == g,
            Role::Seam(j) => g == j || g == j + 1,
        }
    }

    pub fn label(self) -> String {
        match self {
            Role::Flank(f) => format!("flank {f}"),
            Role::Seam(j) => format!("seam {j}|{}", j + 1),
        }
    }
}

#[derive(Clone, Default)]
pub struct Group {
    pub u: f32,
    pub centre: Vector2,
    pub enemy: f32,
    pub own: f32,
    pub ids: Vec<i64>,
    pub presumed: Vec<Vector2>,
    /// Members' (lateral, weight).
    lats: Vec<(f32, f32)>,
    /// Since when this group and the next have been mergeable, and this one splittable.
    merge_since: Option<f64>,
    split_since: Option<f64>,
}

impl Group {
    pub fn live(&self) -> bool {
        self.enemy > 0.0
    }

    pub fn pressure(&self) -> f32 {
        self.enemy / self.own.max(OWN_FLOOR)
    }
}

#[derive(Clone, Copy)]
pub struct SeamGeom {
    origin: Vector2,
    fwd: Vector2,
    right: Vector2,
    u: f32,
}

impl SeamGeom {
    pub fn point(&self, me: Vector2, anchor: Vector2) -> Vector2 {
        let v = |p: Vector2| (p - self.origin).dot(self.fwd);
        let depth = v(me) + (v(anchor) - v(me)) * SEAM_DEPTH;
        self.origin + self.right * self.u + self.fwd * depth
    }

    /// Signed distance across the front from the seam line.
    pub fn lateral(&self, p: Vector2) -> f32 {
        (p - self.origin).dot(self.right) - self.u
    }
}

pub struct Seat {
    pub idx: usize,
    pub pos: Vector2,
    pub hp: f32,
    pub apt: i32,
    pub style: Playstyle,
    pub role: Option<Role>,
    pub since: f64,
}

#[derive(Clone, Copy)]
enum Reshape {
    Merge(usize),
    Split(usize),
}

/// The enemy line split across the front into groups, from team belief only.
pub struct Flanks {
    origin: Vector2,
    fwd: Vector2,
    right: Vector2,
    k: usize,
    pub groups: Vec<Group>,
    last_switch: f64,
    pending: Vec<Reshape>,
}

impl Flanks {
    pub fn new(own: Vector2, enemy: Vector2, n_enemy: usize) -> Self {
        let fwd = (enemy - own).normalized_or_zero();
        let k = if n_enemy >= 9 { 3 } else if n_enemy >= 3 { 2 } else { 1 };
        Flanks { origin: own, fwd, right: Vector2::new(fwd.y, -fwd.x), k, groups: Vec::new(), last_switch: f64::NEG_INFINITY, pending: Vec::new() }
    }

    pub fn lat(&self, p: Vector2) -> f32 {
        (p - self.origin).dot(self.right)
    }

    pub fn seam(&self, j: usize) -> Option<SeamGeom> {
        let (a, b) = (self.groups.get(j)?, self.groups.get(j + 1)?);
        Some(SeamGeom { origin: self.origin, fwd: self.fwd, right: self.right, u: (a.u + b.u) * 0.5 })
    }

    fn gap_u(&self, j: usize) -> f32 {
        (self.groups[j].u + self.groups[j + 1].u) * 0.5
    }

    /// Contacts count at their last position however old: a flank dies when its ships sink, not when we lose them.
    pub fn update(&mut self, belief: &Belief, now: f64) {
        let pts: Vec<(Vector2, f32, Option<i64>)> = belief.contacts.iter()
            .map(|(&id, c)| (c.last_pos, c.last_hp.max(0.05), Some(id)))
            .chain(belief.presumed.iter().map(|r| (r.pos, 1.0, None)))
            .collect();
        if self.groups.is_empty() {
            if pts.is_empty() {
                return;
            }
            let mut sorted: Vec<f32> = pts.iter().map(|p| self.lat(p.0)).collect();
            sorted.sort_by(f32::total_cmp);
            let k = self.k.min(sorted.len());
            self.groups = (0..k).map(|i| Group { u: sorted[(2 * i + 1) * sorted.len() / (2 * k)], ..Default::default() }).collect();
        }
        self.cluster(&pts);
        if let Some(r) = self.reshape(now) {
            self.pending.push(r);
            self.cluster(&pts);
        }
    }

    fn cluster(&mut self, pts: &[(Vector2, f32, Option<i64>)]) {
        let us: Vec<f32> = pts.iter().map(|p| self.lat(p.0)).collect();
        let nearest = |gs: &[Group], u: f32| (0..gs.len()).min_by(|&a, &b| (gs[a].u - u).abs().total_cmp(&(gs[b].u - u).abs())).unwrap();
        let mut of = vec![0usize; pts.len()];
        for _ in 0..LLOYD_ITERS {
            let mut acc = vec![(0.0f32, 0.0f32); self.groups.len()];
            for (i, &u) in us.iter().enumerate() {
                of[i] = nearest(&self.groups, u);
                acc[of[i]].0 += u * pts[i].1;
                acc[of[i]].1 += pts[i].1;
            }
            for (g, (s, w)) in self.groups.iter_mut().zip(acc) {
                if w > 0.0 {
                    g.u = s / w;
                }
            }
        }
        for g in self.groups.iter_mut() {
            g.enemy = 0.0;
            g.ids.clear();
            g.presumed.clear();
            g.lats.clear();
        }
        let mut sum = vec![Vector2::ZERO; self.groups.len()];
        for (i, &(p, w, id)) in pts.iter().enumerate() {
            let g = &mut self.groups[of[i]];
            g.enemy += w;
            g.lats.push((us[i], w));
            sum[of[i]] += p * w;
            match id {
                Some(id) => g.ids.push(id),
                None => g.presumed.push(p),
            }
        }
        for (g, s) in self.groups.iter_mut().zip(sum) {
            if g.enemy > 0.0 {
                g.centre = s / g.enemy;
            }
            g.lats.sort_by(|a, b| a.0.total_cmp(&b.0));
        }
    }

    /// At most one merge or split, each only after holding RESHAPE_S; a dead group merges at once.
    fn reshape(&mut self, now: f64) -> Option<Reshape> {
        let n = self.groups.len();
        let mut merge = None;
        for j in 0..n.saturating_sub(1) {
            let (a, b) = (&self.groups[j], &self.groups[j + 1]);
            let dead = !a.live() || !b.live();
            let close = dead || (b.u - a.u).abs() < MERGE_M;
            let since = if close { Some(a.merge_since.unwrap_or(now)) } else { None };
            self.groups[j].merge_since = since;
            if merge.is_none() && since.is_some_and(|t| dead || now - t >= RESHAPE_S) {
                merge = Some(j);
            }
        }
        if let Some(j) = merge {
            let b = self.groups.remove(j + 1);
            let a = &mut self.groups[j];
            let w = a.enemy + b.enemy;
            a.u = if w > 0.0 { (a.u * a.enemy + b.u * b.enemy) / w } else { (a.u + b.u) * 0.5 };
            self.reset_timers();
            return Some(Reshape::Merge(j));
        }
        let mut split = None;
        for g in 0..n {
            let cut = (n < MAX_GROUPS).then(|| split_cut(&self.groups[g].lats)).flatten();
            let since = cut.map(|_| self.groups[g].split_since.unwrap_or(now));
            self.groups[g].split_since = since;
            if split.is_none() && since.is_some_and(|t| now - t >= RESHAPE_S) {
                split = cut.map(|c| (g, c));
            }
        }
        let (g, cut) = split?;
        let side = |left: bool| {
            let it = self.groups[g].lats.iter().filter(|l| (l.0 < cut) == left);
            let (s, w) = it.fold((0.0, 0.0), |(s, w), l| (s + l.0 * l.1, w + l.1));
            s / w
        };
        let (lu, ru) = (side(true), side(false));
        self.groups[g].u = lu;
        self.groups.insert(g + 1, Group { u: ru, centre: self.groups[g].centre, ..Default::default() });
        self.reset_timers();
        Some(Reshape::Split(g))
    }

    fn reset_timers(&mut self) {
        for g in self.groups.iter_mut() {
            g.merge_since = None;
            g.split_since = None;
        }
    }

    fn nearest_live(&self, u: f32) -> Option<usize> {
        (0..self.groups.len()).filter(|&g| self.groups[g].live())
            .min_by(|&a, &b| (self.groups[a].u - u).abs().total_cmp(&(self.groups[b].u - u).abs()))
    }

    fn tally_own(&mut self, seats: &[Seat]) {
        for g in self.groups.iter_mut() {
            g.own = 0.0;
        }
        for s in seats {
            match s.role {
                Some(Role::Flank(f)) => self.groups[f].own += s.hp,
                Some(Role::Seam(j)) => {
                    self.groups[j].own += s.hp * 0.5;
                    self.groups[j + 1].own += s.hp * 0.5;
                }
                None => {}
            }
        }
    }

    fn seams_allowed(&self, seats: &[Seat]) -> bool {
        self.groups.len() > 1 && seats.len() > 2 * self.groups.len()
    }

    /// Renumbers roles for a merge or split; a split flank's bots are dealt to its halves by enemy share.
    fn remap(&self, r: Reshape, seats: &mut [Seat], now: f64) {
        match r {
            Reshape::Merge(j) => {
                for s in seats.iter_mut() {
                    s.role = s.role.map(|r| match r {
                        Role::Flank(f) if f > j => Role::Flank(f - 1),
                        Role::Seam(x) if x == j => Role::Flank(j),
                        Role::Seam(x) if x > j => Role::Seam(x - 1),
                        r => r,
                    });
                }
            }
            Reshape::Split(g) => {
                let mut on: Vec<usize> = Vec::new();
                for (i, s) in seats.iter_mut().enumerate() {
                    s.role = s.role.map(|r| match r {
                        Role::Flank(f) if f > g => Role::Flank(f + 1),
                        Role::Seam(x) if x >= g => Role::Seam(x + 1),
                        r => r,
                    });
                    if s.role == Some(Role::Flank(g)) {
                        on.push(i);
                    }
                }
                self.deal(seats, on, &[g, g + 1], now);
            }
        }
    }

    /// `idx` in lateral order onto `groups` by quotas proportional to their enemy, at least one each if enough.
    fn deal(&self, seats: &mut [Seat], mut idx: Vec<usize>, groups: &[usize], now: f64) {
        if groups.is_empty() {
            return;
        }
        idx.sort_by(|&a, &b| self.lat(seats[a].pos).total_cmp(&self.lat(seats[b].pos)));
        let w: Vec<f32> = groups.iter().map(|&g| self.groups[g].enemy).collect();
        let mut quota = quotas(idx.len(), &w);
        let mut q = 0;
        for i in idx {
            while q + 1 < groups.len() && quota[q] == 0 {
                q += 1;
            }
            quota[q] = quota[q].saturating_sub(1);
            if seats[i].role != Some(Role::Flank(groups[q])) {
                seats[i].role = Some(Role::Flank(groups[q]));
                seats[i].since = now;
            }
        }
    }

    /// Sets missing roles, applies merges and splits, frees bots off dead flanks, fills empty seams,
    /// and moves at most one able bot to a short-handed flank.
    pub fn assign(&mut self, seats: &mut [Seat], now: f64) -> Vec<&'static str> {
        let mut why = Vec::new();
        if self.groups.is_empty() || seats.is_empty() {
            return why;
        }
        for r in std::mem::take(&mut self.pending) {
            self.remap(r, seats, now);
            why.push(match r {
                Reshape::Merge(_) => "flank_merge",
                Reshape::Split(_) => "flank_split",
            });
        }
        if seats.iter().all(|s| s.role.is_none()) {
            self.initial(seats, now);
            why.push("flank_assign");
        }
        for i in 0..seats.len() {
            let u = self.lat(seats[i].pos);
            let role = match seats[i].role {
                None => self.nearest_live(u).map(|g| (Role::Flank(g), "flank_join")),
                Some(Role::Flank(f)) if !self.groups[f].live() => self.nearest_live(u).map(|g| (Role::Flank(g), "flank_collapse")),
                Some(Role::Seam(j)) => match (self.groups[j].live(), self.groups[j + 1].live()) {
                    (true, true) => None,
                    (true, false) => Some((Role::Flank(j), "seam_collapse")),
                    (false, true) => Some((Role::Flank(j + 1), "seam_collapse")),
                    (false, false) => self.nearest_live(u).map(|g| (Role::Flank(g), "seam_collapse")),
                },
                _ => None,
            };
            if let Some((r, w)) = role {
                seats[i].role = Some(r);
                seats[i].since = now;
                why.push(w);
            }
        }
        why.extend(self.fill_seams(seats, now));
        self.tally_own(seats);
        if now - self.last_switch >= REBALANCE_GAP_S {
            if let Some(w) = self.rebalance(seats, now) {
                why.push(w);
            }
        }
        why
    }

    /// A live gap without a seam ship takes the non-brawler nearest it from a neighbouring flank that keeps another ship.
    fn fill_seams(&self, seats: &mut [Seat], now: f64) -> Vec<&'static str> {
        let mut why = Vec::new();
        if !self.seams_allowed(seats) {
            return why;
        }
        for j in 0..self.groups.len() - 1 {
            if !self.groups[j].live() || !self.groups[j + 1].live() || seats.iter().any(|s| s.role == Some(Role::Seam(j))) {
                continue;
            }
            let count = |f: usize| seats.iter().filter(|s| s.role == Some(Role::Flank(f))).count();
            let su = self.gap_u(j);
            let pick = (0..seats.len())
                .filter(|&i| seats[i].style != Playstyle::Brawler)
                .filter(|&i| matches!(seats[i].role, Some(Role::Flank(f)) if (f == j || f == j + 1) && count(f) > 1))
                .min_by(|&a, &b| (self.lat(seats[a].pos) - su).abs().total_cmp(&(self.lat(seats[b].pos) - su).abs()));
            if let Some(i) = pick {
                seats[i].role = Some(Role::Seam(j));
                seats[i].since = now;
                why.push("seam_fill");
            }
        }
        why
    }

    fn rebalance(&mut self, seats: &mut [Seat], now: f64) -> Option<&'static str> {
        let live: Vec<usize> = (0..self.groups.len()).filter(|&g| self.groups[g].live()).collect();
        let p = |g: usize| self.groups[g].pressure();
        let hi = live.iter().copied().max_by(|&a, &b| p(a).total_cmp(&p(b)))?;
        let lo = live.iter().copied().min_by(|&a, &b| p(a).total_cmp(&p(b)))?;
        let abandoned = self.groups[hi].own < OWN_FLOOR;
        if hi == lo || p(hi) < REBALANCE_P || p(hi) < REBALANCE_RATIO * p(lo) {
            return None;
        }
        let (gl, gh) = (&self.groups[lo], &self.groups[hi]);
        let apt = if abandoned { ABANDONED_APT } else { REBALANCE_APT };
        let mover = seats.iter().enumerate()
            .filter(|(_, s)| s.role == Some(Role::Flank(lo)) && s.apt >= apt && now - s.since >= ROLE_HOLD_S)
            .filter(|(_, s)| gl.enemy / (gl.own - s.hp).max(OWN_FLOOR) < gh.pressure())
            .max_by(|a, b| a.1.apt.cmp(&b.1.apt)
                .then((self.lat(b.1.pos) - gh.u).abs().total_cmp(&(self.lat(a.1.pos) - gh.u).abs())))
            .map(|(i, _)| i)?;
        seats[mover].role = Some(Role::Flank(hi));
        seats[mover].since = now;
        self.last_switch = now;
        self.tally_own(seats);
        Some(if abandoned { "flank_abandoned" } else { "flank_rebalance" })
    }

    /// Seam ships nearest each gap, then the rest in lateral order by each flank's share of the enemy.
    fn initial(&mut self, seats: &mut [Seat], now: f64) {
        if self.seams_allowed(seats) {
            for j in 0..self.groups.len() - 1 {
                let su = self.gap_u(j);
                let pick = (0..seats.len())
                    .filter(|&i| seats[i].role.is_none() && seats[i].style != Playstyle::Brawler)
                    .min_by(|&a, &b| (self.lat(seats[a].pos) - su).abs().total_cmp(&(self.lat(seats[b].pos) - su).abs()));
                if let Some(i) = pick {
                    seats[i].role = Some(Role::Seam(j));
                    seats[i].since = now;
                }
            }
        }
        let rest: Vec<usize> = (0..seats.len()).filter(|&i| seats[i].role.is_none()).collect();
        let live: Vec<usize> = (0..self.groups.len()).filter(|&g| self.groups[g].live()).collect();
        self.deal(seats, rest, &live, now);
    }

    /// Ids covered by `r`, and the centre of the nearest live group it covers.
    pub fn view(&self, r: Role, me: Vector2) -> (HashSet<i64>, Option<Vector2>) {
        let covered = || self.groups.iter().enumerate().filter(|(g, _)| r.covers(*g)).map(|(_, grp)| grp);
        let ids = covered().flat_map(|g| g.ids.iter().copied()).collect();
        let centre = covered().filter(|g| g.live()).map(|g| g.centre)
            .min_by(|a, b| a.distance_to(me).total_cmp(&b.distance_to(me)));
        (ids, centre)
    }
}

/// The widest gap between sorted members past SPLIT_GAP_M with SPLIT_MIN_W either side: its midpoint.
fn split_cut(lats: &[(f32, f32)]) -> Option<f32> {
    let total: f32 = lats.iter().map(|l| l.1).sum();
    let mut left = 0.0;
    let mut best: Option<(f32, f32)> = None;
    for w in lats.windows(2) {
        left += w[0].1;
        let gap = w[1].0 - w[0].0;
        if gap > SPLIT_GAP_M && left >= SPLIT_MIN_W && total - left >= SPLIT_MIN_W && best.is_none_or(|b| gap > b.0) {
            best = Some((gap, (w[0].0 + w[1].0) * 0.5));
        }
    }
    best.map(|b| b.1)
}

/// Largest-remainder shares of `m` by `w`, at least one each when `m` covers them all.
fn quotas(m: usize, w: &[f32]) -> Vec<usize> {
    let n = w.len();
    let base = if m >= n { 1 } else { 0 };
    let spare = m - base * n;
    let total: f32 = w.iter().sum();
    let share: Vec<f32> = w.iter().map(|&x| if total > 0.0 { spare as f32 * x / total } else { spare as f32 / n as f32 }).collect();
    let mut quota: Vec<usize> = share.iter().map(|s| base + s.floor() as usize).collect();
    let mut left = m - quota.iter().sum::<usize>();
    let mut by_rem: Vec<usize> = (0..n).collect();
    by_rem.sort_by(|&a, &b| (share[b] - share[b].floor()).total_cmp(&(share[a] - share[a].floor())));
    for &q in by_rem.iter().cycle() {
        if left == 0 {
            break;
        }
        quota[q] += 1;
        left -= 1;
    }
    quota
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_cut_needs_weight_both_sides() {
        let l = [(0.0, 1.0), (500.0, 1.0), (9000.0, 1.0)];
        assert_eq!(split_cut(&l), Some(4750.0));
        assert_eq!(split_cut(&[(0.0, 1.0), (9000.0, 0.5)]), None);
        assert_eq!(split_cut(&[(0.0, 1.0), (3000.0, 1.0)]), None);
    }

    fn seat(idx: usize, x: f32, role: Role) -> Seat {
        Seat { idx, pos: Vector2::new(x, 0.0), hp: 1.0, apt: 1, style: Playstyle::Dps, role: Some(role), since: 0.0 }
    }

    fn pts(xs: &[f32]) -> Vec<(Vector2, f32, Option<i64>)> {
        xs.iter().enumerate().map(|(i, &x)| (Vector2::new(x, 10000.0), 1.0, Some(i as i64))).collect()
    }

    #[test]
    fn split_after_hold_and_deal_halves() {
        let mut f = Flanks::new(Vector2::ZERO, Vector2::new(0.0, 20000.0), 4);
        f.groups = vec![Group { u: 4000.0, ..Default::default() }];
        let p = pts(&[0.0, 500.0, 9000.0, 9500.0]);
        f.cluster(&p);
        assert!(f.reshape(0.0).is_none());
        assert!(matches!(f.reshape(RESHAPE_S), Some(Reshape::Split(0))));
        f.cluster(&p);
        assert_eq!(f.groups.len(), 2);
        assert!(f.groups[0].u < f.groups[1].u);
        let mut seats = vec![seat(0, 0.0, Role::Flank(0)), seat(1, 9000.0, Role::Flank(0))];
        f.remap(Reshape::Split(0), &mut seats, 1.0);
        assert_eq!(seats[0].role, Some(Role::Flank(0)));
        assert_eq!(seats[1].role, Some(Role::Flank(1)));
    }

    #[test]
    fn merge_close_and_renumber() {
        let mut f = Flanks::new(Vector2::ZERO, Vector2::new(0.0, 20000.0), 6);
        f.groups = vec![Group { u: 0.0, ..Default::default() }, Group { u: 3000.0, ..Default::default() }, Group { u: 20000.0, ..Default::default() }];
        let p = pts(&[0.0, 300.0, 3000.0, 3300.0, 20000.0, 20300.0]);
        f.cluster(&p);
        assert!(f.reshape(0.0).is_none());
        assert!(matches!(f.reshape(RESHAPE_S), Some(Reshape::Merge(0))));
        assert_eq!(f.groups.len(), 2);
        let mut seats = vec![seat(0, 0.0, Role::Seam(0)), seat(1, 3000.0, Role::Flank(1)), seat(2, 0.0, Role::Seam(1)), seat(3, 20000.0, Role::Flank(2))];
        f.remap(Reshape::Merge(0), &mut seats, 1.0);
        let r: Vec<_> = seats.iter().map(|s| s.role.unwrap()).collect();
        assert_eq!(r, vec![Role::Flank(0), Role::Flank(0), Role::Seam(0), Role::Flank(1)]);
    }

    #[test]
    fn quotas_sum_and_floor() {
        assert_eq!(quotas(5, &[3.0, 1.0]).iter().sum::<usize>(), 5);
        assert_eq!(quotas(2, &[3.0, 0.0, 1.0]).iter().sum::<usize>(), 2);
        assert!(quotas(4, &[10.0, 0.1]).iter().all(|&q| q >= 1));
    }
}
