use super::survey::{
    axis_weights, blob_header, erf, rd_u16, resolve_codes, BlobHdr, CELL_CODE_MASK, CELL_MISS, CELL_SECTION_MASK,
    CELL_SECTION_SHIFT, CELL_TURRET, MM_MISS,
};

/// Half-dispersion grid (plane metres), geometric so the query can lerp in log space.
pub(crate) const EV_H0: f32 = 15.0;
pub(crate) const EV_H_RATIO: f32 = 10.0 / 3.0;
pub(crate) const EV_V0: f32 = 2.0;
pub(crate) const EV_V_RATIO: f32 = 6.0;
pub(crate) const EV_NH: usize = 3;
pub(crate) const EV_NV: usize = 3;
const ND: usize = EV_NH * EV_NV;
/// Log-spaced penetration grids (mm) the value is sampled on and lerped between.
const AP_PEN0: f64 = 50.0;
const AP_PEN1: f64 = 1300.0;
const HE_PEN0: f64 = 5.0;
const HE_PEN1: f64 = 150.0;
const NP: usize = 10;
const STEP_REL: f32 = 0.05;
const STEP_ABS: f32 = 0.002;
const AIM_STRIDE: usize = 2;
const AIM_MIN_V_M: f64 = 2.0;

fn grid_pen(i: usize, lo: f64, hi: f64) -> f64 {
    lo * (hi / lo).powf(i as f64 / (NP - 1) as f64)
}

pub(crate) struct EvKernel {
    pub sigma: f64,
    pub guarantee: f64,
    pub ellipse: (f64, f64),
    /// Section-major, 16 codes per section, full pools.
    pub payouts: Vec<f64>,
    pub turret_cap: f64,
    pub om_max: f64,
    /// Section-major like `payouts`: 0 light, 1 medium, 2 heavy (HPManager.DAMAGE_LEVEL).
    pub levels: Vec<u8>,
}

impl EvKernel {
    fn payout(&self, c: u8) -> f64 {
        if c == CELL_MISS {
            return 0.0;
        }
        let idx = (((c & CELL_SECTION_MASK) >> CELL_SECTION_SHIFT) as usize) * 16 + (c & CELL_CODE_MASK) as usize;
        let v = self.payouts.get(idx).copied().unwrap_or(0.0);
        if c & CELL_TURRET != 0 { v.min(self.turret_cap) } else { v }
    }

    fn level(&self, c: u8) -> u8 {
        if c == CELL_MISS {
            return 0;
        }
        let idx = (((c & CELL_SECTION_MASK) >> CELL_SECTION_SHIFT) as usize) * 16 + (c & CELL_CODE_MASK) as usize;
        self.levels.get(idx).copied().unwrap_or(1)
    }
}

fn disp_of(i: usize) -> (f64, f64) {
    let (ih, iv) = (i / EV_NV, i % EV_NV);
    ((EV_H0 * EV_H_RATIO.powi(ih as i32)) as f64, (EV_V0 * EV_V_RATIO.powi(iv as i32)) as f64)
}

/// Kernel mass per cell for every distinct aim column and row, per dispersion.
struct Weights {
    wh: Vec<Vec<f64>>,
    qh: Vec<Vec<f64>>,
    wv: Vec<Vec<f64>>,
    qv: Vec<Vec<f64>>,
}

struct Lattice {
    nx: usize,
    ny: usize,
    aim_u: Vec<f64>,
    aim_v: Vec<f64>,
    g: f64,
    weights: Vec<Weights>,
}

