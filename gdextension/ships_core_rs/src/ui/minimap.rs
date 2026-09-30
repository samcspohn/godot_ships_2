use std::f32::consts::{PI, TAU};

use godot::builtin::{AnyArray, AnyDictionary};
use godot::classes::{Control, Font, IControl, Node3D, Object, Resource, Script, Texture2D, ThemeDb};
use godot::global::HorizontalAlignment;
use godot::prelude::*;

use crate::ballistics::drag_v2::ProjectilePhysicsWithDragV2;
use crate::names::names;
use crate::panic_guard::guard;
use crate::variant_cast::VariantCast;

const SHIP_MARKER_SIZE: f32 = 35.0;
const CONSUMABLE_ICON_SIZE: f32 = 28.0;
const SHIP_NAME_FONT_SIZE: f32 = 10.0;
const TORPEDO_MARKER_SIZE: f32 = 6.0;
const AIRCRAFT_MARKER_SIZE: f32 = 25.0;
const FOV_ARC_SEGMENTS: usize = 32;
const AVIATION_COLOR_LIGHTEN: f64 = 0.5;
const WAYPOINT_MARKER_RADIUS: f32 = 4.0;
const PATH_LINE_WIDTH: f32 = 2.0;

const PLAYER_COLOR: Color = Color::from_rgba(1.0, 1.0, 1.0, 1.0);
const FRIENDLY_COLOR: Color = Color::from_rgba(0.0, 1.0, 0.0, 1.0);
const ENEMY_COLOR: Color = Color::from_rgba(1.0, 0.0, 0.0, 1.0);
const FOV_ARC_COLOR: Color = Color::from_rgba(0.5, 0.8, 1.0, 0.25);
const HYDRO_RANGE_COLOR: Color = Color::from_rgba(0.4, 0.85, 1.0, 0.85);
const RADAR_RANGE_COLOR: Color = Color::from_rgba(0.0, 0.706, 0.627, 1.0);
const AIR_RANGE_COLOR: Color = Color::from_rgba(1.0, 0.85, 0.2, 0.85);
const HALF_WHITE: Color = Color::from_rgba(1.0, 1.0, 1.0, 0.5);
const GOLD: Color = Color::from_rgba(1.0, 0.843_137_3, 0.0, 1.0);
const DARK_KHAKI: Color = Color::from_rgba(0.741_176_5, 0.717_647_1, 0.419_607_85, 1.0);
const AIR_CIRCLE_COLOR: Color = Color::from_rgba(0.7, 0.9, 1.0, 1.0);
const SQUADRON_WAYPOINT_COLOR: Color = Color::from_rgba(1.0, 1.0, 1.0, 1.0);
const SQUADRON_ATTACK_COLOR: Color = Color::from_rgba(1.0, 0.35, 0.0, 1.0);

names!(
    health_controller, is_alive, is_dead, team, team_id, visible_to_enemy, hydro_detected,
    radar_detected, air_detected, det_los, det_hydro, det_radar, det_air, consumable_manager,
    get_active_icons, equipped_consumables, short_name, ship_name, artillery_controller, guns,
    get_params, _range, torpedo_controller, secondary_controller, sub_controllers,
    aviation_controller, aaa_controller, dps, concealment, get_concealment, params, p, air_radius,
    spotting_range, torpedo_detection_range, active_squadrons, squadrons, aircraft, attack_point,
    circle_range, idle_radius, idle_pos, returning, holding_attack, node, waypoints, follow_ship,
    spectate_free, spectating, target_lock_enabled, locked_target, current_weapon_controller,
    get_shell_params, torpedos, armed, position, owner, script;
    cls_hydro = "HydroacousticSearch", cls_radar = "Radar", cls_spotter = "SpottingAircraft",
    cls_battle_camera = "BattleCamera"
);

struct Tracked {
    ship: Gd<Node3D>,
    init: bool,
    pos: Vector3,
    rot: f32,
}

struct Plane {
    pos: Vector3,
    rot: f32,
    color: Color,
}

struct Orbit {
    center: Vector3,
    radius: f32,
    color: Color,
}

