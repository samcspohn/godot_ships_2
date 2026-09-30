use godot::builtin::{AnyArray, AnyDictionary, EulerOrder};
use godot::classes::{Node3D, Object, RigidBody3D, StreamPeerBuffer};
use godot::prelude::*;

use crate::names::names;
use crate::variant_cast::VariantCast;

names!(
    initialized, visible_to_enemy, client_positioned, det_los, det_hydro, det_radar, det_air,
    health_controller, _max_hp, _current_hp, healable_damage, consumable_manager,
    artillery_controller, secondary_controller, torpedo_controller, aviation_controller,
    movement_controller, fire_manager, flood_manager, concealment, skills, stats, guns,
    sub_controllers, launchers, active, from_bytes, throttle_level, rudder_input, fparams,
    rparams, dot_params, fires, floods, curr_buildup, lifetime, _hide;
);

thread_local! {
    static NAMES: Names = Names::new();
}

fn obj(v: Variant) -> Option<Gd<Object>> {
    v.try_to::<Gd<Object>>().ok().filter(|o| o.is_instance_valid())
}

fn sub(o: &Gd<Object>, f: &StringName) -> Option<Gd<Object>> {
    obj(o.get(f))
}

fn from_bytes(o: &Gd<Object>, n: &Names, args: &[Variant]) {
    o.clone().call(&n.from_bytes, args);
}

fn sub_from_bytes(o: &Gd<Object>, f: &StringName, n: &Names, bytes: Variant) {
    if let Some(s) = sub(o, f) {
        from_bytes(&s, n, &[bytes]);
    }
}

fn element(arr: &AnyArray, i: usize) -> Option<Gd<Object>> {
    if i < arr.len() { arr.get(i).and_then(obj) } else { None }
}

struct Reader(Gd<StreamPeerBuffer>);

impl Reader {
    fn new(b: &PackedByteArray) -> Self {
        let mut r = StreamPeerBuffer::new_gd();
        r.set_data_array(b);
        Self(r)
    }
    fn var(&mut self) -> Variant {
        self.0.get_var()
    }
    fn f32(&mut self) -> f32 {
        self.0.get_float()
    }
    fn i32(&mut self) -> i32 {
        self.0.get_32()
    }
    fn u8(&mut self) -> u8 {
        self.0.get_u8()
    }
    fn vec3(&mut self) -> Vector3 {
        self.var().try_to().unwrap_or_default()
    }
}

// HPManager.from_bytes inlined: two LE floats, no script call per snapshot.
fn read_hp(ship: &Gd<Object>, n: &Names, bytes: Variant) {
    let Some(mut hc) = sub(ship, &n.health_controller) else { return };
    let b = bytes.try_to::<PackedByteArray>().unwrap_or_default();
    let s = b.as_slice();
    if s.len() < 8 {
        return;
    }
    let max = f32::from_le_bytes([s[0], s[1], s[2], s[3]]);
    let cur = f32::from_le_bytes([s[4], s[5], s[6], s[7]]);
    hc.set(&n._max_hp, &(max as f64).to_variant());
    hc.set(&n._current_hp, &(cur as f64).to_variant());
}

fn set_det_flags(ship: &mut Gd<Object>, n: &Names, f: u8) {
    ship.set(&n.det_los, &(f & 1 != 0).to_variant());
    ship.set(&n.det_hydro, &(f & 2 != 0).to_variant());
    ship.set(&n.det_radar, &(f & 4 != 0).to_variant());
    ship.set(&n.det_air, &(f & 8 != 0).to_variant());
}

fn finish(ship: &mut Gd<RigidBody3D>, n: &Names, visible_to_enemy: bool) {
    let mut o: Gd<Object> = ship.clone().upcast();
    o.set(&n.visible_to_enemy, &visible_to_enemy.to_variant());
    ship.set_visible(true);
    o.set(&n.client_positioned, &true.to_variant());
}

// One global-transform write instead of basis then position: each write walks the ship subtree.
fn apply_body(ship: &mut Gd<RigidBody3D>, r: &mut Reader) {
    let lv = r.vec3();
    let euler = r.vec3();
    let pos = r.vec3();
    ship.set_linear_velocity(lv);
    ship.set_global_transform(Transform3D::new(Basis::from_euler(EulerOrder::YXZ, euler), pos));
}

fn guns_from_bytes(r: &mut Reader, n: &Names, guns: &AnyArray, count: i32, full: bool) {
    for i in 0..count.max(0) as usize {
        let bytes = r.var();
        if let Some(g) = element(guns, i) {
            from_bytes(&g, n, &[bytes, full.to_variant()]);
        }
    }
}