fn lattice(b: &[u8], h: &BlobHdr, k: &EvKernel) -> Lattice {
    let (nx, ny) = (h.nx, h.ny);
    let (u0, u1) = (h.rect.x as f64, h.rect.z as f64);
    let du = (u1 - u0) / nx.max(1) as f64;
    let ue: Vec<f64> = (0..=nx).map(|i| u0 + du * i as f64).collect();
    let ve: Vec<f64> = (0..=ny).map(|i| f32::from_le_bytes(b[h.edges + 4 * i..h.edges + 4 * i + 4].try_into().unwrap()) as f64).collect();
    let aim_u: Vec<f64> = (0..nx).step_by(AIM_STRIDE).map(|ix| u0 + (ix as f64 + 0.5) * du).collect();
    let mut aim_v = Vec::new();
    let mut last = f64::NEG_INFINITY;
    for iy in (0..ny).step_by(AIM_STRIDE) {
        let v = 0.5 * (ve[iy] + ve[iy + 1]);
        if v - last >= AIM_MIN_V_M {
            aim_v.push(v);
            last = v;
        }
    }
    let s = k.sigma.max(0.01);
    let erf_bound = erf(s / std::f64::consts::SQRT_2);
    let ea = k.ellipse.0.max(0.01);
    let eb = k.ellipse.1.max(0.01) * 0.785;
    let guar_h = |x: f64| ((x + ea) / (2.0 * ea)).clamp(0.0, 1.0);
    let guar_v = |y: f64| 0.5 + 0.5 * y.signum() * (y.abs() / eb).min(1.0).powf(1.0 / 1.6);
    let cdf = |x: f64| super::survey::trunc_gauss_cdf(x, s, erf_bound);
    let p_in = (cdf(ea) - cdf(-ea)) * (cdf(eb) - cdf(-eb));
    let g = if k.guarantee > 0.0 { k.guarantee * (1.0 - p_in).powi(3) } else { 0.0 };
    let weights = (0..ND)
        .map(|d| {
            let (hh, hv) = disp_of(d);
            let (wh, qh) = aim_u.iter().map(|&a| axis_weights(&ue, a, hh, s, erf_bound, &guar_h)).unzip();
            let (wv, qv) = aim_v.iter().map(|&a| axis_weights(&ve, a, hv, s, erf_bound, &guar_v)).unzip();
            Weights { wh, qh, wv, qv }
        })
        .collect();
    Lattice { nx, ny, aim_u, aim_v, g, weights }
}

/// Best-aim (value per shell, landed share) for every dispersion. The kernel
/// is separable, so rows are summed once per aim column, not once per aim.
fn score(l: &Lattice, pay: &[f64], hit: &[f64], heavy: &[f64], medium: &[f64]) -> [Cell; ND] {
    let mut out = [Cell::default(); ND];
    let (nx, ny) = (l.nx, l.ny);
    let row_sums = |w: &[f64], m: &[f64], out: &mut Vec<f64>| {
        out.clear();
        for iy in 0..ny {
            let r = &m[iy * nx..iy * nx + nx];
            out.push(w.iter().zip(r).map(|(a, b)| a * b).sum());
        }
    };
    let (mut rw, mut rq) = (Vec::with_capacity(ny), Vec::with_capacity(ny));
    for (d, w) in l.weights.iter().enumerate() {
        let mut best = (f64::NEG_INFINITY, 0usize, 0usize);
        for iu in 0..l.aim_u.len() {
            row_sums(&w.wh[iu], pay, &mut rw);
            row_sums(&w.qh[iu], pay, &mut rq);
            for iv in 0..l.aim_v.len() {
                let a: f64 = w.wv[iv].iter().zip(&rw).map(|(x, y)| x * y).sum();
                let b: f64 = w.qv[iv].iter().zip(&rq).map(|(x, y)| x * y).sum();
                let v = (1.0 - l.g) * a + l.g * b;
                if v > best.0 {
                    best = (v, iu, iv);
                }
            }
        }
        if !best.0.is_finite() {
            continue;
        }
        let (_, iu, iv) = best;
        let mut at_aim = |m: &[f64]| -> f32 {
            row_sums(&w.wh[iu], m, &mut rw);
            row_sums(&w.qh[iu], m, &mut rq);
            let a: f64 = w.wv[iv].iter().zip(&rw).map(|(x, y)| x * y).sum();
            let b: f64 = w.qv[iv].iter().zip(&rq).map(|(x, y)| x * y).sum();
            ((1.0 - l.g) * a + l.g * b) as f32
        };
        let value = best.0 as f32;
        let share = |x: f32| if value > 0.0 { (x / value).clamp(0.0, 1.0) } else { 0.0 };
        out[d] = Cell { value, landed: at_aim(hit), heavy: share(at_aim(heavy)), medium: share(at_aim(medium)) };
    }
    out
}

/// At the best aim: value per shell, landed share, and the shares of the value
/// that are heavy (citadel) and medium (penetration) damage.
#[derive(Clone, Copy, Default)]
struct Cell {
    value: f32,
    landed: f32,
    heavy: f32,
    medium: f32,
}

