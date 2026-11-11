//! Runtime PointTable builds: GDScript submits one job per (shooter shell, target hull) at match start and the
//! worker fills (range, aspect) buckets on its own pool, every job's longest ranges before any job's closer ones,
//! so the buckets a fight opens with are ready first. Geometry mirrors BotGunnery.build_lattice_at / _refine and PointTable.build.

use godot::prelude::*;
use rayon::prelude::*;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::{Arc, Condvar, Mutex, RwLock};

use super::point_store::{PtTable, Store};
use super::survey::{mc_score, walk_cell, Leaves, Refine};
use crate::projectile::armor::mesh::ArmorMesh;
use crate::projectile::armor::walk::ShellSpec;

/// BotGunnery's lattice constants, sent with each job so GDScript stays their one source.
#[derive(Clone, Copy, Default)]
pub(crate) struct Consts {
    pub lattice_cells: f64,
    pub lattice_min: f64,
    pub lattice_max: f64,
    pub fine_y_lo: f64,
    pub fine_y_hi: f64,
    pub fine_row_m: f64,
    pub fine_rows_max: f64,
    pub fine_descent_max: f64,
    pub sub_cell_m: f64,
    pub sub_max: f64,
    pub anchor_gap_cols: f64,
    pub anchor_gap_v: f64,
    pub cells: f64,
}

pub(crate) struct Job {
    pub key: String,
    pub mesh: Arc<ArmorMesh>,
    pub aabb: Aabb,
    pub spec: ShellSpec,
    pub shell_r: Vec<f64>,
    pub shell_desc: Vec<f64>,
    pub shell_v: Vec<f64>,
    pub shell_step: f64,
    pub ranges: Vec<f64>,
    pub half_disp: Vec<Vector2>,
    pub bias: Vec<f64>,
    pub lead: Vec<f64>,
    pub lead_band: f64,
    pub aspects: Vec<f64>,
    pub points: Vec<Vector3>,
    pub features: Vec<Vector3>,
    pub mc_off: Vec<Vector2>,
    pub mc_lead: Vec<Vector2>,
    pub comp: Vec<f64>,
    pub n_comp: usize,
    pub sections: Vec<i32>,
    pub sat_w: [f32; 4],
    pub secondary: bool,
    pub turret_cap: f64,
    pub c: Consts,
}

#[derive(Default)]
pub(crate) struct JobState {
    pub total: usize,
    pub done: usize,
    pub walks: u64,
    pub submitted: Option<std::time::Instant>,
    pub finished_ms: f64,
    /// Buckets per range rank from the top, built and total.
    pub rank_done: Vec<usize>,
    pub rank_total: Vec<usize>,
    /// ms from submit until the two longest ranges were built (a max-range lookup blends both); -1 until then.
    pub opening_ms: f64,
}

/// One bucket to build: ordered by range rank from the top (0 = a job's longest range), then submission order,
/// so every pair's opening ranges are built before any pair's closer ones.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
struct Task {
    /// Main-battery jobs before any secondary one.
    main: bool,
    rank: std::cmp::Reverse<usize>,
    seq: std::cmp::Reverse<usize>,
    ri: usize,
    ai: usize,
}

#[derive(Default)]
struct Shared {
    tasks: std::collections::BinaryHeap<Task>,
    jobs: Vec<Arc<Job>>,
    results: HashMap<String, JobState>,
    busy_ms: f64,
    /// Over every job: buckets per range rank built and total, and ms from the first submit until each rank was
    /// complete everywhere (-1 until then).
    rank_done: Vec<usize>,
    rank_total: Vec<usize>,
    rank_ms: Vec<f64>,
    first_submit: Option<std::time::Instant>,
}

pub(crate) struct PointWorker {
    shared: Arc<(Mutex<Shared>, Condvar)>,
    store: Store,
    stop: Arc<AtomicBool>,
    threads: Vec<std::thread::JoinHandle<()>>,
}

/// Buckets handed to the pool at a time: small enough that a job submitted later still gets its opening
/// ranges in early, large enough to keep every thread busy.
const BATCH_PER_THREAD: usize = 4;

