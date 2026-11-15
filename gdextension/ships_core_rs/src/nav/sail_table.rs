//! Water route length between every pair of coarse cells, for scoring how far a contact is to sail to.

use godot::prelude::*;
use rayon::prelude::*;
use std::cmp::Reverse;
use std::collections::BinaryHeap;

use crate::nav::reach::nav_pool;
use crate::nav::visibility::VisibilityGrid;

/// Whole cells would count a diagonal step as one, understating routes by up to 41%.
const UNITS_PER_CELL: f32 = 10.0;
/// An eight-way grid route runs this much longer than the smoothed path a ship sails.
const GRID_STRETCH: f32 = 1.04;
const NO_ROUTE: u16 = u16::MAX;
pub(crate) const NO_NEIGHBOUR: u32 = u32::MAX;

pub(crate) struct SailTable {
    cell: f32,
    w: i32,
    h: i32,
    /// Node per coarse cell, -1 on land.
    node: Vec<i32>,
    /// Per node, the fine water cell it is measured from.
    rep: Vec<u32>,
    /// Upper triangle by node.
    dist: Vec<u16>,
}

impl SailTable {
    fn layout(g: &VisibilityGrid, cell: f32) -> Self {
        let span = g.cell * g.w as f32;
        let (w, h) = ((span / cell).ceil() as i32, (g.cell * g.h as f32 / cell).ceil() as i32);
        let mut nearest = vec![(f32::INFINITY, NO_NEIGHBOUR); (w * h) as usize];
        for (k, c) in g.centres.iter().enumerate() {
            let (ix, iz) = (((c.x - g.min_x) / cell).floor() as i32, ((c.y - g.min_z) / cell).floor() as i32);
            let mid = Vector2::new(g.min_x + (ix as f32 + 0.5) * cell, g.min_z + (iz as f32 + 0.5) * cell);
            let slot = &mut nearest[(iz.clamp(0, h - 1) * w + ix.clamp(0, w - 1)) as usize];
            let d = c.distance_squared_to(mid);
            if d < slot.0 {
                *slot = (d, k as u32);
            }
        }
        let (mut node, mut rep) = (vec![-1i32; nearest.len()], Vec::new());
        for (i, &(_, k)) in nearest.iter().enumerate() {
            if k != NO_NEIGHBOUR {
                node[i] = rep.len() as i32;
                rep.push(k);
            }
        }
        Self { cell, w, h, node, rep, dist: Vec::new() }
    }

    pub(crate) fn build(g: &VisibilityGrid, cell: f32) -> Self {
        let mut t = Self::layout(g, cell);
        let adj = adjacency(g);
        let (fine, unit, rep, n) = (g.cell, cell / UNITS_PER_CELL, &t.rep, t.rep.len());
        let rows: Vec<Vec<u16>> = nav_pool().install(|| {
            (0..n)
                .into_par_iter()
                .map_init(|| vec![f32::INFINITY; adj.len()], |dist, i| {
                    flood(&adj, rep[i] as usize, fine, dist);
                    rep[i..].iter().map(|&r| quantise(dist[r as usize], unit)).collect()
                })
                .collect()
        });
        t.dist = rows.into_iter().flatten().collect();
        t
    }

    pub(crate) fn from_bytes(g: &VisibilityGrid, cell: f32, b: &[u8]) -> Option<Self> {
        let mut t = Self::layout(g, cell);
        let n = t.rep.len();
        if b.len() != n * (n + 1) {
            return None;
        }
        t.dist = b.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        Some(t)
    }

    pub(crate) fn to_bytes(&self) -> Vec<u8> {
        self.dist.iter().flat_map(|v| v.to_le_bytes()).collect()
    }

    fn at(&self, i: usize, j: usize) -> u16 {
        let (a, b, n) = (i.min(j), i.max(j), self.rep.len());
        self.dist[a * n - a * a.saturating_sub(1) / 2 + b - a]
    }