type Row = [Cell; ND];

fn close(a: f32, b: f32) -> bool {
    (a - b).abs() <= STEP_ABS.max(STEP_REL * a.abs().max(b.abs()))
}

/// Square-root coded so small values keep their relative precision.
fn enc(v: f32) -> u8 {
    (v.clamp(0.0, 1.0).sqrt() * 255.0).round() as u8
}

fn dec(q: u8) -> f32 {
    let r = q as f32 / 255.0;
    r * r
}

/// Overmatch thresholds: first plates some fleet shell overmatches and whose
/// profile has an overmatched sweep.
fn thresholds(b: &[u8], h: &BlobHdr, om_max: f64) -> Vec<u16> {
    let np = h.np;
    let a = h.prof;
    let mut thr: Vec<u16> = (0..np)
        .filter(|&pi| b[a + 4 * np + pi] > 0)
        .map(|pi| rd_u16(b, a + 2 * pi))
        .filter(|&mm| mm != MM_MISS && (mm as f64) <= om_max)
        .collect();
    thr.sort_unstable();
    thr.dedup();
    thr
}

/// ```text
/// u8 n_thr | u16 thr[n_thr]    AP overmatch class = count of thr <= overmatch
/// AP, per class 0..=n_thr:     u8 value[NP][ND] on the AP pen grid
/// HE:                          u8 value[NP][ND] | u8 landed[NP][ND] on the HE pen grid
/// LEVELS, per AP class then HE: u8 heavy[NP][ND] | u8 medium[NP][ND]
/// ```
/// value = expected payout per shell fired (fraction of alpha) at the best
/// aim, landed = share of shells on the hull there, heavy / medium = shares
/// of the value landing as citadel / penetration damage, all sqrt-coded.
/// Classes that score alike are merged.
pub(crate) fn ev_bucket(b: &[u8], k: &EvKernel) -> Vec<u8> {
    let mut out = Vec::new();
    let Some(h) = blob_header(b) else { return out };
    if h.nx == 0 || h.ny == 0 {
        return out;
    }
    let lat = lattice(b, &h, k);
    let ncell = h.nx * h.ny;
    let eval = |pen: f64, om: f64, he: bool| -> Row {
        match resolve_codes(b, pen, om, he) {
            Some(codes) if codes.len() == ncell => {
                let pay: Vec<f64> = codes.iter().map(|&c| k.payout(c)).collect();
                let hit: Vec<f64> = codes.iter().map(|&c| if c == CELL_MISS { 0.0 } else { 1.0 }).collect();
                let at_level = |lv: u8| -> Vec<f64> {
                    codes.iter().zip(&pay).map(|(&c, &p)| if k.level(c) == lv { p } else { 0.0 }).collect()
                };
                score(&lat, &pay, &hit, &at_level(2), &at_level(1))
            }
            _ => [Cell::default(); ND],
        }
    };
    let thr = thresholds(b, &h, k.om_max);
    let mut classes: Vec<(u16, Vec<Row>)> = Vec::new();
    for class in 0..=thr.len() {
        let om = if class == 0 { 0.0 } else { thr[class - 1] as f64 };
        let rows: Vec<Row> = (0..NP).map(|i| eval(grid_pen(i, AP_PEN0, AP_PEN1), om, false)).collect();
        if classes.last().is_some_and(|(_, prev)| {
            prev.iter().zip(&rows).all(|(p, q)| (0..ND).all(|d| close(p[d].value, q[d].value)))
        }) {
            continue;
        }
        classes.push((om as u16, rows));
    }
    classes.truncate(256);
    out.push((classes.len() - 1) as u8);
    for (t, _) in classes.iter().skip(1) {
        out.extend_from_slice(&t.to_le_bytes());
    }
    for (_, rows) in &classes {
        for row in rows {
            out.extend(row.iter().map(|r| enc(r.value)));
        }
    }
    let he: Vec<Row> = (0..NP).map(|i| eval(0.0, grid_pen(i, HE_PEN0, HE_PEN1), true)).collect();
    for row in &he {
        out.extend(row.iter().map(|r| enc(r.value)));
    }
    for row in &he {
        out.extend(row.iter().map(|r| enc(r.landed)));
    }
    for rows in classes.iter().map(|(_, r)| r).chain(std::iter::once(&he)) {
        for row in rows {
            out.extend(row.iter().map(|r| enc(r.heavy)));
        }
        for row in rows {
            out.extend(row.iter().map(|r| enc(r.medium)));
        }
    }
    out
}

