use godot::prelude::*;
use godot::classes::{Engine, Node3D};

use super::ProjectileManager;
use crate::projectile::armor::mesh::V3;

impl ProjectileManager {
    pub(crate) fn armor_register_ship_impl(&mut self, ship: Gd<Node3D>) {
        self.armor.register(ship);
    }

    pub(crate) fn armor_unregister_ship_impl(&mut self, ship_id: i64) {
        self.armor.unregister(ship_id);
    }

    pub(crate) fn armor_add_part_impl(
        &mut self, ship: Gd<Node3D>, part: Gd<Node3D>, local_xform: Transform3D,
        faces: PackedVector3Array, thickness: PackedFloat32Array, armor_type: i32, dynamic: bool,
    ) -> i32 {
        let id = ship.instance_id().to_i64();
        self.armor.add_part(id, part, local_xform, &faces, &thickness, armor_type, dynamic)
    }

    pub(crate) fn armor_part_count_impl(&self, ship: Gd<Node3D>) -> i32 {
        self.armor.get(ship.instance_id().to_i64()).map(|s| s.parts.len() as i32).unwrap_or(0)
    }

    pub(crate) fn armor_sync(&mut self, ship_id: i64) {
        let frame = Engine::singleton().get_physics_frames() as i64;
        self.armor.sync(ship_id, frame);
    }

    /// Closest armour hit along a ship-local segment, as PrecisionPhysicsWorld
    /// reported it: armor, position, normal, face_index.
    pub(crate) fn armor_raycast_impl(&mut self, ship: Gd<Node3D>, from_local: Vector3, to_local: Vector3) -> VarDictionary {
        let id = ship.instance_id().to_i64();
        self.armor_sync(id);
        let mut out = VarDictionary::new();
        let Some(sa) = self.armor.get(id) else { return out };
        let Some(hit) = sa.mesh.raycast(V3::from_godot(from_local), V3::from_godot(to_local)) else { return out };
        out.set("armor", &sa.parts[hit.part]);
        out.set("position", hit.pos.to_godot());
        out.set("normal", hit.normal.to_godot());
        out.set("face_index", hit.face as i64);
        out.set("part", hit.part as i64);
        out
    }

    pub(crate) fn armor_part_at_impl(&mut self, ship: Gd<Node3D>, local_pos: Vector3) -> Option<Gd<Object>> {
        let id = ship.instance_id().to_i64();
        self.armor_sync(id);
        let sa = self.armor.get(id)?;
        let idx = sa.mesh.part_at(V3::from_godot(local_pos))?;
        Some(sa.parts[idx].clone())
    }
}
