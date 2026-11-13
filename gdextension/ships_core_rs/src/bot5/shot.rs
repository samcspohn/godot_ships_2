use godot::prelude::*;
use std::collections::HashMap;
use std::sync::Arc;

use crate::nav::map::NavigationMap;
use crate::nav::reach::{new_table, segment_clear, RBlockTable, Terrain};

/// Muzzle heights share a table per band, floored: a lower gun only blocks more.
const GUN_H_BAND_M: f32 = 2.0;

#[derive(Clone, Copy, Debug, Default)]
pub struct GunSpec {
    pub speed: f32,
    pub drag: f32,
    pub range: f32,
    pub gun_h: f32,
}

impl GunSpec {
    fn key(&self) -> (i32, i32, i32, i32) {
        ((self.speed * 10.0) as i32, (self.drag * 1e8) as i32, (self.range / 10.0) as i32, self.gun_h as i32)
    }
}

#[derive(Clone)]
pub struct Gun {
    table: Arc<RBlockTable>,
    gun_h: f32,
}

/// Terrain-only shell clearance between two water points, for station search.
#[derive(Default)]
pub struct ShotMap {
    terrain: Option<Arc<Terrain>>,
    tables: HashMap<(i32, i32, i32, i32), Arc<RBlockTable>>,
}

impl ShotMap {
    pub fn ready(&mut self, map: &Option<Gd<NavigationMap>>) -> bool {
        if self.terrain.is_none() {
            if let Some(m) = map {
                let m = m.bind();
                if m.built {
                    self.terrain = Some(Arc::new(Terrain::from_map(&m)));
                }
            }
        }
        self.terrain.is_some()
    }

    pub fn gun(&mut self, g: GunSpec) -> Option<Gun> {
        if g.speed <= 0.0 || g.drag <= 0.0 || g.range <= 0.0 {
            return None;
        }
        let g = GunSpec { gun_h: ((g.gun_h / GUN_H_BAND_M).floor() * GUN_H_BAND_M).max(1.0), ..g };
        let table = self.tables.entry(g.key()).or_insert_with(|| new_table(g.speed, g.drag, g.gun_h, 0.0, g.range)).clone();
        Some(Gun { table, gun_h: g.gun_h })
    }

    /// Whether a shell from `from` can land on `to`; false out of range or off the map.
    pub fn clear(&self, gun: &Gun, from: Vector2, to: Vector2) -> bool {
        let Some(t) = &self.terrain else { return false };
        let d = to - from;
        let dist = d.length();
        if dist < 1.0 {
            return true;
        }
        segment_clear(t, &gun.table, from, d.x / dist, d.y / dist, dist, gun.gun_h)
    }
}
