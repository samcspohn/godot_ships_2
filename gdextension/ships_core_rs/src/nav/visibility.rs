use godot::prelude::*;
use rayon::prelude::*;
use std::sync::Arc;
use std::time::Instant;

use crate::nav::map::NavigationMap;
use crate::nav::reach::{nav_pool, ReachField, Terrain};
use crate::nav::cover_sweep::{pick_dict, sweep_args};
use crate::nav::spot_walk::{Enemy, SpotInputs, AVOID_DET};
use crate::projectile::damage_model::DamageModel;
use crate::variant_cast::VariantCast;

/// Matches the server's spotting ray, cast at y = 1 m on both ends.
const EYE_H: f32 = 1.0;
const STEP_MULT: f32 = 0.5;
/// Bump when `first_block` changes; invalidates every cache file.
const VERSION: u64 = 1;

/// Island line of sight between every pair of water cells, one bit per pair.
/// Terrain only: smoke is dynamic and tested by the caller.
#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct VisibilityGrid {
    base: Base<RefCounted>,
    pub(crate) w: i32,
    pub(crate) h: i32,
    pub(crate) cell: f32,
    pub(crate) min_x: f32,
    pub(crate) min_z: f32,
    /// Water cell index per grid cell, -1 on land.
    pub(crate) index: Vec<i32>,
    pub(crate) centres: Vec<Vector2>,
    /// SDF at each water cell's centre, for hull clearance.
    pub(crate) sdf_c: Vec<f32>,
    stride: usize,
    bits: Vec<u64>,
    build_ms: f64,
    terrain: Option<Arc<Terrain>>,
}

#[godot_api]
impl IRefCounted for VisibilityGrid {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            w: 0,
            h: 0,
            cell: 0.0,
            min_x: 0.0,
            min_z: 0.0,
            index: Vec::new(),
            centres: Vec::new(),
            sdf_c: Vec::new(),
            stride: 0,
            bits: Vec::new(),
            build_ms: 0.0,
            terrain: None,
        }
    }
}

fn clear(t: &Terrain, a: Vector2, b: Vector2) -> bool {
    first_block(t, a, b).is_none()
}

fn first_block(t: &Terrain, a: Vector2, b: Vector2) -> Option<Vector2> {
    let d = b - a;
    let len = d.length();
    if len < 1e-3 {
        return None;
    }
    let (dx, dz) = (d.x / len, d.y / len);
    let step = t.cell * STEP_MULT;
    let margin = t.cell;
    let mut s = 0.0f32;
    while s < len {
        let (px, pz) = (a.x + dx * s, a.y + dz * s);
        let sd = t.bilinear(&t.sdf, px, pz);
        if sd > margin {
            s += sd - margin * 0.5;
            continue;
        }
        // Bilinear height bleeds island height ~one cell out over water; the SDF coast does not.
        if sd <= -0.25 * t.cell && t.bilinear(&t.height, px, pz) > EYE_H {
            return Some(Vector2::new(px, pz));
        }
        s += step;
    }
    None
}

#[inline]
fn bit(row: &[u64], j: usize) -> bool {
    row[j / 64] >> (j % 64) & 1 != 0
}

impl VisibilityGrid {
    pub(crate) fn is_ready(&self) -> bool {
        !self.bits.is_empty()
    }

    /// Nearest water cell to `p`; a ship hugging a coast can sit in a cell whose centre is land.
    pub(crate) fn cell_of(&self, p: Vector2) -> Option<usize> {
        if !self.is_ready() {
            return None;
        }
        let ix = (((p.x - self.min_x) / self.cell).floor() as i32).clamp(0, self.w - 1);
        let iz = (((p.y - self.min_z) / self.cell).floor() as i32).clamp(0, self.h - 1);
        let own = self.index[(iz * self.w + ix) as usize];
        if own >= 0 {
            return Some(own as usize);
        }
        let mut best: Option<(f32, usize)> = None;
        for r in 1..=2 {
            for jz in (iz - r).max(0)..=(iz + r).min(self.h - 1) {
                for jx in (ix - r).max(0)..=(ix + r).min(self.w - 1) {
                    let k = self.index[(jz * self.w + jx) as usize];
                    if k < 0 {
                        continue;
                    }
                    let d = self.centres[k as usize].distance_squared_to(p);
                    if best.is_none_or(|(bd, _)| d < bd) {
                        best = Some((d, k as usize));
                    }
                }
            }
            if best.is_some() {
                break;
            }
        }
        best.map(|(_, k)| k)
    }