struct SquadronPath {
    base: Vector2,
    waypoints: Vec<Vector2>,
    attack_point: Option<Vector2>,
}

struct ShipEntry {
    pos: Vector3,
    rot: f32,
    color: Color,
    icons: AnyArray,
    name: GString,
    locked: bool,
    dead: bool,
}

#[derive(GodotClass)]
#[class(base = Control)]
pub struct MinimapCanvas {
    #[var]
    map_size: f32,
    #[var]
    max_size: f32,
    #[var]
    world_rect: Rect2,
    #[var]
    aim_point: Vector3,
    #[var]
    draw_circles: bool,
    player: Option<Gd<Node3D>>,
    tracked: Vec<Tracked>,
    planes: Vec<Plane>,
    orbits: Vec<Orbit>,
    paths: Vec<SquadronPath>,
    n: Names,
    base: Base<Control>,
}

#[godot_api]
impl IControl for MinimapCanvas {
    fn init(base: Base<Control>) -> Self {
        Self {
            map_size: 300.0,
            max_size: 1600.0,
            world_rect: Rect2::new(Vector2::new(-17500.0, -17500.0), Vector2::new(35000.0, 35000.0)),
            aim_point: Vector3::ZERO,
            draw_circles: true,
            player: None,
            tracked: Vec::new(),
            planes: Vec::new(),
            orbits: Vec::new(),
            paths: Vec::new(),
            n: Names::new(),
            base,
        }
    }

    fn draw(&mut self) {
        guard("MinimapCanvas::draw", || self.draw_inner());
    }
}

#[godot_api]
impl MinimapCanvas {
    #[func]
    fn set_player_ship(&mut self, ship: Option<Gd<Node3D>>) {
        self.player = ship;
    }

    #[func]
    fn register_ship(&mut self, ship: Gd<Node3D>) {
        if self.tracked.iter().any(|t| t.ship == ship) {
            return;
        }
        let (pos, rot) = (ship.get_global_position(), ship.get_rotation().y);
        self.tracked.push(Tracked { ship, init: false, pos, rot });
    }

    #[func]
    fn clear_ships(&mut self) {
        self.tracked.clear();
        self.player = None;
    }

    #[func]
    fn tick(&mut self) {
        guard("MinimapCanvas::tick", || self.tick_inner());
    }
}

fn obj(v: Variant) -> Option<Gd<Object>> {
    v.try_to::<Gd<Object>>().ok().filter(|o| o.is_instance_valid())
}

fn call0(o: &Gd<Object>, m: &StringName) -> Variant {
    o.clone().call(m, &[])
}

fn sub(o: &Gd<Object>, f: &StringName) -> Option<Gd<Object>> {
    obj(o.get(f))
}

fn team_id(o: &Gd<Object>, n: &Names) -> Option<i64> {
    sub(o, &n.team).map(|t| t.get(&n.team_id).to_i64())
}

fn script_is(o: &Gd<Object>, class: &StringName, n: &Names) -> bool {
    let mut s = o.get(&n.script).try_to::<Gd<Script>>().ok();
    while let Some(sc) = s {
        if sc.get_global_name() == *class {
            return true;
        }
        s = sc.get_base_script();
    }
    false
}

fn params_range(o: &Gd<Object>, n: &Names) -> f32 {
    obj(call0(o, &n.get_params)).map_or(0.0, |p| p.get(&n._range).to_f32())
}

fn active_consumable(ship: &Gd<Object>, class: &StringName, field: &StringName, n: &Names) -> f32 {
    let Some(cm) = sub(ship, &n.consumable_manager) else { return -1.0 };
    for item in cm.get(&n.equipped_consumables).to_any_array().iter_shared() {
        if let Some(item) = obj(item) {
            if script_is(&item, class, n) {
                return item.get(field).to_f32();
            }
        }
    }
    -1.0
}