fn dots_from_bytes(r: &mut Reader, n: &Names, mgr: &Gd<Object>, dot: &StringName, list: &StringName) {
    let count = r.i32();
    let a = r.var();
    let b = r.var();
    sub_from_bytes(mgr, dot, n, a);
    sub_from_bytes(mgr, &n.rparams, n, b);
    let items = mgr.get(list).to_any_array();
    for i in 0..count.max(0) as usize {
        let bu = r.f32() as f64;
        let lt = r.f32() as f64;
        if let Some(mut it) = element(&items, i) {
            it.set(&n.curr_buildup, &bu.to_variant());
            it.set(&n.lifetime, &lt.to_variant());
        }
    }
}

fn parse_ship_transform_impl(ship: &mut Gd<RigidBody3D>, n: &Names, b: &PackedByteArray) {
    let o: Gd<Object> = ship.clone().upcast();
    let mut r = Reader::new(b);
    let rot_y = r.f32();
    let x = r.f32();
    let z = r.f32();

    let mut rot = ship.get_rotation();
    rot.y = rot_y;
    let local_basis = Basis::from_euler(ship.get_rotation_order(), rot) * Basis::from_scale(ship.get_scale());
    let parent = ship.get_parent_node_3d().map_or(Transform3D::IDENTITY, |p: Gd<Node3D>| p.get_global_transform());
    let mut xf = parent * Transform3D::new(local_basis, ship.get_position());
    xf.origin.x = x;
    xf.origin.z = z;
    ship.set_global_transform(xf);

    read_hp(&o, n, r.var());
    if let Some(av) = sub(&o, &n.aviation_controller) {
        from_bytes(&av, n, &[r.var()]);
    }
    let vte = r.u8() == 1;
    finish(ship, n, vte);
}

fn sync2_impl(ship: &mut Gd<RigidBody3D>, n: &Names, b: &PackedByteArray, friendly: bool) {
    let mut o: Gd<Object> = ship.clone().upcast();
    if !o.get(&n.initialized).to_bool() {
        return;
    }
    let mut r = Reader::new(b);
    apply_body(ship, &mut r);
    read_hp(&o, n, r.var());
    if friendly {
        let bytes = r.var();
        sub_from_bytes(&o, &n.consumable_manager, n, bytes);
    }

    let art = sub(&o, &n.artillery_controller);
    let guns = art.as_ref().map_or_else(|| VarArray::new().upcast_any_array(), |a| a.get(&n.guns).to_any_array());
    let count = r.i32();
    guns_from_bytes(&mut r, n, &guns, count, false);

    let active = r.u8();
    let sc = sub(&o, &n.secondary_controller);
    if let Some(mut sc) = sc.clone() {
        sc.set(&n.active, &(active == 1).to_variant());
    }
    if active != 0 {
        let subs = sc.as_ref().map_or_else(|| VarArray::new().upcast_any_array(), |s| s.get(&n.sub_controllers).to_any_array());
        let sc_count = r.i32();
        for i in 0..sc_count.max(0) as usize {
            let gun_count = r.i32();
            let guns = element(&subs, i).map_or_else(|| VarArray::new().upcast_any_array(), |c| c.get(&n.guns).to_any_array());
            guns_from_bytes(&mut r, n, &guns, gun_count, false);
        }
    }

    if let Some(tc) = sub(&o, &n.torpedo_controller) {
        let launchers = tc.get(&n.launchers).to_any_array();
        let count = r.i32();
        guns_from_bytes(&mut r, n, &launchers, count, false);
    }
    if let Some(av) = sub(&o, &n.aviation_controller) {
        from_bytes(&av, n, &[r.var()]);
    }

    let _p_id = r.i32();
    let vte = r.u8() == 1;
    finish(ship, n, vte);
    if friendly {
        let f = r.u8();
        set_det_flags(&mut o, n, f);
    }
}

