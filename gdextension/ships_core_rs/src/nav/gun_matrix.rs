use godot::prelude::*;
use rayon::prelude::*;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, AtomicUsize, Ordering::{Acquire, Relaxed, Release}};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::Duration;

use crate::nav::reach::{new_table, segment_clear, RBlockTable, Shell, Terrain};

/// Threads filling tables in the background; the main thread keeps the rest.
const MATRIX_THREADS: usize = 4;
/// Rows computed per worker turn.
const BATCH_ROWS: usize = 32;
/// The row order follows its ships' latest positions at most this often.
const REORDER_EVERY: Duration = Duration::from_secs(2);
const IDLE_SLEEP: Duration = Duration::from_millis(50);

/// The VisibilityGrid's water cells and their line of sight, owned by the worker.
pub(crate) struct Cells {
    pub centres: Vec<Vector2>,
    pub los: Vec<u64>,
    pub los_stride: usize,
}

impl Cells {
    fn seen(&self, i: usize, j: usize) -> bool {
        self.los[i * self.los_stride + j / 64] >> (j % 64) & 1 != 0
    }
}

/// One gun kind's answer, cell to cell: bit (i, j) set when a shell fired from
/// water cell i lands on cell j. Rows fill in the background, nearest the ships
/// carrying the gun first; a row is read only once its `ready` flag is set.
pub(crate) struct GunMatrix {
    pub key: i64,
    pub cap: f32,
    shell: Shell,
    /// Built and zeroed on the worker the first time it needs them, not at registration.
    table: OnceLock<Arc<RBlockTable>>,
    words: usize,
    bits: OnceLock<Box<[AtomicU64]>>,
    ready: Box<[AtomicBool]>,
    pub done: AtomicUsize,
    /// Per team, where ships carrying this gun are believed to be.
    sites: Mutex<[Vec<Vector2>; 2]>,
    /// Unbuilt rows, nearest a site first, and when it was sorted.
    order: Mutex<(Vec<u32>, Option<std::time::Instant>)>,
    /// FILE_* progress with the disk cache.
    pub file: AtomicU8,
}

pub(crate) const FILE_UNTRIED: u8 = 0;
pub(crate) const FILE_LOADED: u8 = 1;
pub(crate) const FILE_NONE: u8 = 2;
pub(crate) const FILE_SAVED: u8 = 3;

/// Where tables are cached and whether completed ones are written; reading always happens.
#[derive(Clone)]
pub(crate) struct CacheCfg {
    pub dir: PathBuf,
    pub map: i64,
    pub save: bool,
}

impl CacheCfg {
    fn path(&self, key: i64) -> PathBuf {
        self.dir.join(format!("{:016x}_{:016x}.gmx", self.map, key))
    }
}

impl GunMatrix {
    pub fn new(key: i64, shell: Shell, n: usize) -> Self {
        GunMatrix {
            key,
            cap: shell.range,
            shell,
            table: OnceLock::new(),
            words: n.div_ceil(64),
            bits: OnceLock::new(),
            ready: (0..n).map(|_| AtomicBool::new(false)).collect(),
            done: AtomicUsize::new(0),
            sites: Mutex::new([Vec::new(), Vec::new()]),
            order: Mutex::new((Vec::new(), None)),
            file: AtomicU8::new(FILE_UNTRIED),
        }
    }

    pub fn rows(&self) -> usize {
        self.ready.len()
    }

    pub fn complete(&self) -> bool {
        self.done.load(Acquire) == self.rows()
    }

    pub fn set_sites(&self, team: usize, sites: Vec<Vector2>) {
        self.sites.lock().unwrap()[team.min(1)] = sites;
    }

    fn row_ready(&self, i: usize) -> bool {
        self.ready[i].load(Acquire)
    }

    fn bits(&self) -> &[AtomicU64] {
        self.bits.get_or_init(|| (0..self.rows() * self.words).map(|_| AtomicU64::new(0)).collect())
    }

    fn table(&self) -> &RBlockTable {
        self.table.get_or_init(|| new_table(self.shell.speed, self.shell.drag, self.shell.gun_h, 0.0, self.shell.range))
    }

    fn bit(&self, i: usize, j: usize) -> bool {
        self.bits()[i * self.words + j / 64].load(Relaxed) >> (j % 64) & 1 != 0
    }

    /// Whether a shell from one of `origins` (cells `origin_cells`) lands on
    /// query cell `k` at `p` (outbound), or from `p` lands on one of them;
    /// None while a row it needs is unbuilt.
    pub fn answer(&self, origins: &[Vector2], origin_cells: &[i32], k: i32, p: Vector2, range: f32, outbound: bool) -> Option<bool> {
        if k < 0 {
            return None;
        }
        let mut unready = false;
        for (o, &c) in origins.iter().zip(origin_cells) {
            if c < 0 {
                return None;
            }
            if p.distance_to(*o) > range.min(self.cap) {
                continue;
            }
            let (row, col) = if outbound { (c as usize, k as usize) } else { (k as usize, c as usize) };
            if !self.row_ready(row) {
                unready = true;
            } else if self.bit(row, col) {
                return Some(true);
            }
        }
        if unready { None } else { Some(false) }
    }