fn gather_aviation(
    n: &Names, s: &Gd<Node3D>, is_player: bool, friendly: bool,
    planes: &mut Vec<Plane>, orbits: &mut Vec<Orbit>, paths: &mut Vec<SquadronPath>,
) {
    let Some(av) = sub(&s.clone().upcast(), &n.aviation_controller) else { return };
    let color = if is_player {
        PLAYER_COLOR
    } else if friendly {
        FRIENDLY_COLOR.lightened(AVIATION_COLOR_LIGHTEN)
    } else {
        ENEMY_COLOR.lightened(AVIATION_COLOR_LIGHTEN)
    };
    let Ok(active) = av.get(&n.active_squadrons).try_to::<AnyDictionary>() else { return };
    let squadrons = av.get(&n.squadrons).to_any_array();
    let params = av.get(&n.params).to_any_array();

    for key in active.keys_array().iter_shared() {
        let idx = key.to_i64();
        if idx < 0 || idx as usize >= squadrons.len() {
            continue;
        }
        let idx = idx as usize;
        let Some(sq) = squadrons.get(idx).and_then(obj) else { continue };
        let aircraft = sq.get(&n.aircraft).to_any_array();
        let attack_point = sq.get(&n.attack_point).try_to::<Vector2>().ok();

        let mut orbit: Option<(Vector3, f32)> = None;
        if let Some(sp) = params.get(idx).and_then(obj).and_then(|pw| obj(call0(&pw, &n.p))) {
            let holds_station = aircraft.get(0).and_then(obj).is_some_and(|a| script_is(&a, &n.cls_spotter, n));
            if let Some(ap) = attack_point {
                if holds_station {
                    orbit = Some((Vector3::new(ap.x, 0.0, ap.y), sp.get(&n.circle_range).to_f32()));
                }
            } else if !sq.get(&n.returning).to_bool() {
                let idle = sq.get(&n.idle_pos).try_to::<Vector2>().unwrap_or_default();
                let r = if sq.get(&n.holding_attack).to_bool() { &n.circle_range } else { &n.idle_radius };
                orbit = Some((Vector3::new(idle.x, 0.0, idle.y), sp.get(r).to_f32()));
            }
        }

        if is_player {
            let base = sub(&sq, &n.node)
                .and_then(|o| o.try_cast::<Node3D>().ok())
                .map_or(Vector2::ZERO, |nd| {
                    let p = nd.get_global_position();
                    Vector2::new(p.x, p.z)
                });
            let waypoints = sq.get(&n.waypoints).to_any_array().iter_shared()
                .filter_map(|v| v.try_to::<Vector2>().ok())
                .collect();
            paths.push(SquadronPath { base, waypoints, attack_point });
        }

        let mut any_plane_shown = false;
        for v in aircraft.iter_shared() {
            let Some(plane) = obj(v).and_then(|o| o.try_cast::<Node3D>().ok()) else { continue };
            if !plane.is_visible() {
                continue;
            }
            any_plane_shown = true;
            planes.push(Plane { pos: plane.get_global_position(), rot: plane.get_rotation().y, color });
        }
        if let Some((center, radius)) = orbit {
            if any_plane_shown && radius > 0.0 {
                orbits.push(Orbit { center, radius, color });
            }
        }
    }
}

struct Painter {
    c: Gd<Control>,
    mm: f32,
    unit: f32,
    scale: f32,
    wr: Rect2,
    circles: bool,
    font: Option<Gd<Font>>,
}

impl Painter {
    fn to_mm(&self, p: Vector3) -> Vector2 {
        Vector2::new(
            (p.x - self.wr.position.x) / self.wr.size.x * self.mm,
            (p.z - self.wr.position.y) / self.wr.size.y * self.mm,
        )
    }

    fn outside(&self, p: Vector2) -> bool {
        p.x < 0.0 || p.y < 0.0 || p.x > self.mm || p.y > self.mm
    }

    fn marker_size(&self) -> f32 {
        SHIP_MARKER_SIZE * self.unit
    }

    fn range_circle(&mut self, at: Vector3, range: f32, color: Color) {
        if !self.circles {
            return;
        }
        let (c, r) = (self.to_mm(at), range * self.scale);
        self.c.draw_arc_ex(c, r, 0.0, TAU, 64, color).width(2.0).done();
    }

