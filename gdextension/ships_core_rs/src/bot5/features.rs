use godot::prelude::*;
use std::cmp::Reverse;
use std::collections::BinaryHeap;

use crate::nav::sail_table::NO_NEIGHBOUR;
use crate::nav::visibility::VisibilityGrid;

use super::field::Layout;

/// Water this near land is an island's berth: cover lies along it.
const BERTH_M: f32 = 900.0;
/// Where two islands' nearest-water regions meet within this of both: a channel between them.
const GAP_M: f32 = 3000.0;
/// Narrower channels are berths already.
const GAP_MIN_M: f32 = 600.0;
const LATTICE: i32 = 4;
const NONE: u16 = u16::MAX;

pub struct Island {
    pub centre: Vector2,
    /// Berth cells with their bearing from the centre, sorted by bearing.
    pub berths: Vec<(f32, u32)>,
    /// Farthest berth from the centre.
    pub radius: f32,
}

/// Where stations are looked for, per map: island berths (cover), gaps between islands (spotting), and an open-water lattice.
pub struct Features {
    pub islands: Vec<Island>,
    pub gaps: Vec<u32>,
    pub lattice: Vec<u32>,
    /// Per water cell its nearest island, NONE when unreachable.
    pub island_of: Vec<u16>,
}

impl Features {
    pub fn build(v: &VisibilityGrid, lay: &Layout) -> Features {
        let (w, h) = (v.w, v.h);
        let land = |x: i32, z: i32| x >= 0 && z >= 0 && x < w && z < h && v.index[(z * w + x) as usize] < 0;
        let mut comp = vec![NONE; (w * h) as usize];
        let mut sums: Vec<(Vector2, f32)> = Vec::new();
        for z in 0..h {
            for x in 0..w {
                if !land(x, z) || comp[(z * w + x) as usize] != NONE || sums.len() >= NONE as usize {
                    continue;
                }
                let id = sums.len() as u16;
                let (mut s, mut n) = (Vector2::ZERO, 0.0);
                let mut stack = vec![(x, z)];
                comp[(z * w + x) as usize] = id;
                while let Some((cx, cz)) = stack.pop() {
                    s += Vector2::new(v.min_x + (cx as f32 + 0.5) * v.cell, v.min_z + (cz as f32 + 0.5) * v.cell);
                    n += 1.0;
                    for dz in -1..=1 {
                        for dx in -1..=1 {
                            let (nx, nz) = (cx + dx, cz + dz);
                            if land(nx, nz) && comp[(nz * w + nx) as usize] == NONE {
                                comp[(nz * w + nx) as usize] = id;
                                stack.push((nx, nz));
                            }
                        }
                    }
                }
                sums.push((s, n));
            }
        }
        let n = v.centres.len();
        let (mut island_of, mut dist) = (vec![NONE; n], vec![f32::INFINITY; n]);
        let mut heap = BinaryHeap::new();
        let grid = |p: Vector2| (((p.x - v.min_x) / v.cell) as i32, ((p.y - v.min_z) / v.cell) as i32);
        for k in 0..n {
            let (x, z) = grid(v.centres[k]);
            for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                if land(x + dx, z + dz) {
                    island_of[k] = comp[((z + dz) * w + x + dx) as usize];
                    dist[k] = v.cell * 0.5;
                    heap.push(Reverse(((v.cell * 0.5).to_bits(), k as u32)));
                    break;
                }
            }
        }
        while let Some(Reverse((bits, k))) = heap.pop() {
            let (d, k) = (f32::from_bits(bits), k as usize);
            if d > dist[k] {
                continue;
            }
            for (slot, &j) in lay.adj[k].iter().enumerate() {
                if j == NO_NEIGHBOUR {
                    continue;
                }
                let nd = d + v.cell * if slot < 4 { 1.0 } else { std::f32::consts::SQRT_2 };
                if nd < dist[j as usize] {
                    dist[j as usize] = nd;
                    island_of[j as usize] = island_of[k];
                    heap.push(Reverse((nd.to_bits(), j)));
                }
            }
        }
        let mut islands: Vec<Island> = sums.iter().map(|&(s, c)| Island { centre: s / c, berths: Vec::new(), radius: 0.0 }).collect();
        let (mut gaps, mut lattice) = (Vec::new(), Vec::new());
        for k in 0..n {
            let (x, z) = grid(v.centres[k]);
            if x % LATTICE == 0 && z % LATTICE == 0 {
                lattice.push(k as u32);
            }
            let id = island_of[k];
            if id == NONE {
                continue;
            }
            if v.sdf_c[k] <= BERTH_M {
                let is = &mut islands[id as usize];
                let d = v.centres[k] - is.centre;
                is.berths.push((d.x.atan2(d.y), k as u32));
                is.radius = is.radius.max(d.length());
            }
            if dist[k] <= GAP_M && dist[k] >= GAP_MIN_M && (x + z) % 2 == 0 && lay.adj[k].iter().any(|&j| j != NO_NEIGHBOUR && island_of[j as usize] != id && island_of[j as usize] != NONE) {
                gaps.push(k as u32);
            }
        }
        for is in &mut islands {
            is.berths.sort_unstable_by(|a, b| a.0.total_cmp(&b.0));
        }
        Features { islands, gaps, lattice, island_of }
    }

    /// One byte per VisibilityGrid cell (row-major, land 0): 1 berth, 2 gap, 3 lattice, 4 other water.
    pub fn bytes(&self, v: &VisibilityGrid) -> Vec<u8> {
        let mut kind = vec![4u8; v.centres.len()];
        for &k in &self.lattice {
            kind[k as usize] = 3;
        }
        for is in &self.islands {
            for &(_, k) in &is.berths {
                kind[k as usize] = 1;
            }
        }
        for &k in &self.gaps {
            kind[k as usize] = 2;
        }
        v.index.iter().map(|&k| if k < 0 { 0 } else { kind[k as usize] }).collect()
    }
}
