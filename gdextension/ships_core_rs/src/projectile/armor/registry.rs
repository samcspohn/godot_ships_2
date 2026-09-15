use godot::prelude::*;
use godot::classes::Node3D;
use std::collections::BTreeMap;

use super::mesh::{ArmorMesh, PartMesh, Tri, V3};

/// One registered ship: its mesh plus the scene objects the walk reports
/// hits against. Turret parts re-read their placement once per frame.
pub struct ShipArmor {
    pub ship: Gd<Node3D>,
    pub mesh: ArmorMesh,
    pub parts: Vec<Gd<Object>>,
    pub dynamic_nodes: Vec<(usize, Gd<Node3D>)>,
    pub sync_frame: i64,
}

#[derive(Default)]
pub struct ArmorRegistry {
    pub ships: BTreeMap<i64, ShipArmor>,
}

impl ArmorRegistry {
    pub fn register(&mut self, ship: Gd<Node3D>) {
        let id = ship.instance_id().to_i64();
        self.ships.entry(id).or_insert_with(|| ShipArmor {
            ship,
            mesh: ArmorMesh::default(),
            parts: Vec::new(),
            dynamic_nodes: Vec::new(),
            sync_frame: -1,
        });
    }

    pub fn unregister(&mut self, id: i64) {
        self.ships.remove(&id);
    }

    pub fn get(&self, id: i64) -> Option<&ShipArmor> {
        self.ships.get(&id)
    }

    pub fn add_part(
        &mut self,
        id: i64,
        part: Gd<Node3D>,
        xform: Transform3D,
        faces: &PackedVector3Array,
        thickness: &PackedFloat32Array,
        armor_type: i32,
        dynamic: bool,
    ) -> i32 {
        let Some(sa) = self.ships.get_mut(&id) else { return -1 };
        let n = faces.len() / 3;
        let mut tris = Vec::with_capacity(n);
        for i in 0..n {
            tris.push(Tri {
                v0: V3::from_godot(faces[i * 3]),
                v1: V3::from_godot(faces[i * 3 + 1]),
                v2: V3::from_godot(faces[i * 3 + 2]),
                thickness: if i < thickness.len() { thickness[i] } else { 0.0 },
            });
        }
        sa.mesh.parts.push(PartMesh::new(tris, armor_type, dynamic, xform));
        let idx = sa.mesh.parts.len() - 1;
        sa.parts.push(part.clone().upcast::<Object>());
        if dynamic {
            sa.dynamic_nodes.push((idx, part));
        }
        sa.sync_frame = -1;
        idx as i32
    }

    /// Re-read turret placements, once per physics frame.
    pub fn sync(&mut self, id: i64, frame: i64) {
        let Some(sa) = self.ships.get_mut(&id) else { return };
        if sa.sync_frame == frame {
            return;
        }
        sa.sync_frame = frame;
        if sa.dynamic_nodes.is_empty() || !sa.ship.is_instance_valid() {
            return;
        }
        let inv = sa.ship.get_global_transform().affine_inverse();
        for (idx, node) in &sa.dynamic_nodes {
            if node.is_instance_valid() {
                sa.mesh.parts[*idx].set_xform(inv * node.get_global_transform());
            }
        }
    }
}
