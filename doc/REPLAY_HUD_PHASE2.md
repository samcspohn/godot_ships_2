# Replay HUD — Phase 2: ViewModel Refactor

## Goal

Make the in-game HUD (`src/ui/camera_ui_scene.gd` + `camera_ui.tscn`) usable
**verbatim** by both gameplay and replay, by inverting the dependency:

> Today: `CameraUIScene` reaches *into* `BattleCamera` and `Ship` and reads
> ~50 different controller fields directly.
>
> After Phase 2: `CameraUIScene` reads from a single `IShipView` /
> `ICameraView` interface. Gameplay supplies a `LiveShipView` that wraps the
> real `Ship`. Replay supplies a `ReplayShipView` that wraps a `GhostShip` +
> snapshot data + an event stream.

When this is done, replay gets the *full* HUD — including reload bars, active
consumables, skills indicators, minimap, optional aim crosshair, even an
end-of-match screen — for free, and any future HUD work has only one place to
maintain.

This also unlocks a future **live spectator** mode (an observer client running
the same HUD on a different ship's data) with no HUD changes.

---

## Non-goals

- Replacing `Ship` with `GhostShip` in gameplay.
- Driving live `Ship` controllers from a replay (Option C in the original
  analysis — too fragile).
- Re-implementing input (weapon selection, sniper toggle, options menu) for
  replay. The HUD will simply hide or disable interactive controls when its
  view exposes `is_interactive == false`.

---

## Interface design

Two thin interfaces, both implemented as GDScript classes. We can't enforce
them via `interface` keyword (GDScript has none), so we use:

- `class_name IShipView` as an *abstract base* with `@warning_ignore` stubs, OR
- duck-typed dictionaries with documented keys.

Recommendation: **abstract base classes**, because the HUD already type-hints
heavily and the IDE benefits are large.

### `IShipView` (read-only ship snapshot)

Located at `src/ui/views/i_ship_view.gd`.

```gdscript
class_name IShipView extends RefCounted

# Identity
var ship_id: int               # stable id (matches replay manifest)
var ship_name: String
var player_name: String
var team_id: int
var is_bot: bool

# Spatial
var global_transform: Transform3D
var linear_velocity: Vector3
var speed_knots: float         # convenience

# Health
var current_hp: float
var max_hp: float
var healable_damage: float

# Status
var detection_type: int        # Ship.DetectionType enum value
var visible_to_enemy: bool
var is_sunk: bool
var fires_active: int          # popcount(fire_mask)
var floods_active: int

# Movement (display only)
var throttle_level: int        # –1..4
var rudder_input: float        # –1..1

# Aim / artillery (optional — null/0 if unknown)
var aim_point: Vector3
var bloom_radius: float
var current_shell_index: int

# Weapon batteries — dynamic count, in stable order
func get_main_guns() -> Array[GunView]    # GunView: { reload: float, ready: bool, rotation_y, barrel_pitch_x }
func get_secondary_guns() -> Array[GunView]
func get_torpedo_launchers() -> Array[LauncherView]   # may return []

# Consumables — manifest order
func get_consumables() -> Array[ConsumableView]
# ConsumableView: {
#   slot_id, type, label, icon: Texture2D,
#   is_active: bool, time_remaining: float, cooldown_remaining: float,
#   charges_remaining: int,
# }

# Skills (optional)
func get_skills() -> Array[SkillView]

# Stats (read-only snapshot, mutates externally)
var stats: IShipStatsView    # see below
```

### `IShipStatsView`

Mirrors the field names that `HitStatCounters` and `BattleEndScreen` already
read from `Stats`. `LiveShipView` exposes the real `Stats` directly;
`ReplayShipView` exposes the running `replay_stats_accumulator`.

### `ICameraView`

Located at `src/ui/views/i_camera_view.gd`.

```gdscript
class_name ICameraView extends RefCounted

# The ship the HUD currently centres on (the player's ship in gameplay,
# the followed ship in replay).
var ship: IShipView

# Spatial
var global_transform: Transform3D

# Aim assist read-outs (gameplay supplies real ballistics; replay supplies
# null / NaN / the recorded aim_point).
var time_to_target: float
var distance_to_target: float
var penetration_power: float
var terrain_hit: bool
var aim_position: Vector3
var max_range_reached: bool

# Target lock
var locked_target: IShipView    # nullable
var target_lock_enabled: bool

# Modes
var is_sniper: bool
var is_free_look: bool

# Capability flags — drives whether the HUD shows interactive controls.
var is_interactive: bool        # true for gameplay, false for replay/spectator
var supports_aiming: bool
var supports_consumable_input: bool
var supports_weapon_selection: bool

# World ship enumeration (replaces in-HUD `get_tree().get_nodes_in_group(...)` scans)
func get_all_ship_views() -> Array[IShipView]
```

### Implementations

```
src/ui/views/
  i_ship_view.gd
  i_camera_view.gd
  i_ship_stats_view.gd
  gun_view.gd
  consumable_view.gd
  skill_view.gd

src/ui/views/live/
  live_ship_view.gd       # wraps Ship
  live_camera_view.gd     # wraps BattleCamera
  live_ship_stats_view.gd # wraps Stats

src/ui/views/replay/
  replay_ship_view.gd     # wraps GhostShip + snapshot getter
  replay_camera_view.gd   # wraps the orbit camera + selected GhostShip
  replay_ship_stats_view.gd # wraps replay_stats_accumulator
```

Live views are mostly one-line accessors:

```gdscript
class_name LiveShipView extends IShipView

var _ship: Ship
func _init(s: Ship) -> void: _ship = s

# Backed properties — could use getter functions instead of plain vars if we
# want to avoid stale reads. Recommendation: use getters everywhere.
func _get(name: StringName) -> Variant:
    match name:
        &"current_hp": return _ship.health_controller.current_hp
        &"max_hp":     return _ship.health_controller.max_hp
        # …
```

Replay views pull from `ReplayPlayback._snap_b` (or a fully interpolated
snapshot) and from the manifest.

---

## Refactor of `camera_ui_scene.gd`

Mechanical rename pass — every reference to `camera_controller` / `_ship` / a
controller becomes a reference to `_camera_view` / `_ship_view`.

Concrete examples:

| Today | After |
|---|---|
| `camera_controller._ship.health_controller.current_hp` | `_ship_view.current_hp` |
| `camera_controller._ship.movement_controller.throttle_level` | `_ship_view.throttle_level` |
| `camera_controller._ship.detection_type` | `_ship_view.detection_type` |
| `camera_controller._ship.secondary_controller.enabled` | (covered by view; e.g. `_ship_view.secondaries_enabled`) |
| `camera_controller._ship.consumable_manager.equipped_consumables` | `_ship_view.get_consumables()` |
| `camera_controller._ship.skills.skills` | `_ship_view.get_skills()` |
| `camera_controller._ship.artillery_controller.guns[i].reload` | `_ship_view.get_main_guns()[i].reload` |
| `camera_controller._ship.team.team_id` | `_ship_view.team_id` |
| `camera_controller._ship.stats` | `_ship_view.stats` |
| `camera_controller.global_transform` | `_camera_view.global_transform` |

Interactive blocks (weapon buttons, sniper key, options menu) get gated by
`_camera_view.is_interactive` / `supports_weapon_selection` etc. In replay,
those panels collapse to zero size or are hidden.

### Setup contract

```gdscript
# camera_ui_scene.gd
var _ship_view: IShipView
var _camera_view: ICameraView

func bind(camera_view: ICameraView) -> void:
    _camera_view = camera_view
    _ship_view = camera_view.ship
    # … defer all setup_* calls until here
```

All `_ready()` calls that touch `camera_controller` move into `bind()`. The
existing `if camera_controller: setup_weapons.call_deferred()` pattern goes
away.

### Where the HUD is instantiated

- **Gameplay** (today): `BattleCamera` instantiates `CameraUIScene`, sets
  `camera_controller = self`, sets `player_controller = …`. After Phase 2:
  it instantiates `CameraUIScene`, builds a `LiveCameraView` wrapping itself,
  and calls `hud.bind(view)`.
- **Replay** (new): `match_replay.gd` instantiates the same scene, builds a
  `ReplayCameraView` wrapping the orbit camera + selected `GhostShip`, and
  calls `hud.bind(view)`.

---

## Replay-side enrichment

To deliver the full HUD experience in replay, the `.replay` format needs a few
small additions. All are backwards-compatible (reader checks `_version`).

### Format bump v3

| Addition | Where | Cost |
|---|---|---|
| `damage` (float) on `EVT_SHELL_HIT` | per event | +4 bytes/hit; small |
| `healable_damage` (float) per ship | per snapshot | +4 bytes/ship/snapshot |
| `secondary_enabled` (1 bit in flags) | per ship | free (use spare flag bit) |
| `consumable_charges_remaining` (u8 per slot) | per snapshot OR on `EVT_CONSUMABLE_USED` | small |
| `consumable_duration_seconds` (u16 per consumable) | manifest | one-time per ship |
| Optional: `damage_taken_pos` (Vector3) on `EVT_SHELL_HIT` | already there as `hit_pos` | reuse |

These let the replay drive:

- Live damage tally → `Stats.total_damage`, `main_damage`, etc.
- Healable HP region of the HP bar.
- Secondaries-disabled indicator.
- Consumable countdown / cooldown rings.
- Floating damage numbers anchored at world hit positions.

### What stays unrecorded

- **Aim ballistics** (time-to-target, penetration power for the *current* aim
  point) — these are gameplay-time computations against `ProjectileManager`.
  In replay we either:
  1. Display the recorded `aim_point` and recompute ballistics against the map
     mesh and the current snapshot ship velocity (cheap, accurate enough), or
  2. Skip the crosshair info readouts entirely.

  Recommendation: **option (1)**, gated by `supports_aiming`.

- **Skills runtime state** — in replay we either don't show skill indicators or
  we record skill activations as new events (`EVT_SKILL_TRIGGERED` etc.). Defer
  to a later format bump if needed.

---

## Migration plan (work-package breakdown)

### WP1 — Interface scaffolding (no behaviour change)

1. Create `src/ui/views/` and write the 6 abstract classes.
2. Implement `LiveShipView` + `LiveCameraView` + `LiveShipStatsView` as 1:1
   wrappers around current usage sites.
3. **Do not touch `camera_ui_scene.gd` yet.** Add a unit-style scene that
   verifies the wrappers compile and read the expected fields.

### WP2 — Mechanical refactor of `camera_ui_scene.gd`

Per-section, smallest-blast-radius first:

1. `_update_ui` (HP / throttle / rudder / speed) → views.
2. `update_visibility_indicator`, `update_secondaries_disabled_indicator`.
3. `update_gun_reload_bars`.
4. `update_consumable_ui`, `setup_consumable_ui`.
5. `_update_skill_indicators`.
6. `setup_team_tracker`, `update_team_tracker`, `update_ship_ui`,
   `update_team_container*`, `setup_ship_ui`, `update_team_indicator`.
7. `update_visibility_indicator`, `_update_camera_angle_display`.
8. `_physics_process` aggregator, `initialize_for_ship`, `_on_match_ended`.
9. Interactive parts (`setup_weapon_buttons`, sniper reticle, options menu)
   gated on `_camera_view.is_interactive` / `supports_weapon_selection`.
10. `Minimap.register_player_ship` migrated to take `IShipView`.

After each step the gameplay path must still work end-to-end (run a real
match). This is gameplay-affecting code — every WP2 step is "boring rename
+ reroute" and should be reviewed for typos rather than logic.

### WP3 — Replay views

1. `ReplayShipView` over `GhostShip` + `ReplayPlayback._snap_b` getter.
2. `ReplayCameraView` over the orbit camera + selected ghost.
3. `ReplayShipStatsView` over `replay_stats_accumulator` (already built in
   Phase 1).

### WP4 — Replace ReplayHUD with full `CameraUIScene`

1. In `match_replay.gd`, instance `camera_ui.tscn` instead of `replay_hud.tscn`.
2. Build views, call `hud.bind(view)`.
3. Make sure interactive panels hide cleanly under
   `is_interactive == false`.
4. Wire the existing replay top bar / scrubber to coexist with the HUD's
   anchors — likely move the scrubber into a slim overlay above the HUD's
   `BottomCenterPanel`.

### WP5 — Format v3 additions

Add the small per-event/per-snapshot fields above. Bump `_version`. Keep the
v2 reader path. This step is what turns *most* of the HUD from "approximate"
to "exact" in replay.

### WP6 — Spectator (optional, future)

Once Live + Replay views both implement the same interface, a *third*
implementation `SpectatorShipView` can stream snapshots from the server and
plug directly into the same HUD. Out of scope for this document.

---

## Testing strategy

- **Snapshot test**: write a tiny harness that constructs a fake `LiveShipView`
  with known field values and asserts the HUD reads the correct labels/bars
  per frame. Same harness with a fake `ReplayShipView`.
- **Side-by-side**: a debug toggle that displays both the live HUD and a
  replay HUD pointed at the same ship in real time during a match (using the
  recorder's in-flight buffer). Any divergence is a view bug or a recorder
  bug.
- **Regression**: full play-through of an existing replay before/after each
  WP2 step. Visual diff at three timestamps: 5 s, mid-match, 30 s before end.

---

## Risks

- **Hidden coupling**: `_update_ui`, `update_ship_ui`, and others read live
  `Ship` references and pass them around (e.g. `Ship` → `setup_ship_ui` →
  stores `ship` in `tracked_ships`). Every such storage site has to switch
  from `Ship` to `IShipView`. Expect bugs around identity (`==` of two view
  wrappers around the same underlying ship needs to be true). Solution:
  override `_to_string` and key by `ship_id` in the dictionaries instead of
  by object identity.
- **Performance**: GDScript dynamic dispatch through `_get` is slower than
  direct field access. Profile after WP2; if `_physics_process` regresses,
  switch hot paths to plain `var` mirrors that the view writes once per
  physics frame.
- **Skills**: `Skill.init_ui(slot)` currently mutates the slot Control
  directly. We have two choices: (a) move the skill-icon construction *into*
  the view, returning a Texture/Label config the HUD lays out, or (b)
  document `init_ui`/`update_ui` as part of `SkillView` and require both Live
  and Replay views to implement them. (b) is cheaper today, (a) is cleaner.
- **Floating damage** uses a 0.25 s accumulator with a *world hit position*.
  Live and replay both have the data via `EVT_SHELL_HIT.hit_pos` once we add
  damage to the format (WP5).
- **Match end**: `_on_match_ended` reads `Stats` and a screenshot, then quits
  the scene tree. Replay equivalent: on `EVT_MATCH_END`, we have the
  per-ship final stats already in the format. The end screen needs a small
  abstraction (`IBattleEndSource`) — defer to its own work package.

---

## Definition of done

- `camera_ui_scene.gd` no longer contains a single reference to `Ship`,
  `BattleCamera`, `Turret`, `Gun`, `ConsumableManager`, `Stats`, or any
  controller class. It only references `IShipView`, `ICameraView`, and their
  members.
- Gameplay still feels and looks identical (visual + input regression).
- Match replay instantiates the same `camera_ui.tscn` and shows: HP bar with
  healable region, exact speed/throttle/rudder, all gun reload bars,
  per-consumable cooldown rings, fire/flood icons, team tracker, minimap, hit
  stat counters with running damage values, and the kill feed.
- Aiming-related widgets are hidden in replay (`supports_aiming == false`).
- `replay_hud.tscn` from Phase 1 is deleted.
- `Phase 1` ↔ `Phase 2` migration is observable as a single commit that
  removes ~10 manual `replay_hud` widgets and adds ~3 lines that bind the
  replay views to `camera_ui.tscn`.