    fn dashed_circle(&mut self, at: Vector3, range: f32, color: Color, dash: f32, gap: f32, width: f32) {
        if !self.circles {
            return;
        }
        let (center, radius) = (self.to_mm(at), range * self.scale);
        let circumference = TAU * radius;
        let num_dashes = (circumference / (dash + gap)) as i32;
        if num_dashes <= 0 {
            return;
        }
        let step = TAU / num_dashes as f32;
        let dash_angle = dash / circumference * TAU;
        let mut pts = PackedVector2Array::new();
        pts.resize(num_dashes as usize * 2);
        let s = pts.as_mut_slice();
        for i in 0..num_dashes as usize {
            let a0 = i as f32 * step;
            let a1 = a0 + dash_angle;
            s[i * 2] = center + Vector2::new(a0.cos(), a0.sin()) * radius;
            s[i * 2 + 1] = center + Vector2::new(a1.cos(), a1.sin()) * radius;
        }
        self.c.draw_multiline_ex(&pts, color).width(width).done();
    }

    fn ship(&mut self, at: Vector3, rot: f32, color: Color, name: &GString) {
        let p = self.to_mm(at);
        if self.outside(p) {
            return;
        }
        let m = self.marker_size();
        let pts: PackedVector2Array = [
            Vector2::new(0.0, -m / 2.0),
            Vector2::new(-m / 3.0, m / 2.0),
            Vector2::new(m / 3.0, m / 2.0),
        ]
        .iter()
        .map(|v| v.rotated(rot) + p)
        .collect();
        self.c.draw_colored_polygon(&pts, color);
        if !name.is_empty() {
            self.ship_name(p, name, color);
        }
    }

    fn ship_name(&mut self, p: Vector2, name: &GString, color: Color) {
        let Some(font) = self.font.clone() else { return };
        let font_size = ((SHIP_NAME_FONT_SIZE * self.unit) as i32).max(8);
        let size = font.get_string_size_ex(name)
            .alignment(HorizontalAlignment::CENTER)
            .width(-1.0)
            .font_size(font_size)
            .done();
        let pos = Vector2::new(p.x - size.x / 2.0, p.y + self.marker_size() / 2.0 + 6.0);
        let mut text_color = color.lerp(Color::WHITE, 0.7);
        text_color.a = 0.9;
        self.c.draw_string_ex(&font, pos, name)
            .alignment(HorizontalAlignment::LEFT)
            .width(-1.0)
            .font_size(font_size)
            .modulate(text_color)
            .done();
    }

    fn tracked_ship(&mut self, e: &ShipEntry) {
        let p = self.to_mm(e.pos);
        if e.locked {
            let m = self.marker_size();
            if self.circles {
                self.c.draw_arc_ex(p, m * 0.9, 0.0, TAU, 32, HALF_WHITE).width(1.0).antialiased(true).done();
            }
            let fwd = Vector2::new(0.0, -1.0).rotated(e.rot);
            self.c.draw_line_ex(p, p + fwd * m * 5.0, HALF_WHITE).width(1.0).done();
        }
        self.ship(e.pos, e.rot, e.color, &e.name);
    }

    fn aura(&mut self, at: Vector3, color: Color) {
        let p = self.to_mm(at);
        if self.outside(p) || !self.circles {
            return;
        }
        let r = self.marker_size() * 1.3 / 2.0;
        self.c.draw_circle(p, r, color);
    }

    fn consumables(&mut self, at: Vector3, icons: &AnyArray) {
        let p = self.to_mm(at);
        if self.outside(p) {
            return;
        }
        let icon_size = CONSUMABLE_ICON_SIZE * self.unit;
        let spacing = 2.0 * self.unit;
        let count = icons.len() as f32;
        let start_x = p.x - (count * icon_size + (count - 1.0) * spacing) / 2.0;
        let y = p.y - self.marker_size() / 2.0 - icon_size - spacing;
        for (i, v) in icons.iter_shared().enumerate() {
            if let Ok(tex) = v.try_to::<Gd<Texture2D>>() {
                let x = start_x + i as f32 * (icon_size + spacing);
                self.c.draw_texture_rect(&tex, Rect2::new(Vector2::new(x, y), Vector2::new(icon_size, icon_size)), false);
            }
        }
    }