impl PointWorker {
    /// One coordinator thread feeding batches of the highest-priority buckets to a `threads`-wide rayon pool.
    pub fn start(threads: usize, store: Store) -> Self {
        let shared: Arc<(Mutex<Shared>, Condvar)> = Arc::default();
        let stop = Arc::new(AtomicBool::new(false));
        let n = threads.max(1);
        let pool = Arc::new(rayon::ThreadPoolBuilder::new().num_threads(n)
            .thread_name(|i| format!("point-table-{i}")).build().unwrap());
        let (sh, st, pl, sto) = (shared.clone(), stop.clone(), pool, store.clone());
        let t = std::thread::Builder::new().name("point-table".into()).spawn(move || {
            loop {
                let batch: Vec<(Arc<Job>, usize, usize, usize)> = {
                    let (m, cv) = &*sh;
                    let mut g = m.lock().unwrap();
                    while g.tasks.is_empty() && !st.load(Relaxed) {
                        g = cv.wait(g).unwrap();
                    }
                    if st.load(Relaxed) {
                        return;
                    }
                    let mut out = Vec::new();
                    while out.len() < n * BATCH_PER_THREAD {
                        let Some(t) = g.tasks.pop() else { break };
                        out.push((g.jobs[t.seq.0].clone(), t.ri, t.ai, t.rank.0));
                    }
                    out
                };
                let t0 = std::time::Instant::now();
                let shc = sh.clone();
                let stop2 = st.clone();
                pl.install(|| {
                    batch.par_iter().for_each(|(job, ri, ai, rank)| {
                        if stop2.load(Relaxed) {
                            return;
                        }
                        let (vals, walks) = build_bucket(job, *ri, *ai);
                        if let Some(v) = vals {
                            let t = sto.read().unwrap().get(&job.key).cloned();
                            if let Some(t) = t {
                                t.write().unwrap().insert(ri * job.aspects.len() + ai, v);
                            }
                        }
                        let mut g = shc.0.lock().unwrap();
                        let r = g.results.entry(job.key.clone()).or_default();
                        r.done += 1;
                        r.walks += walks;
                        let since = r.submitted.map_or(0.0, |s| s.elapsed().as_secs_f64() * 1000.0);
                        if r.done == r.total {
                            r.finished_ms = since;
                        }
                        r.rank_done[*rank] += 1;
                        let open = (0..r.rank_total.len().min(2)).all(|k| r.rank_done[k] >= r.rank_total[k]);
                        if open && r.opening_ms < 0.0 {
                            r.opening_ms = since;
                        }
                        if job.secondary {
                            return;
                        }
                        g.rank_done[*rank] += 1;
                        if g.rank_done[*rank] >= g.rank_total[*rank] && g.rank_ms[*rank] < 0.0 {
                            g.rank_ms[*rank] = g.first_submit.map_or(0.0, |s| s.elapsed().as_secs_f64() * 1000.0);
                        }
                    });
                });
                sh.0.lock().unwrap().busy_ms += t0.elapsed().as_secs_f64() * 1000.0;
            }
        }).expect("point-table thread");
        PointWorker { shared, store, stop, threads: vec![t] }
    }

    pub fn submit(&self, job: Job) {
        let ranges = usable_ranges(&job);
        let n_aspect = job.aspects.len();
        self.store.write().unwrap().insert(job.key.clone(), Arc::new(RwLock::new(PtTable::new(
            job.ranges[..ranges].to_vec(), job.aspects.clone(), job.points.clone(), job.n_comp, job.sections.clone(), job.sat_w))));
        let (m, cv) = &*self.shared;
        let mut g = m.lock().unwrap();
        let seq = g.jobs.len();
        if g.first_submit.is_none() {
            g.first_submit = Some(std::time::Instant::now());
        }
        let r = g.results.entry(job.key.clone()).or_default();
        r.submitted = Some(std::time::Instant::now());
        r.total = ranges * n_aspect;
        r.rank_done = vec![0; ranges];
        r.rank_total = vec![n_aspect; ranges];
        r.opening_ms = if ranges == 0 { 0.0 } else { -1.0 };
        if g.rank_total.len() < ranges {
            g.rank_total.resize(ranges, 0);
            g.rank_done.resize(ranges, 0);
            g.rank_ms.resize(ranges, -1.0);
        }
        for k in 0..if job.secondary { 0 } else { ranges } {
            g.rank_total[k] += n_aspect;
            // A rank someone else finished is open again until this job's buckets for it are built.
            g.rank_ms[k] = -1.0;
        }
        for ri in 0..ranges {
            for ai in 0..n_aspect {
                g.tasks.push(Task { main: !job.secondary, rank: std::cmp::Reverse(ranges - 1 - ri), seq: std::cmp::Reverse(seq), ri, ai });
            }
        }
        g.jobs.push(Arc::new(job));
        cv.notify_all();
    }

