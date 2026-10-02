use godot::builtin::AnyArray;
use godot::classes::{Node3D, Object, PhysicsDirectSpaceState3D, PhysicsRayQueryParameters3D};
use godot::prelude::*;

use crate::names::names;
use crate::variant_cast::VariantCast;

names!(
    team, team_id, visible_to_enemy, det_los, det_hydro, det_radar, det_air, concealment, params, p,
    bloom_radius, assured_acquisition_range, spotting_range_override, radar_spotting_range_override,
    air_radius, aviation_controller, active_squadrons, squadrons, aircraft, spotting_range,
    _pending_spotter, _pending_source, _pending_dist, collider, collision_layer;
);

thread_local! {
    // Dropping StringNames after engine shutdown panics.
    static NAMES: std::mem::ManuallyDrop<Names> = std::mem::ManuallyDrop::new(Names::new());
}

const SMOKE_LAYER: i64 = 1 << 5;

#[derive(Clone, Copy, PartialEq)]
#[repr(i32)]
enum Source {
    Air = 1,
    Hydro = 2,
    Radar = 3,
    Los = 4,
}

fn rank(s: Source) -> u8 {
    match s {
        Source::Los => 2,
        _ => 1,
    }
}

/// LKP refresh the server has to run, in detection order.
#[derive(Clone, Copy)]
#[repr(i32)]
enum Lkp {
    Hydro = 0,
    Radar = 1,
    Air = 2,
}

struct Ship {
    obj: Gd<Node3D>,
    pos: Vector3,
    team: i64,
    conceal: f32,
    assured: f32,
    hydro: f32,
    radar: f32,
    air_radius: f32,
    planes: Vec<(Vector3, f32)>,
    vis: bool,
    flags: [bool; 4],
    pending: Option<(usize, Source, f32)>,
}

impl Ship {
    fn read(obj: Gd<Node3D>, n: &Names) -> Option<Self> {
        let o = obj.clone().upcast::<Object>();
        let team = o.get(&n.team).try_to::<Gd<Object>>().ok()?.get(&n.team_id).to_i64();
        let conc = o.get(&n.concealment).try_to::<Gd<Object>>().ok()?;
        let cp = conc.get(&n.params).try_to::<Gd<Object>>().ok()?.call(&n.p, &[]).try_to::<Gd<Object>>().ok()?;
        let mut planes = Vec::new();
        if let Ok(av) = o.get(&n.aviation_controller).try_to::<Gd<Object>>() {
            let squadrons = av.get(&n.squadrons).to_any_array();
            let keys: Vec<Variant> = av.get(&n.active_squadrons).try_to::<AnyDictionary>()
                .map_or_else(|_| Vec::new(), |d| d.keys_array().iter_shared().collect());
            for k in keys {
                let Some(sq) = squadrons.get(k.to_i64() as usize).and_then(|v| v.try_to::<Gd<Object>>().ok()) else { continue };
                for a in sq.get(&n.aircraft).to_any_array().iter_shared() {
                    let Ok(plane) = a.try_to::<Gd<Node3D>>() else { continue };
                    let range = plane.get(&n.params).try_to::<Gd<Object>>().ok()
                        .and_then(|mut p| p.call(&n.p, &[]).try_to::<Gd<Object>>().ok())
                        .map_or(0.0, |p| p.get(&n.spotting_range).to_f32());
                    planes.push((plane.get_global_position(), range));
                }
            }
        }
        Some(Self {
            pos: obj.get_global_position(),
            team,
            conceal: conc.get(&n.bloom_radius).to_f32(),
            assured: cp.get(&n.assured_acquisition_range).to_f32(),
            hydro: cp.get(&n.spotting_range_override).to_f32(),
            radar: cp.get(&n.radar_spotting_range_override).to_f32(),
            air_radius: cp.get(&n.air_radius).to_f32(),
            planes,
            vis: o.get(&n.visible_to_enemy).to_bool(),
            flags: [false; 4],
            pending: None,
            obj,
        })
    }
}

const LOS: usize = 0;
const HYDRO: usize = 1;
const RADAR: usize = 2;
const AIR: usize = 3;

struct Pass {
    ships: Vec<Ship>,
    space: Gd<PhysicsDirectSpaceState3D>,
    ray: Gd<PhysicsRayQueryParameters3D>,
    events: VarArray,
}

impl Pass {
    fn propose(&mut self, t: usize, s: usize, src: Source, dist: f32) {
        let p = &mut self.ships[t].pending;
        let (pr, pd) = p.map_or((0, f32::INFINITY), |(_, ps, pd)| (rank(ps), pd));
        if rank(src) < pr || (rank(src) == pr && dist >= pd) {
            return;
        }
        *p = Some((s, src, dist));
    }

    fn spot(&mut self, s: usize, t: usize, dist: f32) {
        let reach = self.ships[t].conceal.max(self.ships[s].hydro.max(self.ships[s].radar));
        if reach > dist {
            self.ships[t].vis = true;
            self.ships[t].flags[LOS] = true;
            self.propose(t, s, Source::Los, dist);
        }
    }

    fn lkp(&mut self, kind: Lkp, team: i64, ship: usize) {
        self.events.push(&(kind as i32).to_variant());
        self.events.push(&team.to_variant());
        self.events.push(&self.ships[ship].obj.to_variant());
    }