    #[inline]
    pub(crate) fn visible_idx(&self, i: usize, j: usize) -> bool {
        bit(&self.bits[i * self.stride..(i + 1) * self.stride], j)
    }

    pub(crate) fn frac_idx(&self, i: usize, b: Vector2, radius: i32) -> f32 {
        let ix = (((b.x - self.min_x) / self.cell).floor() as i32).clamp(0, self.w - 1);
        let iz = (((b.y - self.min_z) / self.cell).floor() as i32).clamp(0, self.h - 1);
        let (mut seen, mut total) = (0u32, 0u32);
        for jz in (iz - radius).max(0)..=(iz + radius).min(self.h - 1) {
            for jx in (ix - radius).max(0)..=(ix + radius).min(self.w - 1) {
                let k = self.index[(jz * self.w + jx) as usize];
                if k >= 0 {
                    total += 1;
                    seen += self.visible_idx(i, k as usize) as u32;
                }
            }
        }
        if total == 0 {
            return self.cell_of(b).map_or(0.0, |k| self.visible_idx(i, k) as u8 as f32);
        }
        seen as f32 / total as f32
    }

    /// Lays out the cells for `nav_map`; false when the map is not built.
    fn prepare(&mut self, nav_map: Option<Gd<NavigationMap>>, cell_size: f32) -> bool {
        let Some(map) = nav_map else { return false };
        let m = map.bind();
        if !m.built {
            return false;
        }
        let t = Terrain::from_map(&m);
        drop(m);
        let cell = cell_size.max(t.cell);
        let (w, h) = ((t.w as f32 * t.cell / cell).ceil() as i32, (t.h as f32 * t.cell / cell).ceil() as i32);
        let mut index = vec![-1i32; (w * h) as usize];
        let mut centres = Vec::new();
        let mut sdf_c = Vec::new();
        for iz in 0..h {
            for ix in 0..w {
                let c = Vector2::new(t.min_x + (ix as f32 + 0.5) * cell, t.min_z + (iz as f32 + 0.5) * cell);
                let d = if t.in_bounds(c.x, c.y) { t.bilinear(&t.sdf, c.x, c.y) } else { 0.0 };
                if d > 0.0 {
                    index[(iz * w + ix) as usize] = centres.len() as i32;
                    centres.push(c);
                    sdf_c.push(d);
                }
            }
        }
        self.w = w;
        self.h = h;
        self.cell = cell;
        self.min_x = t.min_x;
        self.min_z = t.min_z;
        self.stride = centres.len().div_ceil(64);
        self.index = index;
        self.centres = centres;
        self.sdf_c = sdf_c;
        self.bits.clear();
        self.terrain = Some(Arc::new(t));
        true
    }
}

#[godot_api]
impl VisibilityGrid {
    #[constant]
    const AVOID_DET: i32 = crate::nav::spot_walk::AVOID_DET as i32;
    #[constant]
    const AVOID_LOS: i32 = crate::nav::spot_walk::AVOID_LOS as i32;
    #[constant]
    const AVOID_FIRE: i32 = crate::nav::spot_walk::AVOID_FIRE as i32;