    /// (done, total, finished_ms, walks, opening_ms) of `key`, or None if never submitted.
    pub fn status(&self, key: &str) -> Option<(usize, usize, f64, u64, f64)> {
        let g = self.shared.0.lock().unwrap();
        g.results.get(key).map(|r| (r.done, r.total, r.finished_ms, r.walks, r.opening_ms))
    }

    /// Per range rank from the top: ms from the first submit until every job had built it, -1 while not.
    pub fn rank_ms(&self) -> Vec<f64> {
        self.shared.0.lock().unwrap().rank_ms.clone()
    }

    pub fn busy_ms(&self) -> f64 {
        self.shared.0.lock().unwrap().busy_ms
    }

    /// Buckets not yet started.
    pub fn pending(&self) -> usize {
        self.shared.0.lock().unwrap().tasks.len()
    }
}

impl Drop for PointWorker {
    fn drop(&mut self) {
        self.stop.store(true, Relaxed);
        self.shared.1.notify_all();
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

/// Ranges with a shell solution, as PointTable.build stops at the first without one.
fn usable_ranges(job: &Job) -> usize {
    job.ranges.iter().take_while(|&&r| shell_at(job, r).is_some()).count()
}

/// (descent deg, speed) at `r`, as BotGunnery._shell_at.
fn shell_at(job: &Job, r: f64) -> Option<(f64, f64)> {
    let rs = &job.shell_r;
    if rs.len() < 2 || r > rs[rs.len() - 1] + job.shell_step {
        return None;
    }
    let i = rs.partition_point(|&x| x < r).clamp(1, rs.len() - 1);
    let f = ((r - rs[i - 1]) / (rs[i] - rs[i - 1])).clamp(0.0, 1.0);
    Some((job.shell_desc[i - 1] + (job.shell_desc[i] - job.shell_desc[i - 1]) * f,
        job.shell_v[i - 1] + (job.shell_v[i] - job.shell_v[i - 1]) * f))
}

fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

/// BotGunnery.lead_axes.
fn lead_axes(job: &Job, desc_deg: f64, aspect_deg: f64, range_m: f64) -> Vector2 {
    let bands = job.lead.len() / 2;
    if bands == 0 {
        return Vector2::ZERO;
    }
    let t = (range_m / job.lead_band - 0.5).clamp(0.0, (bands - 1) as f64);
    let i = (t as usize).min(bands.saturating_sub(2));
    let j = (i + 1).min(bands - 1);
    let f = t - i as f64;
    let al = lerp(job.lead[2 * i], job.lead[2 * j], f);
    let ac = lerp(job.lead[2 * i + 1], job.lead[2 * j + 1], f);
    let (sa, ca) = (aspect_deg.to_radians().sin(), aspect_deg.to_radians().cos());
    Vector2::new(((al * sa).powi(2) + (ac * ca).powi(2)).sqrt() as f32,
        (((al * ca).powi(2) + (ac * sa).powi(2)).sqrt() * desc_deg.to_radians().sin()) as f32)
}

/// PointTable.lead_bias_along.
fn bias_along(job: &Job, r: f64) -> f64 {
    let rows = &job.bias;
    if rows.is_empty() {
        return 0.0;
    }
    let t = (r / job.lead_band - 0.5).clamp(0.0, (rows.len() - 1) as f64);
    let i = (t as usize).min(rows.len() - 1);
    lerp(rows[i], rows[(i + 1).min(rows.len() - 1)], t - i as f64)
}

struct Frame {
    fwd: Vector3,
    right: Vector3,
    up: Vector3,
}

fn frame(aspect_deg: f64) -> Frame {
    let a = aspect_deg.to_radians() as f32;
    let fwd = -Vector3::new(a.sin(), 0.0, -a.cos());
    let mut right = fwd.cross(Vector3::UP);
    if right.length_squared() < 0.0001 {
        right = fwd.cross(Vector3::RIGHT);
    }
    let right = right.normalized();
    Frame { fwd, right, up: right.cross(fwd).normalized() }
}

fn to_plane(p: Vector3, dir: Vector3, f: &Frame) -> Vector2 {
    let dn = dir.dot(f.fwd);
    let q = if dn.abs() > 1e-4 { p - dir * (p.dot(f.fwd) / dn) } else { p };
    Vector2::new(q.dot(f.right), q.dot(f.up))
}

fn uniform_edges(lo: f64, hi: f64, n: usize) -> Vec<f32> {
    (0..=n).map(|i| (lo + (hi - lo) * i as f64 / n as f64) as f32).collect()
}

/// BotGunnery._row_edges.
fn row_edges(c: &Consts, lo: f64, hi: f64, n_u: usize, band_lo: f64, band_hi: f64, fine: bool) -> Vec<f32> {
    if !fine || band_hi <= band_lo {
        return uniform_edges(lo, hi, n_u);
    }
    let dv = (hi - lo) / n_u as f64;
    let mut b_lo = band_lo.max(lo);
    let b_hi = band_hi.min(hi);
    let mut out: Vec<f32> = Vec::new();
    let n_below = ((b_lo - lo) / dv).round() as i64;
    if n_below <= 0 {
        b_lo = lo;
    } else {
        out.extend(uniform_edges(lo, b_lo, n_below as usize));
        out.pop();
    }
    let n_fine = (((b_hi - b_lo) / c.fine_row_m).round() as i64).clamp(2, c.fine_rows_max as i64) as usize;
    out.extend(uniform_edges(b_lo, b_hi, n_fine));
    let n_above = ((hi - b_hi) / dv).round() as i64;
    if n_above <= 0 {
        let l = out.len();
        out[l - 1] = hi as f32;
    } else {
        let above = uniform_edges(b_hi, hi, n_above as usize);
        out.extend_from_slice(&above[1..]);
    }
    out
}

struct Lattice {
    nx: usize,
    ny: usize,
    rect: [f32; 4],
    dir: Vector3,
    edges: Vec<f32>,
    points: Vec<Vector3>,
    refine: Refine,
}

/// BotGunnery.build_lattice_at + _refine.
fn lattice(job: &Job, f: &Frame, descent_deg: f64) -> Option<Lattice> {
    let c = &job.c;
    let d = descent_deg.to_radians() as f32;
    let dir = (f.fwd * d.cos() + Vector3::DOWN * d.sin()).normalized();
    let b = job.aabb;
    if b.size == Vector3::ZERO {
        return None;
    }
    let (mut lo, mut hi) = (Vector2::new(f32::INFINITY, f32::INFINITY), Vector2::new(f32::NEG_INFINITY, f32::NEG_INFINITY));
    let (mut band_lo, mut band_hi) = (f64::INFINITY, f64::NEG_INFINITY);
    for i in 0..8 {
        let mut p = Vector3::new(
            if i & 1 == 0 { b.position.x } else { b.position.x + b.size.x },
            if i & 2 == 0 { b.position.y } else { b.position.y + b.size.y },
            if i & 4 == 0 { b.position.z } else { b.position.z + b.size.z });
        p.y = p.y.max(c.fine_y_lo as f32);
        let q = to_plane(p, dir, f);
        lo = Vector2::new(lo.x.min(q.x), lo.y.min(q.y));
        hi = Vector2::new(hi.x.max(q.x), hi.y.max(q.y));
        p.y = p.y.clamp(c.fine_y_lo as f32, c.fine_y_hi as f32);
        let qb = to_plane(p, dir, f).y as f64;
        band_lo = band_lo.min(qb);
        band_hi = band_hi.max(qb);
    }
    let w = ((hi.x - lo.x) as f64).max(1.0);
    let h = ((hi.y - lo.y) as f64).max(1.0);
    let cap = c.lattice_max.max((c.lattice_max * (c.cells / c.lattice_cells).sqrt()).round());
    let nx = (c.cells * w / h).sqrt().round().clamp(c.lattice_min, cap) as usize;
    let ny_u = (c.cells / nx as f64).round().clamp(3.0, cap) as usize;
    let rect = [lo.x, lo.y, (lo.x as f64 + w) as f32, (lo.y as f64 + h) as f32];
    let edges = row_edges(c, rect[1] as f64, rect[3] as f64, ny_u, band_lo, band_hi, descent_deg < c.fine_descent_max);
    let ny = edges.len() - 1;
    let du = ((rect[2] - rect[0]) / nx as f32) as f64;
    let mut points = Vec::with_capacity(nx * ny);
    for iy in 0..ny {
        let v = 0.5 * (edges[iy] + edges[iy + 1]);
        for ix in 0..nx {
            points.push(f.right * (rect[0] + (ix as f32 + 0.5) * du as f32) + f.up * v);
        }
    }
    // _refine: split the feature points' cells and the cells above and below them.
    let mut anchors: Vec<(f32, f32)> = Vec::new();
    let mut split: Vec<usize> = Vec::new();
    for &p in &job.features {
        let q = to_plane(p, dir, f);
        if q.x <= rect[0] || q.x >= rect[2] || q.y <= rect[1] || q.y >= rect[3] || anchors.len() >= 255 {
            continue;
        }
        if anchors.iter().any(|a| ((a.0 - q.x).abs() as f64) < c.anchor_gap_cols * du && ((a.1 - q.y).abs() as f64) < c.anchor_gap_v) {
            continue;
        }
        anchors.push((q.x, q.y));
        let ix = (((q.x - rect[0]) as f64 / du) as i64).clamp(0, nx as i64 - 1) as usize;
        let iy = (edges.partition_point(|&e| e < q.y) as i64 - 1).clamp(0, ny as i64 - 1) as usize;
        for dy in [-1i64, 0, 1] {
            let y = iy as i64 + dy;
            if y >= 0 && (y as usize) < ny {
                split.push(y as usize * nx + ix);
            }
        }
    }
    split.sort_unstable();
    split.dedup();
    let kx = ((du / c.sub_cell_m - 0.001).ceil() as i64).clamp(1, c.sub_max as i64) as usize;
    let ky: Vec<usize> = (0..ny)
        .map(|iy| ((((edges[iy + 1] - edges[iy]) as f64) / c.sub_cell_m - 0.001).ceil() as i64).clamp(1, c.sub_max as i64) as usize)
        .collect();
    let mut n_sub = 0;
    for &cell in &split {
        let (ix, iy) = (cell % nx, cell / nx);
        for sy in 0..ky[iy] {
            let v = edges[iy] + (edges[iy + 1] - edges[iy]) * ((sy as f32 + 0.5) / ky[iy] as f32);
            for sx in 0..kx {
                points.push(f.right * (rect[0] + (ix as f32 + (sx as f32 + 0.5) / kx as f32) * du as f32) + f.up * v);
            }
        }
        n_sub += kx * ky[iy];
    }
    Some(Lattice { nx, ny, rect, dir, edges, points, refine: Refine { kx, ky, cells: split, anchors, n_sub } })
}

/// One bucket's values (per point n_comp components then landed) and the walks it took.
fn build_bucket(job: &Job, ri: usize, ai: usize) -> (Option<Vec<f32>>, u64) {
    let r = job.ranges[ri];
    let Some(at) = shell_at(job, r) else { return (None, 0) };
    let aspect = job.aspects[ai];
    let f = frame(aspect);
    let Some(lat) = lattice(job, &f, at.0) else { return (None, 0) };
    let a = aspect.to_radians() as f32;
    let gun = Vector3::new(a.sin(), 0.0, -a.cos()) * r as f32;
    let codes: Vec<u8> = lat.points.iter().map(|&p| {
        let hv = Vector3::new(p.x - gun.x, 0.0, p.z - gun.z);
        let s = shell_at(job, hv.length() as f64).unwrap_or(at);
        let d = s.0.to_radians() as f32;
        let dir = hv.normalized() * d.cos() + Vector3::DOWN * d.sin();
        walk_cell(&job.mesh, job.aabb, &job.spec, p, dir.normalized(), s.1, false).0
    }).collect();
    let bias = Vector3::new(0.0, 0.0, -bias_along(job, r) as f32);
    let aims: Vec<Vector2> = job.points.iter().map(|&p| to_plane(p + bias, lat.dir, &f)).collect();
    let ve: Vec<f64> = lat.edges.iter().map(|&e| e as f64).collect();
    let leaves = Leaves::new(lat.nx, lat.ny, lat.rect[0] as f64, lat.rect[2] as f64, &ve, Some(&lat.refine));
    let lead_sd = lead_axes(job, at.0, aspect, r);
    let vals = mc_score(&codes, &leaves, &aims, job.half_disp[ri], lead_sd, &job.mc_off, &job.mc_lead, &job.comp,
        job.n_comp, job.turret_cap);
    (Some(vals), codes.len() as u64)
}