    fn sensor(&mut self, d: usize, t: usize, dist: f32, hydro: bool, smoke: bool) {
        let range = if hydro { self.ships[d].hydro } else { self.ships[d].radar };
        if range <= 0.0 || dist >= range {
            return;
        }
        let (flag, src, kind) = if hydro { (HYDRO, Source::Hydro, Lkp::Hydro) } else { (RADAR, Source::Radar, Lkp::Radar) };
        self.ships[d].flags[flag] = true;
        if smoke {
            self.spot(d, t, dist);
            return;
        }
        self.ships[t].flags[flag] = true;
        self.propose(t, d, src, dist);
        self.propose(d, t, src, dist);
        if !self.ships[t].vis {
            self.lkp(kind, self.ships[d].team, t);
        }
        if !self.ships[d].vis {
            self.lkp(kind, self.ships[t].team, d);
        }
    }

    /// (clear, smoke_blocked)
    fn cast(&mut self, from: Vector3, to: Vector3, n: &Names) -> (bool, bool) {
        self.ray.set_from(from);
        self.ray.set_to(to);
        let hit = self.space.intersect_ray(&self.ray);
        if hit.is_empty() {
            return (true, false);
        }
        let smoke = hit.get(&n.collider).and_then(|c| c.try_to::<Gd<Object>>().ok())
            .is_some_and(|c| c.get(&n.collision_layer).to_i64() & SMOKE_LAYER != 0);
        (false, smoke)
    }

    fn air(&mut self, a: usize, b: usize, n: &Names) {
        for k in 0..self.ships[a].planes.len() {
            let (from, range) = self.ships[a].planes[k];
            let mut to = self.ships[b].pos;
            to.y = 1.0;
            let dist = from.distance_to(to);
            if self.ships[b].air_radius.min(range) <= dist || !self.cast(from, to, n).0 {
                continue;
            }
            self.ships[b].flags[AIR] = true;
            self.propose(b, a, Source::Air, dist);
            if !self.ships[b].vis {
                self.lkp(Lkp::Air, self.ships[a].team, b);
            }
        }
    }

    fn pair(&mut self, a: usize, b: usize, n: &Names) {
        let (sa, sb) = (&self.ships[a], &self.ships[b]);
        let dist = sa.pos.distance_to(sb.pos);
        let assured = sa.assured.max(sb.assured);
        if assured > 0.0 && dist < assured {
            self.spot(a, b, dist);
            self.spot(b, a, dist);
        }
        let (sa, sb) = (&self.ships[a], &self.ships[b]);
        if sa.vis && sb.vis {
            return;
        }
        // The ray only matters if a spot or a sensor reaches this far.
        let needs_ray = sb.conceal.max(sa.hydro.max(sa.radar)) > dist
            || sa.conceal.max(sb.hydro.max(sb.radar)) > dist
            || sa.hydro.max(sa.radar).max(sb.hydro).max(sb.radar) > dist;
        if needs_ray {
            let (mut from, mut to) = (sa.pos, sb.pos);
            from.y = 1.0;
            to.y = 1.0;
            let (los, smoke) = self.cast(from, to, n);
            if los {
                self.spot(a, b, dist);
                self.spot(b, a, dist);
            }
            self.sensor(a, b, dist, true, smoke);
            self.sensor(b, a, dist, true, smoke);
            self.sensor(a, b, dist, false, smoke);
            self.sensor(b, a, dist, false, smoke);
        }
        self.air(a, b, n);
        self.air(b, a, n);
    }

    fn write_back(&mut self, n: &Names) {
        for i in 0..self.ships.len() {
            let s = &self.ships[i];
            let mut o = s.obj.clone().upcast::<Object>();
            if s.vis {
                o.set(&n.visible_to_enemy, &true.to_variant());
            }
            for (f, name) in [(LOS, &n.det_los), (HYDRO, &n.det_hydro), (RADAR, &n.det_radar), (AIR, &n.det_air)] {
                if s.flags[f] {
                    o.set(name, &true.to_variant());
                }
            }
            let Some((spotter, src, dist)) = s.pending else { continue };
            let Ok(mut conc) = o.get(&n.concealment).try_to::<Gd<Object>>() else { continue };
            conc.set(&n._pending_spotter, &self.ships[spotter].obj.to_variant());
            conc.set(&n._pending_source, &(src as i32).to_variant());
            conc.set(&n._pending_dist, &(dist as f64).to_variant());
        }
    }
}

/// Server ship-vs-ship detection for one frame.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SpotPass {
    base: Base<RefCounted>,
}

#[godot_api]
impl SpotPass {
    /// Sets visible_to_enemy, det_* and the concealment's pending spotter on `ships`;
    /// returns flat [kind, team_id, ship] LKP refreshes (kind 0 hydro, 1 radar, 2 air).
    #[func]
    fn run(ships: AnyArray, space: Gd<PhysicsDirectSpaceState3D>, mask: u32) -> VarArray {
        NAMES.with(|n| {
            let ships: Vec<Ship> = ships.iter_shared()
                .filter_map(|v| v.try_to::<Gd<Node3D>>().ok())
                .filter_map(|o| Ship::read(o, n))
                .collect();
            let mut ray = PhysicsRayQueryParameters3D::new_gd();
            ray.set_collide_with_areas(true);
            ray.set_collide_with_bodies(true);
            ray.set_hit_from_inside(false);
            ray.set_collision_mask(mask);
            let mut pass = Pass { ships, space, ray, events: VarArray::new() };
            let count = pass.ships.len();
            for a in 0..count {
                for b in a + 1..count {
                    if pass.ships[a].team != pass.ships[b].team {
                        pass.pair(a, b, n);
                    }
                }
            }
            pass.write_back(n);
            pass.events
        })
    }
}
