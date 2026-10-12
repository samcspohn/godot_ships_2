use godot::prelude::*;
use std::sync::{Arc, RwLock};

/// One ship as every navigator sees it this frame.
#[derive(Clone, Copy, Debug)]
pub(crate) struct ShipSnap {
    pub id: i64,
    pub team: i32,
    pub pos: Vector2,
    pub heading: f32,
    /// Along the bow, negative astern.
    pub speed: f32,
    pub yaw_rate: f32,
    pub half_len: f32,
    pub half_beam: f32,
    /// Spotted by the other team.
    pub seen: bool,
}

impl ShipSnap {
    /// Pose `t` seconds on, holding its speed and rate of turn.
    pub fn pose_at(&self, t: f32) -> (Vector2, f32) {
        let h0 = self.heading;
        if self.yaw_rate.abs() < 1e-4 {
            return (self.pos + Vector2::new(h0.sin(), h0.cos()) * (self.speed * t), h0);
        }
        let h1 = h0 + self.yaw_rate * t;
        let r = self.speed / self.yaw_rate;
        (Vector2::new(self.pos.x + r * (h0.cos() - h1.cos()), self.pos.y + r * (h1.sin() - h0.sin())), h1)
    }
}

pub(crate) type ShipList = Arc<RwLock<Vec<ShipSnap>>>;

/// Every live ship in the match, refreshed once a frame by the server and read
/// by each navigator, which keeps those near and visible to it.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct ShipRegistry {
    base: Base<RefCounted>,
    pub(crate) ships: ShipList,
}

#[godot_api]
impl ShipRegistry {
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn update(&mut self, ids: PackedInt64Array, teams: PackedInt32Array, pos: PackedVector2Array,
            heading: PackedFloat32Array, speed: PackedFloat32Array, yaw_rate: PackedFloat32Array,
            length: PackedFloat32Array, beam: PackedFloat32Array, seen: PackedByteArray) {
        let n = ids.len();
        let (teams, pos, heading, speed, yaw_rate, length, beam, seen) = (teams.as_slice(), pos.as_slice(),
            heading.as_slice(), speed.as_slice(), yaw_rate.as_slice(), length.as_slice(), beam.as_slice(), seen.as_slice());
        let list = ids.as_slice().iter().enumerate().filter(|&(i, _)| i < n.min(teams.len()).min(pos.len()))
            .map(|(i, &id)| ShipSnap {
                id,
                team: teams[i],
                pos: pos[i],
                heading: heading.get(i).copied().unwrap_or(0.0),
                speed: speed.get(i).copied().unwrap_or(0.0),
                yaw_rate: yaw_rate.get(i).copied().unwrap_or(0.0),
                half_len: length.get(i).copied().unwrap_or(200.0) * 0.5,
                half_beam: beam.get(i).copied().unwrap_or(20.0) * 0.5,
                seen: seen.get(i).is_some_and(|&b| b != 0),
            })
            .collect();
        *self.ships.write().unwrap() = list;
    }
}
