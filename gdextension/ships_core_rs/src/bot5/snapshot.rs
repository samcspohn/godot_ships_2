use godot::prelude::*;
use std::collections::HashMap;

pub const STRIDE: usize = 46;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HullClass {
    Bb,
    Ca,
    Dd,
    Cv,
}

impl HullClass {
    pub fn from_i32(v: i32) -> Self {
        match v {
            0 => HullClass::Bb,
            1 => HullClass::Ca,
            2 => HullClass::Dd,
            _ => HullClass::Cv,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            HullClass::Bb => "BB",
            HullClass::Ca => "CA",
            HullClass::Dd => "DD",
            HullClass::Cv => "CV",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ShipState {
    pub id: i64,
    pub team: i32,
    pub alive: bool,
    pub pos: Vector3,
    pub vel: Vector3,
    /// Godot rotation.y; forward is -basis.z.
    pub rot: f32,
    pub yaw_rate: f32,
    pub hp_frac: f32,
    pub hp_max: f32,
    /// Spotted by the other team (Ship.visible_to_enemy).
    pub seen: bool,
    pub max_speed: f32,
    pub reverse_ratio: f32,
    pub length: f32,
    pub beam: f32,
    pub class: HullClass,
    pub gun_range: f32,
    /// Hull top above the ship origin.
    pub top: f32,
    pub turn_radius: f32,
    pub air_radius: f32,
    pub torp_detect_mult: f32,
    pub torp_detect_floor: f32,
    /// Surface detection radius, unbloomed. Firing blooms it to gun_range.
    pub conceal: f32,
    /// Radar/hydro reach, running or carried (discounted); 0 for none.
    pub force_spot: f32,
    pub shell_speed: f32,
    pub shell_drag: f32,
    pub gun_h: f32,
    pub reload: f32,
    /// Shells per main-battery salvo.
    pub barrels: f32,
    pub damage: [f32; 2],
    pub sec_range: f32,
    /// Secondary damage per minute inside sec_range, on a hull like its own.
    pub sec_dpm: f32,
    /// Torpedoes: max range, m/s, damage, reload s, tubes per launcher, detection m, s to bring tubes to bear; range 0 without.
    pub torp_range: f32,
    pub torp_speed: f32,
    pub torp_damage: f32,
    pub torp_reload: f32,
    pub torp_tubes: f32,
    pub torp_detect: f32,
    pub torp_bear_s: f32,
    /// Degrees off the bow where every main gun bears.
    pub guns_bear: f32,
    pub rudder_lag: f32,
    /// ConcealmentParams.bloom_duration: a salvo keeps us visible at gun range this long.
    pub bloom_s: f32,
    /// Its guns fired within its bloom.
    pub bloomed: bool,
    /// Last main-battery shot, sim seconds.
    pub fired_at: f32,
}

/// v4 DDBehavior._is_gunboat inverted: tubes reaching well past our own detection.
const TORP_ENGAGE_RATIO: f32 = 0.8;
pub const SPOT_SAFE: f32 = 1.15;
const TORP_BAND_RATIO: f32 = 1.5;

impl ShipState {
    /// v4 FightStation.threatens: a destroyer spotting with its guns quiet is a target to close on, not a ring.
    pub fn threatens(&self) -> bool {
        self.class != HullClass::Dd || self.bloomed
    }

    pub fn torp_boat(&self) -> bool {
        self.class == HullClass::Dd && self.torp_range > 0.0
            && (self.conceal <= 0.0 || self.torp_range * TORP_ENGAGE_RATIO >= self.conceal * SPOT_SAFE * TORP_BAND_RATIO)
    }

    fn from_row(id: i64, r: &[f32]) -> Self {
        ShipState {
            id,
            team: r[0] as i32,
            alive: r[1] > 0.5,
            pos: Vector3::new(r[2], r[3], r[4]),
            vel: Vector3::new(r[5], 0.0, r[6]),
            rot: r[7],
            yaw_rate: r[8],
            hp_frac: r[9],
            seen: r[10] > 0.5,
            max_speed: r[11],
            length: r[12],
            beam: r[13],
            class: HullClass::from_i32(r[14] as i32),
            gun_range: r[15],
            hp_max: r[16],
            reverse_ratio: r[17],
            top: r[18],
            turn_radius: r[19],
            air_radius: r[20],
            torp_detect_mult: r[21],
            torp_detect_floor: r[22],
            conceal: r[23],
            force_spot: r[24],
            shell_speed: r[25],
            shell_drag: r[26],
            gun_h: r[27],
            reload: r[28],
            barrels: r[29],
            damage: [r[30], r[31]],
            sec_range: r[32],
            sec_dpm: r[33],
            torp_range: r[34],
            torp_speed: r[35],
            torp_damage: r[36],
            torp_reload: r[37],
            torp_tubes: r[38],
            torp_detect: r[39],
            torp_bear_s: r[40],
            guns_bear: r[41],
            rudder_lag: r[42],
            bloom_s: r[43],
            bloomed: r[44] > 0.5,
            fired_at: r[45],
        }
    }

    pub fn fwd(&self) -> Vector3 {
        let (s, c) = self.rot.sin_cos();
        Vector3::new(-s, 0.0, -c)
    }

    /// Navigator convention: 0 = +Z, PI/2 = +X.
    pub fn heading(&self) -> f32 {
        let f = self.fwd();
        f.x.atan2(f.z)
    }

    pub fn speed(&self) -> f32 {
        self.vel.dot(self.fwd())
    }

    pub fn p2(&self) -> Vector2 {
        Vector2::new(self.pos.x, self.pos.z)
    }

    pub fn to_world_dir(&self, local: Vector3) -> Vector3 {
        rot_y(local, self.rot)
    }

    pub fn to_local_dir(&self, world: Vector3) -> Vector3 {
        rot_y(world, -self.rot)
    }
}

pub fn rot_y(v: Vector3, a: f32) -> Vector3 {
    let (s, c) = a.sin_cos();
    Vector3::new(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
}

#[derive(Default)]
pub struct Snapshot {
    pub ships: Vec<ShipState>,
    pub index: HashMap<i64, usize>,
}

impl Snapshot {
    pub fn load(&mut self, ids: &[i64], data: &[f32]) {
        self.ships.clear();
        self.index.clear();
        for (i, &id) in ids.iter().enumerate() {
            let Some(r) = data.get(i * STRIDE..(i + 1) * STRIDE) else { break };
            self.index.insert(id, self.ships.len());
            self.ships.push(ShipState::from_row(id, r));
        }
    }

    pub fn get(&self, id: i64) -> Option<&ShipState> {
        self.index.get(&id).map(|&i| &self.ships[i])
    }

    pub fn enemies_of(&self, team: i32) -> impl Iterator<Item = &ShipState> {
        self.ships.iter().filter(move |s| s.alive && s.team != team)
    }

    pub fn allies_of(&self, team: i32) -> impl Iterator<Item = &ShipState> {
        self.ships.iter().filter(move |s| s.alive && s.team == team)
    }
}
