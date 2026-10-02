use godot::prelude::*;

use crate::nav::reach::ReachLookup;
use crate::nav::visibility::VisibilityGrid;

/// 4-connected, so a wall follower can never slip diagonally between two blocked cells.
const DIRS: [(i32, i32); 4] = [(1, 0), (0, 1), (-1, 0), (0, -1)];

pub(crate) struct Enemy {
    pub pos: Vector2,
    pub cell: Option<usize>,
    /// Inside this we are seen.
    pub det_r: f32,
    /// Inside this, with line of sight, we see it.
    pub spot_r: f32,
    /// Inside this, with line of sight, it can see us to shoot (AVOID_LOS).
    pub los_r: f32,
    /// Its shells count for AVOID_FIRE.
    pub heavy: bool,
    pub shootable: bool,
}

/// Forbidden ground a walk keeps out of, besides land and shallows.
pub(crate) const AVOID_DET: u8 = 1;
pub(crate) const AVOID_LOS: u8 = 2;
pub(crate) const AVOID_FIRE: u8 = 4;

pub(crate) struct SpotInputs {
    pub enemies: Vec<Enemy>,
    pub clearance: f32,
    pub avoid: u8,
    /// AVOID_LOS also forbids cells within this many cells of a seen one: the
    /// hull wanders inside its hold radius and the grid is least sure at coasts.
    pub los_margin: i32,
    /// Goal is "my guns reach it" instead of "I see it".
    pub reach: Option<ReachLookup>,
    /// Enemy fire planes, for AVOID_FIRE.
    pub fire: Option<ReachLookup>,
}

pub(crate) struct WalkResult {
    pub start: Option<Vector2>,
    pub found: Option<(usize, u64)>,
    pub steps: u32,
    pub trails: [Vec<Vector2>; 2],
}

struct Walker {
    ix: i32,
    iz: i32,
    d: usize,
    /// Wall on the (d + 1) side when true, on the (d + 3) side otherwise.
    left: bool,
    /// Per water cell, a bit per direction it was entered with; a repeat means the walker is cycling.
    seen: Vec<u8>,
    done: bool,
}

impl VisibilityGrid {
    pub(crate) fn grid_of(&self, p: Vector2) -> (i32, i32) {
        (((p.x - self.min_x) / self.cell).floor() as i32, ((p.y - self.min_z) / self.cell).floor() as i32)
    }

    pub(crate) fn water(&self, ix: i32, iz: i32) -> Option<usize> {
        if ix < 0 || iz < 0 || ix >= self.w || iz >= self.h {
            return None;
        }
        let k = self.index[(iz * self.w + ix) as usize];
        (k >= 0).then_some(k as usize)
    }

    pub(crate) fn spot_free(&self, ix: i32, iz: i32, inp: &SpotInputs) -> Option<usize> {
        let k = self.water(ix, iz)?;
        if self.sdf_c[k] < inp.clearance || self.in_zone((ix, iz), inp) {
            return None;
        }
        Some(k)
    }

    /// Forbidden by the enemies alone, land aside, so a walk start is placed
    /// where the ray leaves the enemy's ground and not at the first island.
    fn in_zone(&self, c: (i32, i32), inp: &SpotInputs) -> bool {
        self.in_zone_of(c, inp, inp.avoid)
    }

    pub(crate) fn in_zone_of(&self, c: (i32, i32), inp: &SpotInputs, avoid: u8) -> bool {
        let p = Vector2::new(self.min_x + (c.0 as f32 + 0.5) * self.cell, self.min_z + (c.1 as f32 + 0.5) * self.cell);
        if avoid & AVOID_DET != 0 && inp.enemies.iter().any(|e| p.distance_squared_to(e.pos) < e.det_r * e.det_r) {
            return true;
        }
        if avoid & AVOID_FIRE != 0 {
            if let Some(f) = &inp.fire {
                if inp.enemies.iter().enumerate().any(|(i, e)| e.heavy && f.hits(i, p)) {
                    return true;
                }
            }
        }
        if avoid & AVOID_LOS != 0 && self.water(c.0, c.1).is_some() {
            let m = inp.los_margin.max(0);
            for dz in -m..=m {
                for dx in -m..=m {
                    let Some(k) = self.water(c.0 + dx, c.1 + dz) else { continue };
                    let q = self.centres[k];
                    if inp.enemies.iter().any(|e| {
                        e.cell.is_some_and(|ec| q.distance_squared_to(e.pos) <= e.los_r * e.los_r && self.visible_idx(k, ec))
                    }) {
                        return true;
                    }
                }
            }
        }
        false
    }