    /// The node of fine cell `k`'s coarse cell, else the nearest round it that `k` sees: an island can split a coarse cell.
    fn node_of(&self, g: &VisibilityGrid, k: usize) -> Option<usize> {
        let c = g.centres[k];
        let (ix, iz) = (((c.x - g.min_x) / self.cell).floor() as i32, ((c.y - g.min_z) / self.cell).floor() as i32);
        let at = |x: i32, z: i32| (x >= 0 && z >= 0 && x < self.w && z < self.h)
            .then(|| self.node[(z * self.w + x) as usize]).filter(|&n| n >= 0).map(|n| n as usize);
        let seen = |n: usize| g.visible_idx(k, self.rep[n] as usize);
        let own = at(ix, iz);
        if own.is_some_and(seen) {
            return own;
        }
        let mut best: Option<(f32, usize)> = None;
        for dz in -1..=1 {
            for dx in -1..=1 {
                if let Some(n) = at(ix + dx, iz + dz).filter(|&n| seen(n)) {
                    let d = g.centres[self.rep[n] as usize].distance_squared_to(c);
                    if best.is_none_or(|b| d < b.0) {
                        best = Some((d, n));
                    }
                }
            }
        }
        best.map(|b| b.1).or(own)
    }

    /// Metres by water from `a` to `b`: straight where one sees the other, the straight line too where no route joins them.
    pub(crate) fn sail_m(&self, g: &VisibilityGrid, a: Vector2, b: Vector2) -> f32 {
        let straight = a.distance_to(b);
        let (Some(ka), Some(kb)) = (g.cell_of(a), g.cell_of(b)) else { return straight };
        if g.visible_idx(ka, kb) {
            return straight;
        }
        let (Some(na), Some(nb)) = (self.node_of(g, ka), self.node_of(g, kb)) else { return straight };
        match self.at(na, nb) {
            NO_ROUTE => straight,
            d => (d as f32 * self.cell / UNITS_PER_CELL).max(straight),
        }
    }
}

fn quantise(d: f32, unit: f32) -> u16 {
    if d.is_finite() { (d / GRID_STRETCH / unit).round().min((NO_ROUTE - 1) as f32) as u16 } else { NO_ROUTE }
}

/// Per fine cell its water neighbours: four straight, then four diagonal.
pub(crate) fn adjacency(g: &VisibilityGrid) -> Vec<[u32; 8]> {
    let at = |x: i32, z: i32| {
        if x < 0 || z < 0 || x >= g.w || z >= g.h {
            return NO_NEIGHBOUR;
        }
        let k = g.index[(z * g.w + x) as usize];
        if k >= 0 { k as u32 } else { NO_NEIGHBOUR }
    };
    g.centres.iter().map(|c| {
        let (x, z) = (((c.x - g.min_x) / g.cell).floor() as i32, ((c.y - g.min_z) / g.cell).floor() as i32);
        [at(x + 1, z), at(x - 1, z), at(x, z + 1), at(x, z - 1), at(x + 1, z + 1), at(x + 1, z - 1), at(x - 1, z + 1), at(x - 1, z - 1)]
    }).collect()
}

fn flood(adj: &[[u32; 8]], start: usize, cell: f32, dist: &mut [f32]) {
    dist.fill(f32::INFINITY);
    dist[start] = 0.0;
    let mut heap = BinaryHeap::new();
    heap.push(Reverse((0u32, start)));
    while let Some(Reverse((bits, k))) = heap.pop() {
        let d = f32::from_bits(bits);
        if d > dist[k] {
            continue;
        }
        for (slot, &n) in adj[k].iter().enumerate() {
            if n == NO_NEIGHBOUR {
                continue;
            }
            let nd = d + cell * if slot < 4 { 1.0 } else { std::f32::consts::SQRT_2 };
            if nd < dist[n as usize] {
                dist[n as usize] = nd;
                heap.push(Reverse((nd.to_bits(), n as usize)));
            }
        }
    }
}