    /// Next unbuilt rows, nearest a site first.
    fn next_rows(&self, cells: &Cells) -> Vec<usize> {
        let mut o = self.order.lock().unwrap();
        if o.1.is_none_or(|t| t.elapsed() >= REORDER_EVERY) {
            let sites: Vec<Vector2> = self.sites.lock().unwrap().iter().flatten().copied().collect();
            let near = |i: usize| sites.iter().map(|s| s.distance_squared_to(cells.centres[i])).fold(f32::INFINITY, f32::min);
            let mut rows: Vec<(f32, u32)> = (0..self.rows()).filter(|&i| !self.row_ready(i)).map(|i| (near(i), i as u32)).collect();
            rows.sort_unstable_by(|a, b| b.0.total_cmp(&a.0));
            *o = (rows.into_iter().map(|r| r.1).collect(), Some(std::time::Instant::now()));
        }
        let mut out = Vec::with_capacity(BATCH_ROWS);
        while out.len() < BATCH_ROWS {
            let Some(i) = o.0.pop() else { break };
            if !self.row_ready(i as usize) {
                out.push(i as usize);
            }
        }
        out
    }

    fn build_row(&self, i: usize, terrain: &Terrain, cells: &Cells) {
        let o = cells.centres[i];
        let mut row = vec![0u64; self.words];
        for (j, &c) in cells.centres.iter().enumerate() {
            let d = c - o;
            let dist = d.length();
            let hit = dist < 1.0 || (dist <= self.cap && (cells.seen(i, j)
                || segment_clear(terrain, self.table(), o, d.x / dist, d.y / dist, dist, self.shell.gun_h)));
            if hit {
                row[j / 64] |= 1 << (j % 64);
            }
        }
        self.publish(i, &row);
    }

    fn publish(&self, i: usize, row: &[u64]) {
        let bits = self.bits();
        for (w, &v) in row.iter().enumerate() {
            bits[i * self.words + w].store(v, Relaxed);
        }
        if !self.ready[i].swap(true, Release) {
            self.done.fetch_add(1, Release);
        }
    }

    /// Every row, u64 little-endian; empty until complete.
    pub fn to_bytes(&self) -> Vec<u8> {
        if !self.complete() {
            return Vec::new();
        }
        self.bits().iter().flat_map(|w| w.load(Relaxed).to_le_bytes()).collect()
    }

    /// Adopts a saved table; false when its size does not match.
    pub fn load(&self, bytes: &[u8]) -> bool {
        if bytes.len() != self.rows() * self.words * 8 {
            return false;
        }
        for i in 0..self.rows() {
            let row: Vec<u64> = (0..self.words)
                .map(|w| u64::from_le_bytes(bytes[(i * self.words + w) * 8..][..8].try_into().unwrap()))
                .collect();
            self.publish(i, &row);
        }
        true
    }

    /// Reads its cache file, deflated; false when absent or the wrong size.
    fn read(&self, cfg: &CacheCfg) -> bool {
        let Ok(z) = std::fs::read(cfg.path(self.key)) else { return false };
        miniz_oxide::inflate::decompress_to_vec(&z).is_ok_and(|b| self.load(&b))
    }

    /// Writes the complete table, deflated, through a per-process temp file.
    fn write(&self, cfg: &CacheCfg) -> bool {
        let path = cfg.path(self.key);
        let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
        let z = miniz_oxide::deflate::compress_to_vec(&self.to_bytes(), 6);
        std::fs::create_dir_all(&cfg.dir).is_ok() && std::fs::write(&tmp, z).is_ok() && std::fs::rename(&tmp, &path).is_ok()
    }

    /// Loads before building, saves once complete: all on the worker, never the main thread.
    fn sync_file(&self, cfg: &Option<CacheCfg>) {
        let Some(cfg) = cfg else { return };
        match self.file.load(Acquire) {
            FILE_UNTRIED => {
                let state = if self.read(cfg) { FILE_LOADED } else { FILE_NONE };
                self.file.store(state, Release);
            }
            FILE_NONE if cfg.save && self.complete() && !cfg.path(self.key).exists() => {
                if self.write(cfg) {
                    self.file.store(FILE_SAVED, Release);
                }
            }
            _ => {}
        }
    }
}

/// Fills every registered table's rows until all are complete or it is stopped.
pub(crate) struct MatrixWorker {
    pub matrices: Arc<RwLock<Vec<Arc<GunMatrix>>>>,
    pub cache: Arc<Mutex<Option<CacheCfg>>>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl MatrixWorker {
    pub fn start(terrain: Arc<Terrain>, cells: Arc<Cells>) -> Self {
        let matrices: Arc<RwLock<Vec<Arc<GunMatrix>>>> = Arc::default();
        let cache: Arc<Mutex<Option<CacheCfg>>> = Arc::default();
        let stop = Arc::new(AtomicBool::new(false));
        let (m, st, c) = (matrices.clone(), stop.clone(), cache.clone());
        let thread = std::thread::Builder::new().name("gun-matrix".into()).spawn(move || {
            let pool = rayon::ThreadPoolBuilder::new().num_threads(MATRIX_THREADS)
                .thread_name(|i| format!("gun-matrix-{i}")).build().unwrap();
            let mut turn = 0usize;
            while !st.load(Relaxed) {
                let cfg = c.lock().unwrap().clone();
                let all: Vec<Arc<GunMatrix>> = m.read().unwrap().clone();
                for g in &all {
                    g.sync_file(&cfg);
                }
                // A table is built once the cache has had its say, or straight away without one.
                let open: Vec<Arc<GunMatrix>> = all.into_iter()
                    .filter(|g| !g.complete() && (cfg.is_none() || g.file.load(Acquire) != FILE_UNTRIED))
                    .collect();
                if open.is_empty() {
                    std::thread::sleep(IDLE_SLEEP);
                    continue;
                }
                let g = &open[turn % open.len()];
                turn += 1;
                let rows = g.next_rows(&cells);
                pool.install(|| rows.par_iter().for_each(|&i| g.build_row(i, &terrain, &cells)));
            }
        }).expect("gun-matrix thread");
        MatrixWorker { matrices, cache, stop, thread: Some(thread) }
    }
}

impl Drop for MatrixWorker {
    fn drop(&mut self) {
        self.stop.store(true, Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