    fn aircraft(&mut self, at: Vector3, rot: f32, color: Color) {
        let p = self.to_mm(at);
        let s = AIRCRAFT_MARKER_SIZE * self.unit;
        let pts: PackedVector2Array = [
            Vector2::new(0.0, -s),
            Vector2::new(s * 0.55, 0.0),
            Vector2::new(0.0, s * 0.6),
            Vector2::new(-s * 0.55, 0.0),
        ]
        .iter()
        .map(|v| v.rotated(-rot) + p)
        .collect();
        self.c.draw_colored_polygon(&pts, color);
        let mut outline = color.darkened(0.45);
        outline.a = 0.8;
        let s = pts.as_slice();
        let ring: PackedVector2Array = [s[0], s[1], s[2], s[3], s[0]].into_iter().collect();
        self.c.draw_polyline_ex(&ring, outline).width(1.0).done();
    }

    fn squadron_path(&mut self, path: &SquadronPath) {
        let base = self.to_mm(Vector3::new(path.base.x, 0.0, path.base.y));
        let mut prev = base;
        for wp in &path.waypoints {
            let w = self.to_mm(Vector3::new(wp.x, 0.0, wp.y));
            self.c.draw_line_ex(prev, w, SQUADRON_WAYPOINT_COLOR).width(PATH_LINE_WIDTH).done();
            if self.circles {
                self.c.draw_circle(w, WAYPOINT_MARKER_RADIUS, SQUADRON_WAYPOINT_COLOR);
            }
            prev = w;
        }
        if let (true, Some(ap)) = (path.waypoints.is_empty(), path.attack_point) {
            let a = self.to_mm(Vector3::new(ap.x, 0.0, ap.y));
            self.c.draw_line_ex(base, a, SQUADRON_ATTACK_COLOR).width(PATH_LINE_WIDTH).done();
        }
    }

    fn fov_arc(&mut self, center: Vector2, range: f32, cam_rot_y: f32, fov_deg: f32, aspect: f32) {
        let fov_h = 2.0 * ((fov_deg.to_radians() / 2.0).tan() * aspect).atan();
        let r = range * self.scale;
        let mid = -cam_rot_y - PI / 2.0;
        let (a0, a1) = (mid - fov_h / 2.0, mid + fov_h / 2.0);
        let mut pts = PackedVector2Array::new();
        pts.push(center);
        for i in 0..=FOV_ARC_SEGMENTS {
            let a = a0 + (i as f32 / FOV_ARC_SEGMENTS as f32) * (a1 - a0);
            pts.push(center + Vector2::new(a.cos(), a.sin()) * r);
        }
        self.c.draw_colored_polygon(&pts, FOV_ARC_COLOR);
        let outline = Color::from_rgba(FOV_ARC_COLOR.r, FOV_ARC_COLOR.g, FOV_ARC_COLOR.b, 0.5);
        if self.circles {
            self.c.draw_arc_ex(center, r, a0, a1, FOV_ARC_SEGMENTS as i32, outline).width(1.5).done();
        }
        let e0 = center + Vector2::new(a0.cos(), a0.sin()) * r;
        let e1 = center + Vector2::new(a1.cos(), a1.sin()) * r;
        let edges: PackedVector2Array = [center, e0, center, e1].into_iter().collect();
        self.c.draw_multiline_ex(&edges, outline).width(1.5).done();
    }
}

