use super::snapshot::HullClass;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Playstyle {
    Gunboat,
    Tank,
    Dps,
    IslandHugger,
    Brawler,
}

impl Playstyle {
    pub fn from_i32(v: i32, class: HullClass) -> Self {
        match v {
            0 => Playstyle::Gunboat,
            1 => Playstyle::Tank,
            2 => Playstyle::Dps,
            3 => Playstyle::IslandHugger,
            4 => Playstyle::Brawler,
            _ => Self::default_for(class),
        }
    }

    pub fn default_for(class: HullClass) -> Self {
        match class {
            HullClass::Bb => Playstyle::Tank,
            HullClass::Ca => Playstyle::Dps,
            HullClass::Dd => Playstyle::Gunboat,
            HullClass::Cv => Playstyle::Gunboat,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Playstyle::Gunboat => "gunboat",
            Playstyle::Tank => "tank",
            Playstyle::Dps => "dps",
            Playstyle::IslandHugger => "island_hugger",
            Playstyle::Brawler => "brawler",
        }
    }

    pub fn style(self) -> Style {
        match self {
            Playstyle::Gunboat => Style { band: (0.75, 0.92), aggression: 0.2, risk: 1.5 },
            Playstyle::Tank => Style { band: (0.45, 0.65), aggression: 0.7, risk: 0.6 },
            Playstyle::Dps => Style { band: (0.6, 0.8), aggression: 0.5, risk: 1.0 },
            Playstyle::IslandHugger => Style { band: (0.6, 0.85), aggression: 0.4, risk: 2.0 },
            Playstyle::Brawler => Style { band: (0.25, 0.45), aggression: 0.9, risk: 0.4 },
        }
    }
}

/// Station ranges are fractions of the bot's own gun range.
#[derive(Clone, Copy, Debug)]
pub struct Style {
    pub band: (f32, f32),
    pub aggression: f32,
    /// Weight of damage taken per minute against damage dealt per minute, at full hp.
    pub risk: f32,
}

/// BotAptitude.Level order: RECRUIT, REGULAR, VETERAN, ACE.
#[derive(Clone, Copy, Debug)]
pub struct Aptitude {
    pub level: i32,
}

impl Aptitude {
    pub fn team_weight(self) -> f32 {
        [0.0, 0.35, 0.7, 1.0][self.level.clamp(0, 3) as usize]
    }

    /// Positioning reads enemy positions this stale; never applied to gunnery.
    pub fn view_delay_s(self) -> f64 {
        [12.0, 6.0, 2.0, 0.0][self.level.clamp(0, 3) as usize]
    }

    pub fn reads_turns(self) -> bool {
        self.level >= 1
    }
}

#[derive(Clone, Debug, Default)]
pub struct Kinematics {
    pub turning_circle_radius: f32,
    pub rudder_response_time: f32,
    pub acceleration_time: f32,
    pub deceleration_time: f32,
    pub max_speed: f32,
    pub reverse_speed_ratio: f32,
    pub length: f32,
    pub beam: f32,
    pub turn_speed_loss: f32,
    pub linear_drag: f32,
    pub turn_tightening: f32,
}
