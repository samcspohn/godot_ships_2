use godot::prelude::*;
use std::collections::HashMap;

use crate::nav::types::ThreatCircle;

/// One enemy, as the threat picture sees it. Updated by `update_team` each tick
/// and persistent across calls so an entry survives the ship moving.
#[derive(Clone, Copy, Debug)]
pub struct EnemyThreatState {
    pub enemy_id: i32,
    pub position: Vector2, // world XZ
    pub decay: f32,        // [0,1] — fades for unspotted ships
    /// How far this ship can force-spot regardless of anybody's concealment:
    /// radar, hydroacoustic search. Zero for a ship with nothing running. This
    /// is the enemy's own reach and has nothing to do with who is asking, which
    /// is why it lives here and the observer's radius does not.
    pub force_spot: f32,
    pub seen_this_tick: bool,
}

impl Default for EnemyThreatState {
    fn default() -> Self {
        Self {
            enemy_id: -1,
            position: Vector2::ZERO,
            decay: 1.0,
            force_spot: 0.0,
            seen_this_tick: false,
        }
    }
}

struct TeamData {
    enemies: HashMap<i32, EnemyThreatState>,
    /// Starts at 1 so a consumer can use 0 for "never synced".
    version: u64,
}

impl Default for TeamData {
    fn default() -> Self {
        Self { enemies: HashMap::new(), version: 1 }
    }
}

/// Per-team enemy positions, shared by every ship on the opposing side.
///
/// GDScript drives a single global tick by calling `update_team`. Each
/// ShipNavigator then builds its OWN threat circle list from this data via
/// `build_threats`, sized to its own detection radius.
///
/// Circles used to be pre-built here and shared, keyed by team and by the
/// observer's radius rounded up to the nearest kilometre. That saved almost
/// nothing — the expensive part, HpaGraph::stamp_threats, was always per-ship
/// anyway — and cost a great deal of accuracy: every ship routed against a
/// radius up to a kilometre larger than its own, which put the standoff a
/// spotting skill wanted reliably INSIDE the circle the router refused to path
/// through. Building per ship is O(enemies) per ship per tick and removes the
/// quantisation completely.
#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct ThreatRegistry {
    base: Base<RefCounted>,
    teams: HashMap<i32, TeamData>,
}

#[godot_api]
impl IRefCounted for ThreatRegistry {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, teams: HashMap::new() }
    }
}

// --- C++-only API (used by ShipNavigator) ---

impl ThreatRegistry {
    /// Build the threat circles for one observer. `observer_radius` is the
    /// range at which that ship is itself detectable, plus whatever margin it
    /// wants; the radius used for each enemy is the larger of that and the
    /// enemy's own force-spotting reach, because a radar cruiser sees you at
    /// radar range no matter how well you are hidden.
    pub(crate) fn build_threats(
        &self,
        team_id: i32,
        observer_radius: f32,
        out: &mut Vec<ThreatCircle>,
    ) {
        out.clear();
        let Some(team) = self.teams.get(&team_id) else {
            return;
        };
        out.reserve(team.enemies.len());
        for es in team.enemies.values() {
            // The larger of "how far away this ship can see me by my own
            // concealment" and "how far it can see me whatever my concealment".
            // Decay applies to both: a contact nobody has looked at for a while
            // is a fading claim about where the danger is, not a fading sensor.
            let radius = observer_radius.max(es.force_spot) * es.decay;
            if radius <= 0.0 {
                continue;
            }
            out.push(ThreatCircle::new(es.enemy_id, es.position, radius));
        }
        // Deterministic ordering keeps stamp_threats and the destination push
        // from depending on hash iteration order.
        out.sort_by(|a, b| a.enemy_id.cmp(&b.enemy_id));
    }

    /// Bumped every time `update_team` changes anything for this team, so a
    /// consumer can skip rebuilding. Never zero, so zero is safe as
    /// "never synced".
    pub(crate) fn get_team_version(&self, team_id: i32) -> u64 {
        self.teams.get(&team_id).map_or(1, |t| t.version)
    }
}

// --- GDScript-exposed API ---
//
// The C++ additionally binds get_enemy_count(), which has no caller anywhere in
// the project, so it is not ported.

#[godot_api]
impl ThreatRegistry {
    /// Replace the per-team enemy list. The three arrays are parallel:
    ///   ids                  — ship instance IDs
    ///   positions_with_decay — (world.x, world.z, decay); decay <= 0 is dropped
    ///   force_spot_ranges    — metres of radar/hydro reach, 0 for none
    /// Entries are matched by id across calls; vanished ids are pruned.
    #[func]
    fn update_team(
        &mut self,
        team_id: i32,
        ids: PackedInt32Array,
        positions_with_decay: PackedVector3Array,
        force_spot_ranges: PackedFloat32Array,
    ) {
        let team = self.teams.entry(team_id).or_default();

        // Mark every existing entry stale; survivors get re-flagged below.
        for es in team.enemies.values_mut() {
            es.seen_this_tick = false;
        }

        let mut changed = false;
        let n = ids.len().min(positions_with_decay.len());
        for i in 0..n {
            let eid = ids[i];
            let pwd = positions_with_decay[i];
            let decay = pwd.z;
            if decay <= 0.0 {
                continue;
            }
            let force_spot = if i < force_spot_ranges.len() {
                0.0f32.max(force_spot_ranges[i])
            } else {
                0.0
            };

            match team.enemies.get_mut(&eid) {
                None => {
                    changed = true;
                    team.enemies.insert(
                        eid,
                        EnemyThreatState {
                            enemy_id: eid,
                            position: Vector2::new(pwd.x, pwd.y),
                            decay,
                            force_spot,
                            seen_this_tick: true,
                        },
                    );
                }
                Some(es) => {
                    // Only a semantic change earns a version bump — consumers
                    // rebuild their whole circle list off it, and floating-point
                    // noise in a position is not a reason to make every ship on
                    // the team do that.
                    const POS_EPS: f32 = 0.01;
                    const SCALAR_EPS: f32 = 0.01;
                    if (es.position.x - pwd.x).abs() > POS_EPS
                        || (es.position.y - pwd.y).abs() > POS_EPS
                        || (es.decay - decay).abs() > SCALAR_EPS
                        || (es.force_spot - force_spot).abs() > SCALAR_EPS
                    {
                        changed = true;
                    }
                    es.position = Vector2::new(pwd.x, pwd.y);
                    es.decay = decay;
                    es.force_spot = force_spot;
                    es.seen_this_tick = true;
                }
            }
        }

        // Prune anything that stopped being reported.
        let before = team.enemies.len();
        team.enemies.retain(|_, es| es.seen_this_tick);
        if team.enemies.len() != before {
            changed = true;
        }

        if changed {
            team.version += 1;
        }
    }

    /// Drop every team's data (e.g. between matches).
    #[func]
    fn reset(&mut self) {
        self.teams.clear();
    }
}
