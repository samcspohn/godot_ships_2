use godot::classes::{PhysicsDirectSpaceState3D, Resource};
use godot::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2 as P;
use crate::nav::map::NavigationMap;

/// Quarter cells the sim answers are kept per.
const QUARTER_M: f32 = 75.0;
const CACHE_MAX: usize = 200_000;

pub(crate) static SIMS: AtomicU64 = AtomicU64::new(0);
pub(crate) static SIM_HITS: AtomicU64 = AtomicU64::new(0);
pub(crate) static SIM_NS: AtomicU64 = AtomicU64::new(0);

thread_local! {
    static CACHE: RefCell<HashMap<(i64, i32, i32, i32), bool>> = RefCell::new(HashMap::new());
}

/// Our guns' own shot check (the shell flown over the real island colliders), for reach answers on the
/// matrix's edge, where its terrain model disagrees with the colliders most.
pub(crate) struct EdgeSim {
    shell: Gd<Resource>,
    nav: Gd<NavigationMap>,
    space: Gd<PhysicsDirectSpaceState3D>,
    gun_h: f32,
    key: i64,
    trees: Option<std::sync::Arc<crate::nav::edge_tree::EdgeTrees>>,
}

/// The key EdgeSim answers and EdgeTrees are kept under: one per shell resource and muzzle height.
pub(crate) fn edge_key(shell: &Gd<Resource>, gun_h: f32) -> i64 {
    shell.instance_id().to_i64() ^ ((gun_h * 10.0) as i64) << 48
}

/// The shell's (v0, beta, vt, tau) as the live solver reads them, `gun_h` and the gun's `range`.
pub(crate) fn shell_raw(shell: &Gd<Resource>, gun_h: f32, range: f32) -> Option<[f64; 6]> {
    let (v0, beta, vt, tau) = P::extract_params(shell)?;
    (v0 > 0.0 && beta > 0.0).then_some([v0, beta, vt, tau, gun_h as f64, range as f64])
}

/// SHIPS_EDGECHK: every 16th tree answer is also simulated; CHECKS by (tree, sim) within the gun's range, then
/// past it by sim.
static CHECK: std::sync::LazyLock<bool> = std::sync::LazyLock::new(|| std::env::var_os("SHIPS_EDGECHK").is_some());
pub(crate) static CHECKS: [AtomicU64; 6] = [const { AtomicU64::new(0) }; 6];

impl EdgeSim {
    pub(crate) fn from_opts(o: &VarDictionary) -> Option<Self> {
        let shell = o.get("sim_shell")?.try_to::<Gd<Resource>>().ok()?;
        let nav = o.get("sim_nav")?.try_to::<Gd<NavigationMap>>().ok()?;
        let space = o.get("sim_space")?.try_to::<Gd<PhysicsDirectSpaceState3D>>().ok()?;
        let gun_h = o.get("sim_gun_h").map_or(5.0, |v| v.to::<f32>());
        let range = o.get("sim_range").map_or(0.0, |v| v.to::<f32>());
        let key = edge_key(&shell, gun_h);
        let trees = crate::nav::edge_tree::get();
        if let Some(t) = &trees {
            t.register(key, || shell_raw(&shell, gun_h, range));
        }
        Some(Self { shell, nav, space, gun_h, key, trees })
    }

    /// The EdgeTrees answer for a shot from `p` onto target cell `cq` (centre `q`); None while it is being built.
    pub(crate) fn tree(&self, p: Vector2, q: Vector2, cq: usize) -> Option<bool> {
        let t = self.trees.as_ref()?;
        let hit = t.answer(self.key, cq as i32, q, p)?;
        if *CHECK && t.stats[crate::nav::edge_tree::ST_ANSWERED].load(Relaxed) % 16 == 0 {
            let sim = self.hits(p, q, cq);
            if t.in_range(self.key, cq as i32, p) {
                CHECKS[(hit as usize) << 1 | sim as usize].fetch_add(1, Relaxed);
            } else {
                CHECKS[4 + sim as usize].fetch_add(1, Relaxed);
            }
        }
        Some(hit)
    }

    /// Whether our shell from `p` clears the terrain onto `q` (target cell `cq`), kept per p's quarter cell and cq.
    pub(crate) fn hits(&self, p: Vector2, q: Vector2, cq: usize) -> bool {
        let k = (self.key, (p.x / QUARTER_M).floor() as i32, (p.y / QUARTER_M).floor() as i32, cq as i32);
        if let Some(hit) = CACHE.with(|c| c.borrow().get(&k).copied()) {
            SIM_HITS.fetch_add(1, Relaxed);
            return hit;
        }
        let t0 = std::time::Instant::now();
        let from = Vector3::new(p.x, self.gun_h, p.y);
        let sol = P::calculate_launch_vector_impl(from, Vector3::new(q.x, 0.0, q.y), &self.shell);
        let hit = match (sol.get(0).and_then(|v| v.try_to::<Vector3>().ok()), sol.get(1).and_then(|v| v.try_to::<f64>().ok())) {
            (Some(launch), Some(t)) => {
                let r = P::sim_can_shoot_over_terrain_impl(from, launch, t, &self.shell, Some(self.nav.clone()),
                    Some(self.space.clone()), VarArray::new(), None);
                !r.get("terrain_blocked").is_some_and(|v| v.to::<bool>())
            }
            _ => false,
        };
        SIMS.fetch_add(1, Relaxed);
        SIM_NS.fetch_add(t0.elapsed().as_nanos() as u64, Relaxed);
        CACHE.with(|c| {
            let mut c = c.borrow_mut();
            if c.len() >= CACHE_MAX {
                c.clear();
            }
            c.insert(k, hit);
        });
        hit
    }
}