    #[func]
    fn build(&mut self, nav_map: Option<Gd<NavigationMap>>, #[opt(default = 300.0)] cell_size: f32) {
        let t0 = Instant::now();
        if !self.prepare(nav_map, cell_size) {
            return;
        }
        let (t, centres, n, stride) = (self.terrain.clone().unwrap(), &self.centres, self.centres.len(), self.stride);
        // Upper triangle only; the lower half is gathered from it so both halves agree bit for bit.
        let upper: Vec<Vec<u64>> = nav_pool().install(|| {
            (0..n)
                .into_par_iter()
                .map(|i| {
                    let mut row = vec![0u64; stride];
                    for j in i + 1..n {
                        if clear(&t, centres[i], centres[j]) {
                            row[j / 64] |= 1u64 << (j % 64);
                        }
                    }
                    row
                })
                .collect()
        });
        let rows: Vec<Vec<u64>> = nav_pool().install(|| {
            (0..n)
                .into_par_iter()
                .map(|j| {
                    let mut row = upper[j].clone();
                    row[j / 64] |= 1u64 << (j % 64);
                    for (i, up) in upper.iter().enumerate().take(j) {
                        if bit(up, j) {
                            row[i / 64] |= 1u64 << (i % 64);
                        }
                    }
                    row
                })
                .collect()
        });
        self.bits = rows.into_iter().flatten().collect();
        self.build_ms = t0.elapsed().as_secs_f64() * 1000.0;
    }

    /// Changes whenever the terrain, the cell size or the ray model does; names the cache file.
    #[func]
    fn signature(&self, nav_map: Option<Gd<NavigationMap>>, #[opt(default = 300.0)] cell_size: f32) -> i64 {
        let Some(map) = nav_map else { return 0 };
        let m = map.bind();
        let mut hsh: u64 = 0xcbf2_9ce4_8422_2325 ^ VERSION;
        let mut mix = |v: u32| {
            hsh ^= v as u64;
            hsh = hsh.wrapping_mul(0x0100_0000_01b3);
        };
        for v in [m.grid_width as u32, m.grid_height as u32, m.cell_size.to_bits(), m.min_x.to_bits(),
            m.min_z.to_bits(), cell_size.to_bits(), EYE_H.to_bits()] {
            mix(v);
        }
        let height = if m.height_mid_grid.len() == m.height_grid.len() { &m.height_mid_grid } else { &m.height_grid };
        for v in m.sdf_grid.iter().chain(height.iter()) {
            mix(v.to_bits());
        }
        hsh as i64
    }

    #[func]
    fn to_bytes(&self) -> PackedByteArray {
        let mut out = Vec::with_capacity(self.bits.len() * 8);
        for w in &self.bits {
            out.extend_from_slice(&w.to_le_bytes());
        }
        PackedByteArray::from(out.as_slice())
    }

    /// Restores bits saved by `to_bytes` for the same map and cell size; false on a size mismatch.
    #[func]
    fn from_bytes(&mut self, nav_map: Option<Gd<NavigationMap>>, cell_size: f32, bytes: PackedByteArray) -> bool {
        if !self.prepare(nav_map, cell_size) {
            return false;
        }
        let b = bytes.as_slice();
        if b.len() != self.centres.len() * self.stride * 8 {
            self.centres.clear();
            return false;
        }
        self.bits = b.chunks_exact(8).map(|c| u64::from_le_bytes(c.try_into().unwrap())).collect();
        self.build_ms = 0.0;
        true
    }

    #[func]
    fn is_built(&self) -> bool {
        self.is_ready()
    }

    #[func]
    fn get_info(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("cell", self.cell);
        d.set("width", self.w);
        d.set("height", self.h);
        d.set("cells", self.centres.len() as i64);
        d.set("bytes", (self.bits.len() * 8) as i64);
        d.set("build_ms", self.build_ms);
        d
    }

    /// -1 when not built.
    #[func]
    fn cell_index(&self, p: Vector2) -> i64 {
        self.cell_of(p).map_or(-1, |k| k as i64)
    }

    #[func]
    fn cell_centre(&self, k: i64) -> Vector2 {
        self.centres.get(k as usize).copied().unwrap_or(Vector2::ZERO)
    }

