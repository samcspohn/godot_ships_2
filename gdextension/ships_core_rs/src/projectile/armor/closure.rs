//! Armour parts must be closed: `ArmorMesh::part_at` needs all six axis rays to cross a part.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::sync::{Mutex, OnceLock};

use godot::classes::ProjectSettings;
use godot::obj::Singleton;
use godot::global::godot_warn;
use rayon::prelude::*;

use super::mesh::{PartMesh, V3};
use crate::nav::reach::nav_pool;

const VERSION: u64 = 1;
const CACHE_PATH: &str = "user://armor_closure.cache";
const TARGET_SAMPLES: f64 = 200_000.0;
/// Off-grid so rays miss axis-aligned faces and edges.
const PHASE: f64 = 0.371;

const DIRS: [V3; 6] = [
    V3::new(1.0, 0.0, 0.0), V3::new(-1.0, 0.0, 0.0),
    V3::new(0.0, 1.0, 0.0), V3::new(0.0, -1.0, 0.0),
    V3::new(0.0, 0.0, 1.0), V3::new(0.0, 0.0, -1.0),
];

#[derive(Clone, Copy, Debug)]
pub struct Verdict {
    pub samples: u32,
    pub leaks: u32,
    pub first_leak: V3,
}

struct Cache {
    path: String,
    verdicts: HashMap<u64, Verdict>,
    warned: HashSet<u64>,
}

static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();

fn cache() -> &'static Mutex<Cache> {
    CACHE.get_or_init(|| {
        let path = ProjectSettings::singleton().globalize_path(CACHE_PATH).to_string();
        let mut verdicts = HashMap::new();
        for line in std::fs::read_to_string(&path).unwrap_or_default().lines() {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() != 6 {
                continue;
            }
            let (Ok(h), Ok(samples), Ok(leaks), Ok(x), Ok(y), Ok(z)) = (
                u64::from_str_radix(f[0], 16), f[1].parse(), f[2].parse(),
                f[3].parse(), f[4].parse(), f[5].parse(),
            ) else { continue };
            verdicts.insert(h, Verdict { samples, leaks, first_leak: V3::new(x, y, z) });
        }
        Mutex::new(Cache { path, verdicts, warned: HashSet::new() })
    })
}

pub fn content_hash(part: &PartMesh) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325 ^ VERSION;
    for t in &part.tris {
        for v in [t.v0, t.v1, t.v2] {
            for c in [v.x, v.y, v.z] {
                for b in c.to_bits().to_le_bytes() {
                    h ^= b as u64;
                    h = h.wrapping_mul(0x0100_0000_01b3);
                }
            }
        }
    }
    h
}

/// Leak: most axis rays say inside, another misses the part. Majority so open internal sheets pass.
pub fn scan(part: &PartMesh) -> Verdict {
    let Some((min, max)) = part.local_bounds() else {
        return Verdict { samples: 0, leaks: 0, first_leak: V3::default() };
    };
    let ext = max.sub(min);
    let vol = ext.x.max(1e-3) * ext.y.max(1e-3) * ext.z.max(1e-3);
    let step = (vol / TARGET_SAMPLES).cbrt().max(0.05);
    let n = |e: f64| ((e / step).floor() as usize).max(1);
    let (nx, ny, nz) = (n(ext.x), n(ext.y), n(ext.z));
    let reach = ext.length() + 10.0;
    let at = |i: usize| {
        let (x, y, z) = (i % nx, (i / nx) % ny, i / (nx * ny));
        let c = |lo: f64, k: usize, m: usize, e: f64| lo + e * (k as f64 + PHASE) / m as f64;
        V3::new(c(min.x, x, nx, ext.x), c(min.y, y, ny, ext.y), c(min.z, z, nz, ext.z))
    };
    let total = nx * ny * nz;
    let leaks: Vec<usize> = nav_pool().install(|| {
        (0..total).into_par_iter().filter(|&i| {
            let p = at(i);
            let mut odd = 0;
            let mut miss = false;
            for d in DIRS {
                let c = part.crossings(p.add(d.scale(reach)), p);
                odd += c & 1;
                miss |= c == 0;
            }
            odd >= 4 && miss
        }).collect()
    });
    Verdict {
        samples: total as u32,
        leaks: leaks.len() as u32,
        first_leak: leaks.first().map(|&i| at(i)).unwrap_or_default(),
    }
}

pub fn check(part: &PartMesh, label: &str) {
    let h = content_hash(part);
    let mut c = cache().lock().unwrap();
    let v = match c.verdicts.get(&h) {
        Some(v) => *v,
        None => {
            let v = scan(part);
            c.verdicts.insert(h, v);
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&c.path) {
                let p = v.first_leak;
                let _ = writeln!(f, "{h:016x} {} {} {} {} {}", v.samples, v.leaks, p.x, p.y, p.z);
            }
            v
        }
    };
    if v.leaks > 0 && c.warned.insert(h) {
        let p = v.first_leak;
        godot_warn!(
            "armor mesh not closed: {label} — {}/{} interior samples leak (e.g. part-local ({:.2}, {:.2}, {:.2})); shells detonating there resolve as overpen",
            v.leaks, v.samples, p.x, p.y, p.z
        );
    }
}