    pub(crate) fn spotted_mask(&self, k: usize, inp: &SpotInputs) -> u64 {
        let c = self.centres[k];
        let mut mask = 0u64;
        for (i, e) in inp.enemies.iter().enumerate().take(64) {
            if !e.shootable {
                continue;
            }
            let hit = match &inp.reach {
                Some(r) => r.hits(i, c),
                None => e.cell.is_some_and(|ec| c.distance_squared_to(e.pos) <= e.spot_r * e.spot_r && self.visible_idx(k, ec)),
            };
            if hit {
                mask |= 1u64 << i;
            }
        }
        mask
    }

    /// Cells crossed from `a` along `dir` until the grid edge, 4-connected.
    fn ray_cells(&self, a: Vector2, dir: Vector2) -> Vec<(i32, i32)> {
        let (mut ix, mut iz) = self.grid_of(a);
        let gx = (a.x - self.min_x) / self.cell;
        let gz = (a.y - self.min_z) / self.cell;
        let axis = |g: f32, i: i32, d: f32| -> (i32, f32, f32) {
            if d > 1e-6 {
                (1, (i as f32 + 1.0 - g) / d, 1.0 / d)
            } else if d < -1e-6 {
                (-1, (g - i as f32) / -d, 1.0 / -d)
            } else {
                (0, f32::INFINITY, f32::INFINITY)
            }
        };
        let (sx, mut tx, dtx) = axis(gx, ix, dir.x);
        let (sz, mut tz, dtz) = axis(gz, iz, dir.y);
        let mut out = Vec::new();
        while ix >= 0 && iz >= 0 && ix < self.w && iz < self.h {
            out.push((ix, iz));
            if tx < tz {
                ix += sx;
                tx += dtx;
            } else {
                iz += sz;
                tz += dtz;
            }
        }
        out
    }

    /// The perimeter cell to start from and the direction of the wall beside it.
    /// Outward: where the ray from `from` through `toward` leaves forbidden ground.
    /// Inward: last free cell before blocked ground on the way from `from` toward `toward`.
    fn walk_start(&self, from: Vector2, toward: Vector2, outward: bool, inp: &SpotInputs) -> Option<(i32, i32, usize)> {
        let dir = (toward - from).try_normalized()?;
        let cells = self.ray_cells(from, dir);
        let dir_of = |a: (i32, i32), b: (i32, i32)| DIRS.iter().position(|&d| (a.0 + d.0, a.1 + d.1) == b);
        if outward {
            // Last exit from forbidden ground before `toward`, so a pocket inside it is skipped.
            let goal = self.grid_of(toward);
            let at_goal = cells.iter().position(|&c| c == goal).unwrap_or(cells.len());
            let mut pick = None;
            for i in 1..cells.len() {
                if self.in_zone(cells[i - 1], inp) && !self.in_zone(cells[i], inp) {
                    pick = Some(i);
                    if i >= at_goal {
                        break;
                    }
                }
            }
            let mut i = pick?;
            while self.spot_free(cells[i].0, cells[i].1, inp).is_none() {
                i += 1;
                if i >= cells.len() {
                    return None;
                }
            }
            return Some((cells[i].0, cells[i].1, dir_of(cells[i], cells[i - 1])?));
        }
        self.spot_free(cells.first()?.0, cells.first()?.1, inp)?;
        for w in cells.windows(2) {
            if self.spot_free(w[1].0, w[1].1, inp).is_none() {
                return Some((w[0].0, w[0].1, dir_of(w[0], w[1])?));
            }
        }
        None
    }