    #[func]
    fn visible(&self, a: Vector2, b: Vector2) -> bool {
        match (self.cell_of(a), self.cell_of(b)) {
            (Some(i), Some(j)) => self.visible_idx(i, j),
            _ => true,
        }
    }

    /// Share of the water cells within `radius` cells of `b` that `a` sees.
    /// Near 0 or 1 is robust; in between, a small move by either side flips it.
    #[func]
    fn visible_frac(&self, a: Vector2, b: Vector2, #[opt(default = 1)] radius: i32) -> f32 {
        match self.cell_of(a) {
            Some(i) => self.frac_idx(i, b, radius.max(0)),
            None => 1.0,
        }
    }

    fn hold_inputs(&self, enemies: &PackedVector2Array, o: &VarDictionary) -> SpotInputs {
        let f32s = |k: &str| o.get(k).and_then(|v| v.try_to::<PackedFloat32Array>().ok()).unwrap_or_default();
        let (det, spot, los) = (f32s("det_r"), f32s("spot_r"), f32s("los_r"));
        let bytes = |k: &str| o.get(k).and_then(|v| v.try_to::<PackedByteArray>().ok()).unwrap_or_default();
        let (shoot, heavy) = (bytes("shootable"), bytes("heavy"));
        let (d, s, l, sh, hv) = (det.as_slice(), spot.as_slice(), los.as_slice(), shoot.as_slice(), heavy.as_slice());
        let field = o.get("reach_field").and_then(|v| v.try_to::<Gd<ReachField>>().ok());
        let ids = o.get("ids").and_then(|v| v.try_to::<PackedInt64Array>().ok()).unwrap_or_default();
        let team = o.get("team").map_or(-1, |v| v.to_i32());
        SpotInputs {
            enemies: enemies.as_slice().iter().enumerate().map(|(i, &pos)| Enemy {
                pos,
                cell: self.cell_of(pos),
                det_r: d.get(i).copied().unwrap_or(0.0),
                spot_r: s.get(i).copied().unwrap_or(0.0),
                los_r: l.get(i).copied().unwrap_or(0.0),
                heavy: hv.get(i).is_some_and(|&b| b != 0),
                shootable: sh.get(i).is_some_and(|&b| b != 0),
            }).collect(),
            clearance: o.get("clearance").map_or(0.0, |v| v.to_f32()),
            avoid: o.get("avoid").map_or(AVOID_DET as i32, |v| v.to_i32()) as u8,
            los_margin: o.get("los_margin").map_or(0, |v| v.to_i32()),
            reach: field.as_ref().and_then(|f| f.bind().reach_lookup(team, o.get("hull_key").map_or(0, |v| v.to_i64()), ids.as_slice())),
            fire: field.as_ref().and_then(|f| f.bind().fire_lookup(team, ids.as_slice())),
            reach_needs_los: o.get("reach_needs_los").is_some_and(|v| v.to_bool()),
        }
    }

    /// Perimeter search for an allowed cell that sees at least `need` shootable
    /// enemies within their `spot_r`. `outward` starts where the ray from `from`
    /// through `toward` leaves forbidden ground; otherwise at the last free cell
    /// from `from` toward `toward`. `opts`: det_r, spot_r, los_r (per enemy),
    /// shootable, heavy (AVOID_FIRE), clearance, avoid (AVOID_* bits, default detection), los_margin, need,
    /// budget_m (<= 0 walks the whole perimeter), flank. With reach_field, team,
    /// hull_key and ids (per enemy) the goal counts enemies the hull can hit
    /// from the cell instead of enemies it sees.
    #[func]
    fn hold_walk(&self, from: Vector2, toward: Vector2, outward: bool, enemies: PackedVector2Array,
        opts: VarDictionary) -> VarDictionary {
        let mut d = VarDictionary::new();
        if !self.is_ready() {
            return d;
        }
        let inp = self.hold_inputs(&enemies, &opts);
        let need = opts.get("need").map_or(1, |v| v.to_i32()).max(1) as u32;
        let budget = opts.get("budget_m").map_or(0.0, |v| v.to_f32());
        let flank = opts.get("flank").and_then(|v| v.try_to::<Vector2>().ok()).unwrap_or(Vector2::ZERO);
        let r = self.spot_walk_impl(from, toward, outward, &inp, need, budget, flank);
        d.set("found", r.found.is_some());
        d.set("has_start", r.start.is_some());
        d.set("start", r.start.unwrap_or(Vector2::INF));
        if let Some((k, mask)) = r.found {
            d.set("pos", self.centres[k]);
            d.set("mask", mask as i64);
            d.set("count", mask.count_ones() as i64);
        }
        d.set("steps", r.steps as i64);
        d.set("trail_a", &PackedVector2Array::from(r.trails[0].as_slice()));
        d.set("trail_b", &PackedVector2Array::from(r.trails[1].as_slice()));
        d
    }