impl MinimapCanvas {
    fn tick_inner(&mut self) {
        let n = &self.n;
        self.tracked.retain(|t| t.ship.is_instance_valid() && t.ship.is_inside_tree());
        for t in &mut self.tracked {
            let alive = sub(&t.ship.clone().upcast(), &n.health_controller).is_some_and(|h| call0(&h, &n.is_alive).to_bool());
            if alive {
                t.pos = t.ship.get_global_position();
                t.rot = t.ship.get_rotation().y;
            }
        }

        self.planes.clear();
        self.orbits.clear();
        self.paths.clear();
        let player = self.player.clone().filter(|p| p.is_instance_valid());
        let player_team = player.as_ref().and_then(|p| team_id(&p.clone().upcast(), n));
        let mut ships: Vec<Gd<Node3D>> = self.tracked.iter().map(|t| t.ship.clone()).collect();
        ships.extend(player.clone());
        for s in &ships {
            let is_player = player.as_ref() == Some(s);
            let friendly = player_team.is_some() && team_id(&s.clone().upcast(), n) == player_team;
            gather_aviation(n, s, is_player, friendly, &mut self.planes, &mut self.orbits, &mut self.paths);
        }
        self.base_mut().queue_redraw();
    }

    fn draw_inner(&mut self) {
        let mm = self.map_size;
        let mut pt = Painter {
            c: self.base().clone(),
            mm,
            unit: mm / self.max_size,
            scale: (mm / self.world_rect.size.x).min(mm / self.world_rect.size.y),
            wr: self.world_rect,
            circles: self.draw_circles,
            font: ThemeDb::singleton().get_fallback_font(),
        };
        pt.c.draw_rect_ex(Rect2::new(Vector2::ZERO, Vector2::new(mm, mm)), HALF_WHITE).filled(false).width(2.0).done();

        let n = &self.n;
        let Some(player) = self.player.clone().filter(|p| p.is_instance_valid()) else { return };
        let ship: Gd<Object> = player.clone().upcast();
        let player_pos = player.get_global_position();
        let player_team = team_id(&ship, n);

        let viewport = self.base().get_viewport();
        let cam = viewport.as_ref().and_then(|v| v.get_camera_3d());
        let bc = cam.clone().filter(|c| script_is(&c.clone().upcast(), &n.cls_battle_camera, n));
        let bc_obj: Option<Gd<Object>> = bc.clone().map(|c| c.upcast());
        let follow = bc_obj.as_ref().and_then(|b| sub(b, &n.follow_ship));
        let arc_ship = follow.clone().unwrap_or_else(|| ship.clone());
        let arc_range = sub(&arc_ship, &n.artillery_controller).map_or(0.0, |a| params_range(&a, n));

        if let (Some(bc), Some(b)) = (&bc, &bc_obj) {
            let free = b.get(&n.spectate_free).to_bool();
            let center = if free {
                Some(bc.get_global_position())
            } else {
                follow.clone().and_then(|f| f.try_cast::<Node3D>().ok()).map(|f| f.get_global_position())
            };
            if let (Some(center), Some(vp)) = (center, &viewport) {
                let size = vp.get_visible_rect().size;
                pt.fov_arc(pt.to_mm(center), arc_range, bc.get_rotation().y, bc.get_fov(), size.x / size.y);
            }
        }

        let locked_id = bc_obj.as_ref()
            .filter(|b| b.get(&n.target_lock_enabled).to_bool())
            .and_then(|b| sub(b, &n.locked_target))
            .map(|t| t.instance_id());

        let mut entries: Vec<ShipEntry> = Vec::with_capacity(self.tracked.len());
        let mut auras: Vec<(Vector3, Color)> = Vec::new();
        for t in &mut self.tracked {
            if !t.ship.is_instance_valid() {
                continue;
            }
            let o: Gd<Object> = t.ship.clone().upcast();
            let visible = o.get(&n.visible_to_enemy).to_bool();
            let radar = o.get(&n.radar_detected).to_bool();
            let hydro = o.get(&n.hydro_detected).to_bool();
            let air = o.get(&n.air_detected).to_bool();
            let tid = team_id(&o, n);
            let enemy = tid != player_team;
            if enemy && (visible || hydro || radar || air) {
                t.init = true;
            }
            if enemy && !t.init {
                continue;
            }
            let friendly = !enemy && tid.is_some();
            let dead = sub(&o, &n.health_controller).is_some_and(|h| call0(&h, &n.is_dead).to_bool());
            let color = if dead {
                Color::from_rgba(0.2, 0.2, 0.2, 1.0)
            } else if friendly {
                FRIENDLY_COLOR
            } else if visible {
                ENEMY_COLOR
            } else if radar {
                RADAR_RANGE_COLOR
            } else if hydro {
                HYDRO_RANGE_COLOR
            } else if air {
                AIR_RANGE_COLOR
            } else {
                Color::from_rgba(0.4, 0.4, 0.4, 1.0)
            };

            let mut icons = VarArray::new().upcast_any_array();
            if friendly {
                let det = if o.get(&n.det_radar).to_bool() {
                    Some(RADAR_RANGE_COLOR)
                } else if o.get(&n.det_hydro).to_bool() {
                    Some(HYDRO_RANGE_COLOR)
                } else if o.get(&n.det_air).to_bool() {
                    Some(AIR_RANGE_COLOR)
                } else if o.get(&n.det_los).to_bool() {
                    Some(GOLD)
                } else {
                    None
                };
                if let Some(c) = det {
                    auras.push((t.pos, c.with_alpha(0.7)));
                }
                if let Some(cm) = sub(&o, &n.consumable_manager) {
                    icons = call0(&cm, &n.get_active_icons).to_any_array();
                }
            }
            let short: GString = o.get(&n.short_name).try_to().unwrap_or_default();
            let name = if short.is_empty() { o.get(&n.ship_name).try_to().unwrap_or_default() } else { short };
            entries.push(ShipEntry {
                pos: t.pos,
                rot: -t.rot,
                color,
                icons,
                name,
                locked: locked_id == Some(o.instance_id()),
                dead,
            });
        }

        if let Some(art) = sub(&ship, &n.artillery_controller) {
            if art.get(&n.guns).to_any_array().len() > 0 {
                pt.range_circle(player_pos, params_range(&art, n), HALF_WHITE);
            }
        }
        if let Some(tc) = sub(&ship, &n.torpedo_controller) {
            pt.range_circle(player_pos, params_range(&tc, n), HALF_WHITE);
        }
        if let Some(sc) = sub(&ship, &n.secondary_controller) {
            for c in sc.get(&n.sub_controllers).to_any_array().iter_shared().filter_map(obj) {
                pt.range_circle(player_pos, params_range(&c, n), DARK_KHAKI);
            }
        }
        if let Some(av) = sub(&ship, &n.aviation_controller) {
            let mut seen: Vec<f32> = Vec::new();
            for p in av.get(&n.params).to_any_array().iter_shared().filter_map(obj) {
                let r = p.get(&n._range).to_f32();
                if !seen.contains(&r) {
                    seen.push(r);
                    pt.range_circle(player_pos, r, AIR_CIRCLE_COLOR);
                }
            }
        }
        if let Some(aa) = sub(&ship, &n.aaa_controller).and_then(|a| obj(call0(&a, &n.get_params))) {
            let r = aa.get(&n._range).to_f32();
            if r > 0.0 && aa.get(&n.dps).to_f32() > 0.0 {
                pt.range_circle(player_pos, r, AIR_RANGE_COLOR);
            }
        }

        if let Some(conc) = sub(&ship, &n.concealment) {
            pt.dashed_circle(player_pos, call0(&conc, &n.get_concealment).to_f32(), HALF_WHITE, 8.0, 4.0, 2.0);
            let air = sub(&conc, &n.params).and_then(|p| obj(call0(&p, &n.p))).map_or(0.0, |p| p.get(&n.air_radius).to_f32());
            if air > 0.0 {
                pt.dashed_circle(player_pos, air, HALF_WHITE, 8.0, 4.0, 3.0);
            }
        }

        let torp_range = active_consumable(&ship, &n.cls_hydro, &n.torpedo_detection_range, n);
        if torp_range > 0.0 && pt.circles {
            let fill = HYDRO_RANGE_COLOR.with_alpha(0.2);
            let c = pt.to_mm(player_pos);
            pt.c.draw_circle(c, torp_range * pt.scale, fill);
        }
        let hydro_range = active_consumable(&ship, &n.cls_hydro, &n.spotting_range, n);
        if hydro_range > 0.0 {
            pt.dashed_circle(player_pos, hydro_range, HYDRO_RANGE_COLOR, 3.0, 4.0, 3.0);
        }
        let radar_range = active_consumable(&ship, &n.cls_radar, &n.spotting_range, n);
        if radar_range > 0.0 {
            pt.dashed_circle(player_pos, radar_range, RADAR_RANGE_COLOR, 3.0, 4.0, 3.0);
        }

        for (pos, color) in &auras {
            pt.aura(*pos, *color);
        }
        for e in entries.iter().filter(|e| e.dead) {
            pt.tracked_ship(e);
        }
        for e in entries.iter().filter(|e| !e.dead) {
            pt.tracked_ship(e);
        }
        let player_name: GString = ship.get(&n.ship_name).try_to().unwrap_or_default();
        pt.ship(player_pos, -player.get_rotation().y, PLAYER_COLOR, &player_name);

        for e in entries.iter().filter(|e| e.icons.len() > 0) {
            pt.consumables(e.pos, &e.icons);
        }
        if let Some(cm) = sub(&ship, &n.consumable_manager) {
            let icons = call0(&cm, &n.get_active_icons).to_any_array();
            if icons.len() > 0 {
                pt.consumables(player_pos, &icons);
            }
        }

        if pt.circles {
            for o in &self.orbits {
                let (c, r) = (pt.to_mm(o.center), o.radius * pt.scale);
                pt.c.draw_circle(c, r, o.color.with_alpha(0.08));
                pt.c.draw_arc_ex(c, r, 0.0, TAU, 48, o.color.with_alpha(0.45)).width(1.0).done();
            }
        }
        for a in &self.planes {
            pt.aircraft(a.pos, a.rot, a.color);
        }
        for p in &self.paths {
            pt.squadron_path(p);
        }

        self.draw_torpedoes(&mut pt, &player, player_team);

        if bc_obj.as_ref().is_some_and(|b| b.get(&n.spectating).to_bool()) {
            return;
        }
        let shell = player.get_node_or_null("Modules/PlayerControl")
            .map(|pc| pc.upcast::<Object>())
            .and_then(|pc| sub(&pc, &n.current_weapon_controller))
            .and_then(|wc| call0(&wc, &n.get_shell_params).try_to::<Gd<Resource>>().ok());
        let mut aim = self.aim_point;
        if let Some(shell) = shell {
            let lv = ProjectilePhysicsWithDragV2::calculate_launch_vector_impl(player_pos, aim, &shell);
            if let Some(v) = lv.get(0).and_then(|v| v.try_to::<Vector3>().ok()) {
                aim = ProjectilePhysicsWithDragV2::calculate_impact_position_impl(player_pos, v, &shell);
            }
        }
        let p = pt.to_mm(aim);
        if !pt.outside(p) && pt.circles {
            pt.c.draw_circle_ex(p, 2.0, Color::WHITE).filled(false).done();
        }
    }

    fn draw_torpedoes(&self, pt: &mut Painter, player: &Gd<Node3D>, player_team: Option<i64>) {
        if !pt.circles {
            return;
        }
        let n = &self.n;
        let Some(tm) = self.base().get_node_or_null("/root/TorpedoManager").map(|t| t.upcast::<Object>()) else { return };
        let r = TORPEDO_MARKER_SIZE * pt.unit / 2.0;
        let player_id = player.instance_id();
        for t in tm.get(&n.torpedos).to_any_array().iter_shared().filter_map(obj) {
            if !t.get(&n.armed).to_bool() {
                continue;
            }
            let p = pt.to_mm(t.get(&n.position).try_to::<Vector3>().unwrap_or_default());
            if pt.outside(p) {
                continue;
            }
            let color = match obj(t.get(&n.owner)) {
                None => PLAYER_COLOR,
                Some(o) if o.instance_id() == player_id => PLAYER_COLOR,
                Some(o) if player_team.is_some() && team_id(&o, n) == player_team => FRIENDLY_COLOR,
                Some(_) => ENEMY_COLOR,
            };
            pt.c.draw_circle(p, r, color);
        }
    }
}