fn grid_pos(x: f32, x0: f32, ratio: f32, n: usize) -> (usize, f32) {
    let t = ((x.max(1e-3) / x0).ln() / ratio.ln()).clamp(0.0, (n - 1) as f32);
    let i = (t.floor() as usize).min(n - 2);
    (i, t - i as f32)
}

/// (value per shell fired as a fraction of alpha, landed share) for one shell
/// against one bucket chunk: lerped in log pen and log half-dispersion.
pub(crate) fn ev_lookup(b: &[u8], pen: f64, overmatch: f64, is_he: bool, half_h: f32, half_v: f32) -> Option<(f32, f32)> {
    let c = Chunk::of(b, pen, overmatch, is_he, half_h, half_v)?;
    let vals = if is_he { c.head + (c.n_thr + 1) * c.block } else { c.head + c.class * c.block };
    // Below the grid's first pen the value fades to zero rather than holding.
    let fade = if c.x < c.lo { (c.x / c.lo) as f32 } else { 1.0 };
    Some((c.tri(b, vals) * fade, if is_he { c.tri(b, vals + c.block) * fade } else { 0.0 }))
}

/// (heavy, medium) shares of `ev_lookup`'s value; None for chunks baked without them.
pub(crate) fn ev_levels(b: &[u8], pen: f64, overmatch: f64, is_he: bool, half_h: f32, half_v: f32) -> Option<(f32, f32)> {
    let c = Chunk::of(b, pen, overmatch, is_he, half_h, half_v)?;
    let levels = c.head + (c.n_thr + 1) * c.block + 2 * c.block;
    if b.len() < levels + (c.n_thr + 2) * 2 * c.block {
        return None;
    }
    let base = levels + if is_he { c.n_thr + 1 } else { c.class } * 2 * c.block;
    Some((c.tri(b, base), c.tri(b, base + c.block)))
}

struct Chunk {
    n_thr: usize,
    block: usize,
    head: usize,
    class: usize,
    x: f64,
    lo: f64,
    p: (usize, f32),
    h: (usize, f32),
    v: (usize, f32),
}

impl Chunk {
    fn of(b: &[u8], pen: f64, overmatch: f64, is_he: bool, half_h: f32, half_v: f32) -> Option<Self> {
        let n_thr = *b.first()? as usize;
        let block = NP * ND;
        let head = 1 + 2 * n_thr;
        if b.len() < head + (n_thr + 1) * block + 2 * block {
            return None;
        }
        let (class, x, lo, hi) = if is_he {
            (0, overmatch, HE_PEN0, HE_PEN1)
        } else {
            ((0..n_thr).filter(|&i| rd_u16(b, 1 + 2 * i) as f64 <= overmatch).count(), pen, AP_PEN0, AP_PEN1)
        };
        Some(Self {
            n_thr,
            block,
            head,
            class,
            x,
            lo,
            p: grid_pos(x.max(1e-3) as f32, lo as f32, (hi / lo).powf(1.0 / (NP - 1) as f64) as f32, NP),
            h: grid_pos(half_h, EV_H0, EV_H_RATIO, EV_NH),
            v: grid_pos(half_v, EV_V0, EV_V_RATIO, EV_NV),
        })
    }

    /// Trilinear in log pen x log half-dispersion of the block at `base`.
    fn tri(&self, b: &[u8], base: usize) -> f32 {
        let ((ip, fp), (ih, fh), (iv, fv)) = (self.p, self.h, self.v);
        let at = |p: usize, a: usize, c: usize| dec(b[base + p * ND + a * EV_NV + c]);
        let lerp = |p: f32, q: f32, t: f32| p + (q - p) * t;
        let plane = |p: usize| {
            let lo = lerp(at(p, ih, iv), at(p, ih, iv + 1), fv);
            let hi = lerp(at(p, ih + 1, iv), at(p, ih + 1, iv + 1), fv);
            lerp(lo, hi, fh)
        };
        lerp(plane(ip), plane(ip + 1), fp)
    }
}