    /// Every water cell within `box_m` of `from`, reached by the cheapest path
    /// priced by time and by lit enemies' fire at the aspect each step shows.
    /// hold_walk's opts plus damage_model, me, prio and seen_r (per enemy), speed,
    /// my_hp, box_m, pref_range, gun_range, hold_s, need, allow_hard, held and
    /// weights w_gain, w_risk, w_time, w_range, w_hard.
    /// {best, held, dark: {pos, score, gain, risk, time, mask, count, hard} or {}, cells, us}.
    #[func]
    fn cover_sweep(&self, from: Vector2, enemies: PackedVector2Array, opts: VarDictionary) -> VarDictionary {
        let mut d = VarDictionary::new();
        let Some(mut dm) = opts.get("damage_model").and_then(|v| v.try_to::<Gd<DamageModel>>().ok()) else { return d };
        if !self.is_ready() {
            return d;
        }
        let t0 = Instant::now();
        let inp = self.hold_inputs(&enemies, &opts);
        let args = sweep_args(from, &opts, &mut dm.bind_mut());
        let r = self.cover_sweep_impl(&inp, &args, &dm.bind());
        pick_dict(&mut d, "best", r.best, &self.centres);
        pick_dict(&mut d, "held", r.held, &self.centres);
        pick_dict(&mut d, "dark", r.dark, &self.centres);
        d.set("cells", r.cells as i64);
        d.set("us", t0.elapsed().as_micros() as i64);
        d
    }

    /// {free, mask, count} for the cell holding `pos`, under the same `opts`.
    #[func]
    fn hold_eval(&self, pos: Vector2, enemies: PackedVector2Array, opts: VarDictionary) -> VarDictionary {
        let inp = self.hold_inputs(&enemies, &opts);
        let (free, mask) = if self.is_ready() { self.spot_eval_impl(pos, &inp) } else { (false, 0) };
        let mut d = VarDictionary::new();
        d.set("free", free);
        d.set("mask", mask as i64);
        d.set("count", mask.count_ones() as i64);
        d
    }

    /// One byte per grid cell, row-major: 1 seen from `p`, 0 hidden, 255 land.
    #[func]
    fn get_row_bytes(&self, p: Vector2) -> PackedByteArray {
        let mut out = vec![255u8; self.index.len()];
        if let Some(i) = self.cell_of(p) {
            for (g, &k) in self.index.iter().enumerate() {
                if k >= 0 {
                    out[g] = self.visible_idx(i, k as usize) as u8;
                }
            }
        }
        PackedByteArray::from(out.as_slice())
    }

    /// The build's own ray between arbitrary points, for validation.
    #[func]
    fn ray_clear(&self, a: Vector2, b: Vector2) -> bool {
        self.terrain.as_ref().is_none_or(|t| clear(t, a, b))
    }

    /// Where `ray_clear` stops, or (INF, INF).
    #[func]
    fn ray_block_point(&self, a: Vector2, b: Vector2) -> Vector2 {
        self.terrain.as_ref().and_then(|t| first_block(t, a, b)).unwrap_or(Vector2::INF)
    }
}