fn sync_player_impl(ship: &mut Gd<RigidBody3D>, n: &Names, b: &PackedByteArray) {
    let mut o: Gd<Object> = ship.clone().upcast();
    if !o.get(&n.initialized).to_bool() {
        return;
    }
    let mut r = Reader::new(b);
    let throttle = r.i32();
    let rudder = r.f32() as f64;
    if let Some(mut mc) = sub(&o, &n.movement_controller) {
        mc.set(&n.throttle_level, &(throttle as i64).to_variant());
        mc.set(&n.rudder_input, &rudder.to_variant());
    }
    apply_body(ship, &mut r);
    read_hp(&o, n, r.var());
    let healable = r.f32() as f64;
    if let Some(mut hc) = sub(&o, &n.health_controller) {
        hc.set(&n.healable_damage, &healable.to_variant());
    }

    let bytes = r.var();
    sub_from_bytes(&o, &n.consumable_manager, n, bytes);

    if let Some(fm) = sub(&o, &n.fire_manager) {
        dots_from_bytes(&mut r, n, &fm, &n.fparams, &n.fires);
    }
    if let Some(fm) = sub(&o, &n.flood_manager) {
        dots_from_bytes(&mut r, n, &fm, &n.dot_params, &n.floods);
    }

    let art = sub(&o, &n.artillery_controller);
    let bytes = r.var();
    if let Some(a) = &art {
        from_bytes(a, n, &[bytes]);
    }
    let guns = art.as_ref().map_or_else(|| VarArray::new().upcast_any_array(), |a| a.get(&n.guns).to_any_array());
    let count = r.i32();
    guns_from_bytes(&mut r, n, &guns, count, true);

    let subs = sub(&o, &n.secondary_controller)
        .map_or_else(|| VarArray::new().upcast_any_array(), |s| s.get(&n.sub_controllers).to_any_array());
    let sc_count = r.i32();
    for i in 0..sc_count.max(0) as usize {
        let sc_bytes = r.var();
        let c = element(&subs, i);
        if let Some(c) = &c {
            from_bytes(c, n, &[sc_bytes]);
        }
        let gun_count = r.i32();
        let guns = c.map_or_else(|| VarArray::new().upcast_any_array(), |c| c.get(&n.guns).to_any_array());
        guns_from_bytes(&mut r, n, &guns, gun_count, true);
    }

    if let Some(tc) = sub(&o, &n.torpedo_controller) {
        from_bytes(&tc, n, &[r.var()]);
        let launchers = tc.get(&n.launchers).to_any_array();
        let count = r.i32();
        guns_from_bytes(&mut r, n, &launchers, count, true);
    }
    if let Some(av) = sub(&o, &n.aviation_controller) {
        from_bytes(&av, n, &[r.var()]);
    }

    let bytes = r.var();
    sub_from_bytes(&o, &n.concealment, n, bytes);
    let bytes = r.var();
    sub_from_bytes(&o, &n.skills, n, bytes);

    let _p_id = r.i32();
    let bytes = r.var();
    sub_from_bytes(&o, &n.stats, n, bytes);
    let vte = r.u8() == 1;
    let f = r.u8();
    set_det_flags(&mut o, n, f);
    finish(ship, n, vte);
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct ShipSync {
    base: Base<RefCounted>,
}

#[godot_api]
impl ShipSync {
    #[func]
    fn parse_ship_transform(mut ship: Gd<RigidBody3D>, b: PackedByteArray) {
        NAMES.with(|n| parse_ship_transform_impl(&mut ship, n, &b));
    }

    #[func]
    fn sync2(mut ship: Gd<RigidBody3D>, b: PackedByteArray, friendly: bool) {
        NAMES.with(|n| sync2_impl(&mut ship, n, &b, friendly));
    }

    #[func]
    fn sync_player(mut ship: Gd<RigidBody3D>, b: PackedByteArray) {
        NAMES.with(|n| sync_player_impl(&mut ship, n, &b));
    }

    #[func]
    fn defer_sync_ship(players: Variant, friendly: i32, player_name: GString, ship_data: Variant) {
        let Ok(players) = players.try_to::<AnyDictionary>() else { return };
        let Some(entry) = players.get(&player_name.to_variant()) else { return };
        let Some(mut ship) = entry.to_any_array().get(0)
            .and_then(obj)
            .and_then(|o| o.try_cast::<RigidBody3D>().ok())
        else {
            return;
        };
        NAMES.with(|n| {
            if ship_data.is_nil() {
                ship.call(&n._hide, &[]);
                return;
            }
            let o: Gd<Object> = ship.clone().upcast();
            match friendly {
                2 => parse_ship_transform_impl(&mut ship, n, &ship_data.try_to().unwrap_or_default()),
                3 => sub_from_bytes(&o, &n.aviation_controller, n, ship_data),
                _ => sync2_impl(&mut ship, n, &ship_data.try_to().unwrap_or_default(), friendly == 1),
            }
        });
    }
}
