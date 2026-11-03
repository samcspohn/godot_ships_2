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
}

impl EdgeSim {
    pub(crate) fn from_opts(o: &VarDictionary) -> Option<Self> {
        let shell = o.get("sim_shell")?.try_to::<Gd<Resource>>().ok()?;
        let nav = o.get("sim_nav")?.try_to::<Gd<NavigationMap>>().ok()?;
        let space = o.get("sim_space")?.try_to::<Gd<PhysicsDirectSpaceState3D>>().ok()?;
        let gun_h = o.get("sim_gun_h").map_or(5.0, |v| v.to::<f32>());
        let key = shell.instance_id().to_i64() ^ ((gun_h * 10.0) as i64) << 48;
        Some(Self { shell, nav, space, gun_h, key })
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