    fn step(&self, wk: &mut Walker, inp: &SpotInputs) -> Option<usize> {
        let order = if wk.left {
            [(wk.d + 1) % 4, wk.d, (wk.d + 3) % 4, (wk.d + 2) % 4]
        } else {
            [(wk.d + 3) % 4, wk.d, (wk.d + 1) % 4, (wk.d + 2) % 4]
        };
        for nd in order {
            let (nx, nz) = (wk.ix + DIRS[nd].0, wk.iz + DIRS[nd].1);
            if let Some(k) = self.spot_free(nx, nz, inp) {
                wk.ix = nx;
                wk.iz = nz;
                wk.d = nd;
                if wk.seen[k] & (1 << nd) != 0 {
                    wk.done = true;
                    return None;
                }
                wk.seen[k] |= 1 << nd;
                return Some(k);
            }
        }
        wk.done = true;
        None
    }

    /// Two wall followers leave the start in opposite directions along the edge of
    /// blocked ground (the `avoid` set, land, the map edge); the one heading
    /// toward `flank` takes two steps for each of the other's. Stops at the first
    /// cell that spots at least `need` shootable enemies.
    pub(crate) fn spot_walk_impl(
        &self,
        from: Vector2,
        toward: Vector2,
        outward: bool,
        inp: &SpotInputs,
        need: u32,
        budget_m: f32,
        flank: Vector2,
    ) -> WalkResult {
        let mut res = WalkResult { start: None, found: None, steps: 0, trails: [Vec::new(), Vec::new()] };
        let Some((sx, sz, wall)) = self.walk_start(from, toward, outward, inp) else { return res };
        let k0 = self.spot_free(sx, sz, inp).unwrap();
        res.start = Some(self.centres[k0]);
        let m0 = self.spotted_mask(k0, inp);
        if m0.count_ones() >= need {
            res.found = Some((k0, m0));
            return res;
        }
        let mk = |left: bool| {
            let d = if left { (wall + 3) % 4 } else { (wall + 1) % 4 };
            Walker { ix: sx, iz: sz, d, left, seen: vec![0u8; self.centres.len()], done: false }
        };
        let mut w = [mk(true), mk(false)];
        let tangent = |wk: &Walker| Vector2::new(DIRS[wk.d].0 as f32, DIRS[wk.d].1 as f32);
        let flank_first = if flank.length_squared() > 0.0 { if tangent(&w[0]).dot(flank) >= 0.0 { 0 } else { 1 } } else { 0 };
        let pattern: &[usize] = if flank.length_squared() > 0.0 {
            &[flank_first, flank_first, 1 - flank_first]
        } else {
            &[0, 1]
        };
        let max_steps = if budget_m > 0.0 { (budget_m / self.cell).ceil() as u32 } else { u32::MAX };
        let mut turn = 0usize;
        while res.steps < max_steps && !(w[0].done && w[1].done) {
            let mut i = pattern[turn % pattern.len()];
            turn += 1;
            if w[i].done {
                i = 1 - i;
            }
            let Some(k) = self.step(&mut w[i], inp) else { continue };
            res.steps += 1;
            res.trails[i].push(self.centres[k]);
            let m = self.spotted_mask(k, inp);
            if m.count_ones() >= need {
                res.found = Some((k, m));
                return res;
            }
        }
        res
    }

    /// Whether `pos` is allowed, and what it spots.
    pub(crate) fn spot_eval_impl(&self, pos: Vector2, inp: &SpotInputs) -> (bool, u64) {
        let (ix, iz) = self.grid_of(pos);
        match self.spot_free(ix, iz, inp) {
            Some(k) => (true, self.spotted_mask(k, inp)),
            None => (false, 0),
        }
    }
}
