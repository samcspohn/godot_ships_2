use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

#[derive(Clone, Copy, Debug)]
pub(crate) struct Cpu {
    pub id: usize,
    /// Dense 0..nodes, not the kernel's node id.
    pub node: usize,
    pub pkg: usize,
    pub l3: usize,
    pub core: usize,
}

fn read_usize(path: &str) -> Option<usize> {
    fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn allowed_cpus() -> Vec<usize> {
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        if libc::sched_getaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &mut set) != 0 {
            return (0..std::thread::available_parallelism().map_or(1, |n| n.get())).collect();
        }
        (0..libc::CPU_SETSIZE as usize).filter(|&c| libc::CPU_ISSET(c, &set)).collect()
    }
}

/// Allowed CPUs ordered node, L3, core, SMT sibling, so that neighbouring
/// worker indices share the most cache.
pub(crate) fn cpu_order(smt: bool) -> Vec<Cpu> {
    let mut cpus: Vec<(usize, Cpu)> = allowed_cpus()
        .into_iter()
        .map(|id| {
            let base = format!("/sys/devices/system/cpu/cpu{id}");
            let node = fs::read_dir(&base)
                .ok()
                .and_then(|d| {
                    d.flatten().find_map(|e| e.file_name().to_str()?.strip_prefix("node")?.parse::<usize>().ok())
                })
                .unwrap_or(0);
            let pkg = read_usize(&format!("{base}/topology/physical_package_id")).unwrap_or(0);
            let core = read_usize(&format!("{base}/topology/core_id")).unwrap_or(id);
            let l3 = read_usize(&format!("{base}/cache/index3/id")).unwrap_or(pkg);
            (node, Cpu { id, node, pkg, l3, core })
        })
        .collect();
    cpus.sort_by_key(|(n, c)| (*n, c.pkg, c.l3, c.core, c.id));
    let mut nodes: Vec<usize> = cpus.iter().map(|(n, _)| *n).collect();
    nodes.dedup();
    let mut out: Vec<Cpu> = Vec::with_capacity(cpus.len());
    for (n, mut c) in cpus {
        c.node = nodes.iter().position(|&x| x == n).unwrap_or(0);
        if !smt && out.last().is_some_and(|p| p.pkg == c.pkg && p.core == c.core) {
            continue;
        }
        out.push(c);
    }
    out
}

fn pin(cpu: usize) {
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_SET(cpu, &mut set);
        libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set);
    }
}

/// Remaining [front, back) of one worker's items, packed so owner and thieves
/// race on a single word.
struct Range(AtomicU64);

impl Range {
    fn new(f: u32, b: u32) -> Self {
        Range(AtomicU64::new(((f as u64) << 32) | b as u64))
    }

    fn take(&self, front: bool) -> Option<usize> {
        let mut v = self.0.load(Ordering::Acquire);
        loop {
            let (f, b) = ((v >> 32) as u32, v as u32);
            if f >= b {
                return None;
            }
            let (nv, got) = if front { (v + (1 << 32), f) } else { (v - 1, b - 1) };
            match self.0.compare_exchange_weak(v, nv, Ordering::AcqRel, Ordering::Acquire) {
                Ok(_) => return Some(got as usize),
                Err(cur) => v = cur,
            }
        }
    }
}

pub(crate) struct Worker {
    pub node: usize,
}

#[derive(Default, Debug)]
pub(crate) struct RunStats {
    pub threads: usize,
    pub nodes: usize,
    pub wall_ms: f64,
    pub busy_ms: Vec<f64>,
    pub items: Vec<u32>,
    pub steals: u64,
    pub cross_node_steals: u64,
}

/// Runs `f` once per item on pinned workers. Items are cut into one contiguous
/// run per worker of equal `cost`, so items that share data land on
/// neighbouring cores; a drained worker steals single items from the back of
/// the nearest victim (sibling, L3, node, then the other node).
pub(crate) fn run_balanced<T, F>(costs: &[f64], threads: usize, smt: bool, f: F) -> (Vec<T>, RunStats)
where
    T: Send + Sync,
    F: Fn(usize, &Worker) -> T + Sync,
{
    let mut order = cpu_order(smt);
    if threads > 0 && threads < order.len() {
        order.truncate(threads);
    }
    let n = order.len().max(1);
    let t0 = Instant::now();

    let total: f64 = costs.iter().map(|c| c.max(0.0)).sum::<f64>().max(1e-9);
    let mut starts = vec![costs.len(); n + 1];
    let mut acc = 0.0;
    let mut w = 0;
    starts[0] = 0;
    for (i, c) in costs.iter().enumerate() {
        let owner = (((acc + 0.5 * c.max(0.0)) / total * n as f64) as usize).min(n - 1);
        while w < owner {
            w += 1;
            starts[w] = i;
        }
        acc += c.max(0.0);
    }
    for s in starts.iter_mut().skip(w + 1) {
        *s = costs.len();
    }
    let ranges: Vec<Range> = (0..n).map(|w| Range::new(starts[w] as u32, starts[w + 1] as u32)).collect();

    let class = |a: &Cpu, b: &Cpu| -> u8 {
        if a.pkg == b.pkg && a.core == b.core {
            0
        } else if a.l3 == b.l3 && a.pkg == b.pkg {
            1
        } else if a.node == b.node {
            2
        } else {
            3
        }
    };
    let victims: Vec<Vec<usize>> = (0..n)
        .map(|w| {
            let mut v: Vec<usize> = (0..n).filter(|&o| o != w).collect();
            v.sort_by_key(|&o| (class(&order[w], &order[o]), o.abs_diff(w)));
            v
        })
        .collect();

    let slots: Vec<OnceLock<T>> = (0..costs.len()).map(|_| OnceLock::new()).collect();
    let pin_order: Vec<usize> = order.iter().map(|c| c.id).collect();
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(n)
        .thread_name(|i| format!("bake-{i}"))
        .start_handler(move |i| pin(pin_order[i]))
        .build()
        .expect("bake pool");

    let per: Vec<(f64, u32, u64, u64)> = pool.broadcast(|ctx| {
        let w = ctx.index();
        let me = Worker { node: order[w].node };
        let (mut busy, mut items, mut steals, mut cross) = (0.0f64, 0u32, 0u64, 0u64);
        loop {
            let mut got = ranges[w].take(true);
            if got.is_none() {
                for &v in &victims[w] {
                    if let Some(i) = ranges[v].take(false) {
                        steals += 1;
                        if order[v].node != me.node {
                            cross += 1;
                        }
                        got = Some(i);
                        break;
                    }
                }
            }
            let Some(i) = got else { break };
            let s = Instant::now();
            let _ = slots[i].set(f(i, &me));
            busy += s.elapsed().as_secs_f64() * 1e3;
            items += 1;
        }
        (busy, items, steals, cross)
    });

    let stats = RunStats {
        threads: n,
        nodes: order.iter().map(|c| c.node).max().map_or(1, |m| m + 1),
        wall_ms: t0.elapsed().as_secs_f64() * 1e3,
        busy_ms: per.iter().map(|p| p.0).collect(),
        items: per.iter().map(|p| p.1).collect(),
        steals: per.iter().map(|p| p.2).sum(),
        cross_node_steals: per.iter().map(|p| p.3).sum(),
    };
    let out = slots.into_iter().map(|s| s.into_inner().expect("every item runs")).collect();
    (out, stats)
}
