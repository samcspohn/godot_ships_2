# Match Replay System — Design & Implementation Plan

## Overview

A full match replay system consisting of two halves:

1. **Recorder** — runs server-side during a live match, writes a binary `.replay` file
2. **Viewer** — runs in the port scene, reads the file, drives ghost ships and simulated
   projectiles with a scrubber, speed controls, and a follow/orbit camera

Both halves share a common data-structure layer so the same event/snapshot definitions
are used for writing and reading.

---

## Architecture Summary

```
[LIVE MATCH — SERVER]
  GameServer._physics_process
       │
       ├─ ReplayRecorder (autoload child, server-only)
       │       │
       │       ├─ snapshot timer (5 Hz) → writes SNAPSHOT events
       │       ├─ hooks into Gun.fire()               → SHELL_FIRED
       │       ├─ hooks into Stats.record_hit()        → SHELL_HIT
       │       ├─ hooks into TorpedoManager signals    → TORPEDO_*
       │       ├─ hooks into Fire._sync_activate RPC   → FIRE_STARTED/ENDED
       │       ├─ hooks into Flood._sync_activate RPC  → FLOOD_STARTED/ENDED
       │       ├─ hooks into ConsumableManager signals  → CONSUMABLE_*
       │       ├─ hooks into _Utils.kill_feed_event     → SHIP_SUNK
       │       └─ hooks into _Utils.match_ended         → MATCH_END
       │
       └─ writes binary to user://replays/<timestamp>.replay
              │
              └── [index appended at EOF]

[PORT SCENE — CLIENT]
  match_replay.tscn
       │
       ├─ ReplayBrowser  (file picker)
       ├─ ReplayPlayback (time engine)
       │       ├─ ReplayFileReader (file + index loader)
       │       ├─ GhostShip × N   (visual-only ships, no physics)
       │       ├─ ShellReplayer   (analytical shell trails)
       │       └─ TorpedoReplayer (analytical torpedo markers)
       │
       └─ ReplayViewerUI
               ├─ Scrubber (HSlider + snapshot markers)
               ├─ Speed controls (-2x → 8x)
               ├─ Camera mode toggle (orbit / follow-ship)
               ├─ Kill feed overlay
               └─ Ship name tags + HP bars
```

---

## 1. File Format Specification

### 1.1 Header

Written once at match start with `ReplayRecorder.begin_match()`.

```
[4 bytes] magic         u32   0x52455050  ("REPP")
[2 bytes] version       u16   1
[4 bytes] match_ts      u32   Unix timestamp of match start (seconds)
[1 byte]  map_id        u8    0=map, 1=map2
[2 bytes] ship_count    u16   total ships (bots + players)
[4 bytes] index_offset  u32   byte offset of the index block (written last, filled at EOF)

[per ship — ship_count entries]
  [1 byte]  ship_id       u8    0-based index, stable for this file
  [1 byte]  team_id       u8    0 or 1
  [1 byte]  is_bot        u8    bool
  [pascal string] player_name   String  (u8 length prefix + UTF-8 bytes)
  [pascal string] ship_name     String  (e.g. "Yamato")
  [pascal string] scene_path    String  (e.g. "res://Ships/Yamato/Yamato.tscn")
  [1 byte]  gun_count     u8    number of Gun nodes on this ship
  [1 byte]  fire_count    u8    number of Fire zones on this ship
  [1 byte]  flood_count   u8    number of Flood zones on this ship
  [1 byte]  consumable_count u8 number of equipped consumable slots
  [per consumable slot — consumable_count entries]
    [1 byte] slot_id       u8
    [1 byte] type          u8    ConsumableItem.ConsumableType enum
    [pascal string] label  String  human-readable name
```

### 1.2 Event Stream

All events share the same 5-byte preamble:

```
[4 bytes] timestamp  f32   seconds since match start
[1 byte]  event_type u8    see enum below
[variable] payload        see per-event layout
```

#### Event Type Enum

```
MATCH_START       = 0x00   # payload: none (header already carries metadata)
MATCH_END         = 0x01   # payload: see below
SNAPSHOT          = 0x02   # payload: full per-ship state block
SHELL_FIRED       = 0x10   # payload: see below
SHELL_HIT         = 0x11   # payload: see below
TORPEDO_FIRED     = 0x20
TORPEDO_ARMED     = 0x21
TORPEDO_DETECTED  = 0x22
TORPEDO_DESTROYED = 0x23
FIRE_STARTED      = 0x30
FIRE_ENDED        = 0x31
FLOOD_STARTED     = 0x32
FLOOD_ENDED       = 0x33
CONSUMABLE_USED   = 0x40
CONSUMABLE_ENDED  = 0x41
DETECTION_CHANGED = 0x50
SHIP_SUNK         = 0x60
```

#### SNAPSHOT payload (every 0.2 s, ~5 Hz)

Written for ALL ships in ship_id order.

```
[per ship]
  [3×f32]  position        x, z, rotation_y   (y-pos is always near 0; skip it)
  [3×f32]  linear_velocity x, y, z
  [f32]    hp              current HP
  [u8]     flags           bit0=visible_to_enemy, bit1-2=detection_type(2 bits), bit3=is_sunk
  [i8]     throttle_level  -1 to 4
  [f32]    rudder_input    -1.0 to 1.0
  [3×f32]  aim_point       world-space aim target (artillery controller)
  [f32]    bloom_radius    concealment effective radius
  [u8]     shell_index     0=AP, 1=HE
  [u8]     fire_mask       bitmask of active fire zones (bit per zone, up to 8)
  [u8]     flood_mask      bitmask of active flood zones
  [u8]     consumable_mask bitmask of active consumables (bit per slot)
  [per gun — gun_count entries]
    [f32] turret_rot_y     local rotation.y
    [f32] barrel_rot_x     local rotation.x (elevation)
    [f32] reload           0.0–1.0
```

Estimated snapshot size for 24 ships with 4 guns each:
~(12+12+4+1+1+4+12+4+1+1+1+1 + 4×12) bytes × 24 = ~(54+48)×24 = **2,448 bytes/snapshot**
At 5 Hz: ~12 KB/s → **~14 MB for a 20-minute match**. Acceptable.

#### MATCH_END payload

```
[u8]   winning_team
[u16]  duration_seconds
[per ship — ship_count entries]
  [u8]   ship_id
  [f32]  total_damage
  [f32]  main_damage
  [f32]  torpedo_damage
  [f32]  fire_damage
  [f32]  flood_damage
  [u32]  frags
  [u32]  main_hits
  [u32]  citadel_count
  [u32]  penetration_count
  [u32]  overpen_count
```

#### SHELL_FIRED payload

```
[u8]   ship_id
[u8]   gun_index           which Gun node fired (index into ship.artillery_controller.guns)
[u8]   muzzle_index        which muzzle on the gun
[u8]   shell_type          0=AP, 1=HE
[3×f32] muzzle_position    world position
[3×f32] velocity           dispersed velocity vector (m/s)
[f32]  fire_timestamp      ProjectileManager.get_current_time() at fire
[f32]  drag                shell_params.drag (needed to re-simulate trajectory analytically)
[f32]  caliber             shell_params.caliber (for visual scale)
```

> **Why record velocity instead of aim_point?** Because dispersion means each
> shell's actual trajectory differs from the aim point. The velocity vector
> is the only way to replay the exact trajectory that hit (or missed).

#### SHELL_HIT payload

```
[u8]   attacker_ship_id
[u8]   victim_ship_id
[u8]   hit_type            ArmorInteraction.HitResult enum (0–6)
[u8]   is_secondary        bool
[f32]  damage
[3×f32] hit_position       world position of impact
```

#### TORPEDO_FIRED payload

```
[u8]   ship_id
[u8]   launcher_index
[u16]  torpedo_id          TorpedoManager assigned ID
[3×f32] start_position
[3×f32] direction          normalized
[f32]  fire_timestamp      from ProjectileManager.get_current_time()
[f32]  speed_knts          torpedo_params.speed_knts
[f32]  range_m             maximum range in metres
[f32]  detection_range     torpedo_params.detection_range
```

#### TORPEDO_ARMED payload
```
[u16]  torpedo_id
```

#### TORPEDO_DETECTED payload
```
[u16]  torpedo_id
```

#### TORPEDO_DESTROYED payload
```
[u16]  torpedo_id
[3×f32] position           world position at destruction
[u8]   hit_ship_id         0xFF = no hit (self-destruct/expired), else the victim ship_id
```

#### FIRE_STARTED / FIRE_ENDED payload
```
[u8]   ship_id
[u8]   zone_index          index into FireManager.fires array
[u8]   caused_by_ship_id   ship that caused it (0xFF if unknown/irrelevant for ENDED)
```

#### FLOOD_STARTED / FLOOD_ENDED payload
```
[u8]   ship_id
[u8]   zone_index
[u8]   caused_by_ship_id
```

#### CONSUMABLE_USED / CONSUMABLE_ENDED payload
```
[u8]   ship_id
[u8]   slot_id
```

#### DETECTION_CHANGED payload
```
[u8]   ship_id
[u8]   detection_type      Ship.detection_type enum: NONE=0, LOS=1, HYDRO=2, RADAR=3
[u8]   visible_to_enemy    bool
```

#### SHIP_SUNK payload
```
[u8]   victim_ship_id
[u8]   sinker_ship_id
[u8]   damage_type         HPManager.DAMAGE_TYPE enum
[3×f32] position           position at death
```

### 1.3 Index Block

Written at the very end, then the `index_offset` field in the header is
patched with `seek(8)` + `put_u32()`.

```
[u32]  snapshot_count
[per snapshot]
  [f32]  timestamp          seconds since match start
  [u64]  file_offset        byte position of the SNAPSHOT event (the 5-byte preamble)
```

---

## 2. Implementation Plan

### Phase 1 — Data Structures & Serialization Layer

**New file: `src/replay/replay_event.gd`**

- `class_name ReplayEvent`
- Inner class `ReplayHeader` with all header fields
- Inner class `ShipManifestEntry` (ship_id, team_id, is_bot, names, scene_path, gun_count, etc.)
- Constants for event type bytes (`SHELL_FIRED = 0x10`, etc.)
- Static helpers:
  - `write_vector3_xz(writer, v)` — writes x, z (skip y for positions)
  - `write_vector3_full(writer, v)` — writes x, y, z (for velocities)
  - `read_vector3_xz(reader) -> Vector3`
  - `read_vector3_full(reader) -> Vector3`
  - `write_string(writer, s)` — u8 length prefix + UTF-8
  - `read_string(reader) -> String`

**No Godot scene needed.** This is a pure data/logic script.

---

### Phase 2 — ReplayRecorder (server-side)

**New file: `src/replay/replay_recorder.gd`**

- `class_name ReplayRecorder extends Node`
- Registered as an autoload in `project.godot` **but only active on the server**:
  - In `_ready()`: `if not _Utils.authority(): set_process(false); return`

#### State

```gdscript
var _file: FileAccess = null
var _writer: StreamPeerBuffer
var _snapshot_timer: float = 0.0
const SNAPSHOT_INTERVAL: float = 0.2  # 5 Hz

var _match_start_time: float = 0.0
var _match_active: bool = false

# Ship registry built at match start
var _ships: Array[Ship] = []         # index = ship_id
var _ship_to_id: Dictionary = {}     # Ship -> u8

# Snapshot index (built in memory, written at EOF)
var _snapshot_index: Array = []      # Array of {timestamp: float, offset: int}
```

#### Key Methods

**`begin_match(ships: Array[Ship], map_id: int)`**
- Called from `GameServer.spawn_player()` once `all_players_spawned` is true
- Opens `user://replays/<unix_ts>_<map>.replay`
- Writes magic, version, placeholder index_offset (0)
- Builds `_ship_to_id` dictionary
- Writes ship manifest header
- Emits `MATCH_START` event
- Sets `_match_active = true`

**`_physics_process(delta)`**
- Guards: `if not _match_active: return`
- Advances `_snapshot_timer += delta`
- When `_snapshot_timer >= SNAPSHOT_INTERVAL`: calls `_write_snapshot()`, resets timer

**`_write_snapshot()`**
- Records current `_file.get_position()` → appends to `_snapshot_index`
- Writes preamble (timestamp, `SNAPSHOT`)
- For each ship in `_ships`: writes all snapshot fields (position, rotation, velocity,
  hp, flags, throttle, rudder, aim_point, bloom_radius, shell_index, fire_mask,
  flood_mask, consumable_mask, per-gun state)

**`record_shell_fired(ship, gun_index, muzzle_index, muzzle_pos, velocity, fire_ts, shell_params)`**
- Called directly from `Gun.fire()` (add a call there)
- Writes `SHELL_FIRED` event

**`record_shell_hit(attacker, victim, hit_type, is_secondary, damage, position)`**
- Called from `Stats.record_hit()` (add a call there — before `damage_events.clear()`)
- Writes `SHELL_HIT` event

**`record_torpedo_fired(ship, launcher_index, torpedo_id, start_pos, direction, fire_ts, params)`**
- Called from `TorpedoManager.fireTorpedo()` after ID assignment
- Writes `TORPEDO_FIRED` event

**`record_torpedo_armed(torpedo_id)`** — called from `TorpedoManager._arm_torp()`
**`record_torpedo_detected(torpedo_id)`** — called from `TorpedoManager` detection path
**`record_torpedo_destroyed(torpedo_id, position, hit_ship)`**
- Called from `TorpedoManager.destroyTorpedo()`

**`record_fire_started/ended(ship, zone_index, caused_by)`**
- Connected to `Fire._sync_activate` / `_sync_deactivate` (or called directly from
  `Fire._apply_build_up` and `Fire.extinguish`)

**`record_flood_started/ended(ship, zone_index, caused_by)`** — same pattern

**`record_consumable_used(ship, slot_id)`**
- Connected to `ConsumableManager.consumable_used` signal
- `ConsumableManager.consumable_ready` → `record_consumable_ended`

**`record_detection_changed(ship, detection_type, visible_to_enemy)`**
- Called from `GameServer._physics_process` when detection state changes for a ship
  (compare current vs previous detection_type, emit only on change)

**`record_ship_sunk(victim, sinker, damage_type)`**
- Connected to `_Utils.kill_feed_event` signal

**`end_match(winning_team, duration_secs)`**
- Connected to `_Utils.match_ended` signal
- Writes `MATCH_END` event with full stats
- Writes snapshot index block at EOF
- Patches `index_offset` field in header: `_file.seek(8)` → `put_32(index_offset)`
- Closes file
- Sets `_match_active = false`

#### Hook Points in Existing Code

| Existing location | What to add |
|---|---|
| `Gun.fire()` after `ProjectileManager.fireBullet()` | `ReplayRecorder.record_shell_fired(...)` |
| `Stats.record_hit()` before return | `ReplayRecorder.record_shell_hit(...)` if server |
| `TorpedoManager.fireTorpedo()` after ID assigned | `ReplayRecorder.record_torpedo_fired(...)` |
| `TorpedoManager.destroyTorpedo()` | `ReplayRecorder.record_torpedo_destroyed(...)` |
| `TorpedoManager._notify_armed()` or `_arm_torp` path | `ReplayRecorder.record_torpedo_armed(...)` |
| `Fire._apply_build_up()` after `lifetime = 1` | `ReplayRecorder.record_fire_started(...)` |
| `Fire.extinguish()` (or `_sync_deactivate`) | `ReplayRecorder.record_fire_ended(...)` |
| `Flood._apply_build_up()` after ignition | `ReplayRecorder.record_flood_started(...)` |
| `Flood.extinguish()` | `ReplayRecorder.record_flood_ended(...)` |
| `ConsumableManager.consumable_used` signal | `ReplayRecorder.record_consumable_used(...)` |
| `ConsumableManager.consumable_ready` signal | `ReplayRecorder.record_consumable_ended(...)` |
| `_Utils.kill_feed_event` signal | `ReplayRecorder.record_ship_sunk(...)` |
| `_Utils.match_ended` signal | `ReplayRecorder.end_match(...)` |
| `GameServer` once all players spawned | `ReplayRecorder.begin_match(...)` |
| `GameServer._physics_process` detection loop | `ReplayRecorder.record_detection_changed(...)` (on change only) |

---

### Phase 3 — ReplayFileReader

**New file: `src/replay/replay_file_reader.gd`**

- `class_name ReplayFileReader`
- Loads a `.replay` file fully into memory as `PackedByteArray`
- Uses a `StreamPeerBuffer` for sequential reading
- Parses and exposes:
  - `header: ReplayHeader`
  - `ships: Array[ReplayEvent.ShipManifestEntry]`
  - `snapshot_index: Array[Dictionary]`  → `[{timestamp, offset}, ...]`
  - `total_duration: float`
  - `winning_team: int`
  - `end_stats: Dictionary`  → ship_id → stats dict

**`load_file(path: String) -> Error`**
- Reads magic, validates version
- Parses header and manifest
- Jumps to `index_offset`, parses snapshot index
- Returns `OK` or an error code

**`read_events_in_range(t_start: float, t_end: float) -> Array`**
- Binary searches `snapshot_index` for the last snapshot ≤ `t_start`
- Seeks to that offset, reads events until `timestamp > t_end`
- Returns array of parsed event dictionaries

**`read_snapshot_at(t: float) -> Dictionary`**
- Returns the snapshot at or just before time `t` (full ship state for all ships)
- Used for instantaneous scrubbing

**`get_next_snapshot(t: float) -> Dictionary`**
- Returns the snapshot just after time `t` (for interpolation)

---

### Phase 4 — GhostShip

**New file: `src/replay/ghost_ship.gd`**

- `class_name GhostShip extends Node3D`
- Visual-only representation of a ship during replay
- **No `RigidBody3D`, no physics**, no network, no child modules
- Holds a reference to the actual ship scene for its model mesh

**State:**
```gdscript
var ship_entry: ReplayEvent.ShipManifestEntry
var current_hp: float
var max_hp: float
var team_id: int
var detection_type: int
var is_sunk: bool

# Interpolation targets
var _pos_from: Vector3
var _pos_to: Vector3
var _rot_from: float
var _rot_to: float
var _interp_t: float = 0.0

# Child references
var _model: Node3D           # The ship .glb model
var _hp_bar: Control         # Floating HP bar (projected to screen)
var _name_label: Label3D     # Ship name tag
var _detection_ring: MeshInstance3D  # Optional concealment radius ring
var _gun_nodes: Array[Node3D]  # Turret nodes for rotation
var _fire_particles: Array[Node3D]
var _flood_particles: Array[Node3D]
```

**`setup(entry: ReplayEvent.ShipManifestEntry)`**
- Loads `entry.scene_path` and adds the visual model as a child (or just the mesh)
- Initializes HP bar, name label, gun references

**`apply_snapshot(snap_data: Dictionary)`**
- Immediately sets position, rotation, HP, detection flags, gun rotations, etc.
- Sets `_pos_from = _pos_to = current position` (resets interpolation)

**`set_interpolation_targets(snap_from: Dictionary, snap_to: Dictionary)`**
- Sets `_pos_from`, `_pos_to`, `_rot_from`, `_rot_to`
- Resets `_interp_t = 0.0`

**`_process(delta)` / `advance_interpolation(alpha: float)`**
- Lerps position and heading between the two snapshots using `alpha`
- Called by `ReplayPlayback` with the current normalized time between snapshots

**`set_active_fires(mask: int)` / `set_active_floods(mask: int)`**
- Shows/hides particle systems

**`set_sunk(sinking_basis: Basis)`**
- Plays sinking animation (tilt + sink below water)

---

### Phase 5 — ShellReplayer & TorpedoReplayer

**New file: `src/replay/shell_replayer.gd`**

- `class_name ShellReplayer extends Node3D`
- Manages visual shell trails during replay
- Uses the same `GPUProjectileRenderer` approach (or falls back to `ImmediateMesh` trails)

**`spawn_shell(event: Dictionary, current_replay_time: float)`**
- Creates a shell visual given the SHELL_FIRED event data
- Since trajectory is **fully analytical** (position = f(muzzle_pos, velocity, drag, t)),
  the shell position at any replay time `t_replay` is:
  ```gdscript
  var t_flight = t_replay - event.fire_timestamp
  var pos = ReplayBallistics.position_at(
      event.muzzle_position, event.velocity, event.drag, t_flight
  )
  ```
- Reuses `GDProjectilePhysicsWithDrag` (already in `analytical_projectile_system.gd`)
  by passing replay time instead of real time

**`update_shells(current_time: float)`**
- Called each frame by `ReplayPlayback`
- For each active shell: computes current position analytically, moves the visual
- Removes shells past their expected flight time (estimated from velocity and range)

**New file: `src/replay/torpedo_replayer.gd`**

- Same pattern; torpedoes are even simpler (pure linear):
  ```gdscript
  var t_flight = (current_time - event.fire_timestamp) * TORPEDO_SPEED_MULTIPLIER
  var pos = event.direction * event.params.speed * t_flight + event.start_position
  pos.y = max(pos.y - t_flight * 10, 0.1)
  ```
- Shows detection cone when `TORPEDO_DETECTED` event fires
- Shows explosion effect on `TORPEDO_DESTROYED`

**New file: `src/replay/replay_ballistics.gd`** (pure static helpers)
- `static func position_at(muzzle: Vector3, vel: Vector3, drag: float, t: float) -> Vector3`
  — wraps `GDProjectilePhysicsWithDrag` or reimplements the analytical formula
  (already exists in `analytical_projectile_system.gd`)

---

### Phase 6 — ReplayPlayback Engine

**New file: `src/replay/replay_playback.gd`**

- `class_name ReplayPlayback extends Node`
- The central time-keeper and state machine

**State:**
```gdscript
var reader: ReplayFileReader
var ghost_ships: Array[GhostShip] = []
var shell_replayer: ShellReplayer
var torpedo_replayer: TorpedoReplayer

var current_time: float = 0.0
var is_playing: bool = false
var playback_speed: float = 1.0  # 0.25, 0.5, 1.0, 2.0, 4.0, 8.0

var _snap_a: Dictionary = {}    # last snapshot data
var _snap_b: Dictionary = {}    # next snapshot data
var _snap_a_time: float = 0.0
var _snap_b_time: float = 0.0

# Pending events queue (events between snap_a and current_time that haven't fired yet)
var _pending_events: Array[Dictionary] = []

# Signal for UI
signal time_changed(new_time: float)
signal event_fired(event: Dictionary)
signal playback_ended()
```

**`load_replay(path: String) -> Error`**
- Calls `reader.load_file(path)`
- Instantiates `GhostShip` for each ship in `reader.ships`
- Seeks to time 0, initializes `_snap_a` and `_snap_b`

**`seek(t: float)`**
- Clamps `t` to `[0, reader.total_duration]`
- Binary searches `reader.snapshot_index` for last snapshot ≤ `t`
- Reads that snapshot → applies to all `GhostShip` nodes immediately
- Reads next snapshot → sets interpolation targets
- Re-queues pending events from `t` to `_snap_b_time`
- Clears all active shells/torpedoes and re-spawns any that were in-flight at `t`
  (iterate `reader.read_events_in_range(t - MAX_SHELL_FLIGHT_TIME, t)`,
   spawn shells that haven't hit yet)
- Emits `time_changed(t)`

**`_process(delta)`**
- If `not is_playing: return`
- Advances `current_time += delta * playback_speed`
- If `current_time >= _snap_b_time`:
  - Applies `_snap_b` → all ghost ships
  - Reads next snapshot pair
  - If no more snapshots: `is_playing = false; emit_signal("playback_ended")`
- Fires any `_pending_events` with `timestamp <= current_time`
- Computes interpolation alpha: `(current_time - _snap_a_time) / (_snap_b_time - _snap_a_time)`
- Calls `ghost_ship.advance_interpolation(alpha)` for each ship
- Updates shells and torpedoes: `shell_replayer.update_shells(current_time)`

**`set_speed(s: float)`** — sets `playback_speed`
**`play()` / `pause()`** — toggle `is_playing`

---

### Phase 7 — Viewer Scene

**New scene: `src/replay/match_replay.tscn`**

Structure mirrors `shell_replay.tscn` but expands it to a full match:

```
match_replay.tscn (Node)
├─ CanvasLayer
│   ├─ ReplayViewerUI (Control, full-rect)
│   │   ├─ TopBar (HBoxContainer)
│   │   │   ├─ BackButton
│   │   │   ├─ MatchInfoLabel
│   │   │   └─ CameraControls (orbit/follow dropdown)
│   │   ├─ SidePanel (PanelContainer, left)
│   │   │   ├─ KillFeed (VBoxContainer)
│   │   │   └─ EventLog (ItemList, optional)
│   │   └─ BottomBar (PanelContainer)
│   │       ├─ PlayPauseButton
│   │       ├─ SpeedButtons (HBoxContainer: 0.25x 0.5x 1x 2x 4x 8x)
│   │       ├─ TimeLabel (current / total)
│   │       └─ Scrubber (HSlider)
│   │           └─ [EventMarkers drawn via _draw() overlay]
└─ SubViewportContainer (full-rect or right portion)
    └─ SubViewport
        └─ World3D (Node3D)
            ├─ Map (loaded at runtime from map_id)
            ├─ DirectionalLight3D
            ├─ GhostShipsRoot (Node3D) — GhostShip children added here
            ├─ ShellReplayer
            ├─ TorpedoReplayer
            └─ ReplayCamera (Camera3D)
                └─ OrbitCameraController (adapts OrbitCamera from port)
```

**New script: `src/replay/match_replay.gd`**

- `extends Node`
- Owns `ReplayPlayback`
- On `_ready()`:
  - Reads selected replay path from `_Utils.pending_replay_path`
    (a new field added to `_Utils`, set by the file browser)
  - Calls `playback.load_replay(path)`
  - Adds all ghost ships to `World3D/GhostShipsRoot`
  - Loads the correct map scene
  - Connects `playback.time_changed` → `scrubber.value = t`
  - Connects `playback.event_fired` → `_on_event(event)`
  - Calls `playback.play()`
- `_on_scrubber_changed(value)` → `playback.seek(value * total_duration)` (if user dragged)
- `_on_back_pressed()` → `get_tree().change_scene_to_file("res://src/port/main_menu/main_menu.tscn")`

#### Camera Controller for Replay

Reuse `OrbitCamera` from `src/port/main_menu/orbit_camera.gd` as-is for free orbit.
Add a "follow ship" mode:

```gdscript
var follow_target: GhostShip = null

func _process(delta):
    if follow_target:
        # Spherical coord follow, same logic as ThirdPersonViewV2 but reading
        # follow_target.global_position directly (no physics RigidBody needed)
        ...
    else:
        # existing orbit logic
```

Ship dropdown in `TopBar` → selecting a ship sets `follow_target`.

---

### Phase 8 — Replay File Browser

**New scene: `src/replay/replay_browser.tscn`**

A simple list overlay shown as a full-screen panel when "Match Replays" is clicked
from the port main menu.

**Script: `src/replay/replay_browser.gd`**

- Scans `user://replays/` directory with `DirAccess`
- For each `.replay` file: reads only the header (first ~N bytes) to extract
  date, map, ship count, duration preview
- Populates an `ItemList` with one entry per replay
- "Play" button → sets `_Utils.pending_replay_path`, then
  `get_tree().change_scene_to_file("res://src/replay/match_replay.tscn")`
- "Delete" button → removes the file, refreshes list
- "Back" button → returns to `main_menu.tscn`

---

### Phase 9 — Port Integration

**Edit: `src/port/main_menu/main_menu_ui.gd`**

Add a "Match Replays" button alongside the existing "Replay" (shell debug) button:
```gdscript
func _on_match_replays_pressed():
    get_tree().change_scene_to_file("res://src/replay/replay_browser.tscn")
```

**Edit: `src/utils/utils.gd`**

Add one field:
```gdscript
var pending_replay_path: String = ""
```

**Edit: `project.godot`**

Register `ReplayRecorder` as an autoload:
```
[autoload]
...
ReplayRecorder="*res://src/replay/replay_recorder.gd"
```

---

## 3. Viewer UI Details

### Scrubber

- `HSlider` with `min_value=0`, `max_value=1.0` (normalized), `step=0.001`
- Overlay `Control` node drawn on top using `_draw()` to paint event markers:
  - Red triangles at `SHIP_SUNK` timestamps
  - Yellow diamonds at `TORPEDO_FIRED` timestamps
  - White circles at `SHELL_HIT` (citadel) timestamps
- While playback is active: scrubber updates from `playback.time_changed` signal
- While user drags: disconnect signal, reconnect on mouse release

### Speed Controls

Seven `Button` nodes in an `HBoxContainer`:
- Labels: `0.25×`, `0.5×`, `1×`, `2×`, `4×`, `8×`
- Pressing one calls `playback.set_speed(v)` and toggles visual active state

### Kill Feed

- `VBoxContainer` with up to 6 children
- On `SHIP_SUNK` event: prepend a `PanelContainer` with
  `[sinker_name] ⚓ [victim_name]` layout, tween opacity out after 10 seconds
- Matches the existing `kill_feed.gd` pattern from `src/ui/`

### HP Bars

- Each `GhostShip` owns a `Control` node projected to screen via
  `camera.unproject_position(ghost_ship.global_position + Vector3.UP * 20)`
- Bar changes color from green → yellow → red based on HP fraction
- Hidden for sunk ships

### Detection Indicators

- `Label3D` on each `GhostShip` displaying detection type icon (`👁` LOS, `〰` Hydro, `📡` Radar)
- Optional wireframe ring mesh showing `bloom_radius` (toggle button in TopBar)

---

## 4. File Layout (New Files to Create)

```
src/replay/
├─ replay_event.gd          Phase 1 — Data structures, constants, serialization helpers
├─ replay_recorder.gd       Phase 2 — Server-side recorder (autoload)
├─ replay_file_reader.gd    Phase 3 — File loader + snapshot index
├─ ghost_ship.gd            Phase 4 — Visual-only ship node
├─ replay_ballistics.gd     Phase 5 — Static shell/torpedo position helpers
├─ shell_replayer.gd        Phase 5 — Manages live shell visuals during replay
├─ torpedo_replayer.gd      Phase 5 — Manages live torpedo visuals during replay
├─ replay_playback.gd       Phase 6 — Time engine: play/pause/seek/speed
├─ match_replay.gd          Phase 7 — Root controller for the viewer scene
├─ match_replay.tscn        Phase 7 — Viewer scene
├─ replay_browser.gd        Phase 8 — File picker
└─ replay_browser.tscn      Phase 8 — File picker scene
```

Replay files saved to:
```
user://replays/<unix_timestamp>_<map_name>.replay
```

---

## 5. Existing Files to Edit

| File | Change |
|---|---|
| `src/artillary/Guns/Gun.gd` | Call `ReplayRecorder.record_shell_fired()` in `fire()` |
| `src/stats/stats.gd` | Call `ReplayRecorder.record_shell_hit()` in `record_hit()` |
| `src/torpedo/torpedo_manager.gd` | Call `ReplayRecorder.record_torpedo_*()` in `fireTorpedo()`, `destroyTorpedo()`, detection |
| `src/Fire/fire.gd` | Call `ReplayRecorder.record_fire_started/ended()` |
| `src/Flood/flood.gd` | Call `ReplayRecorder.record_flood_started/ended()` |
| `src/Consumable/consumable_manager.gd` | Connect signals to recorder |
| `src/utils/utils.gd` | Add `pending_replay_path: String` field |
| `src/server/server.gd` | Call `ReplayRecorder.begin_match()` and connect `_Utils.match_ended` |
| `src/port/main_menu/main_menu_ui.gd` | Add "Match Replays" button |
| `project.godot` | Register `ReplayRecorder` autoload |

---

## 6. Key Design Decisions

### Why Binary (not JSON)?
- `StreamPeerBuffer` is already the universal serialization tool in this codebase
  (every subsystem has `to_bytes()`/`from_bytes()`)
- Binary is ~5–10× smaller and faster to read/write than JSON for the same data
- The index-at-EOF pattern enables O(log n) scrubbing without loading the whole file

### Why 5 Hz snapshots?
- Below 5 Hz, linear interpolation of ship movement looks jerky (ships can turn
  significantly in 0.2 s at high rudder)
- Above 5 Hz, file size grows proportionally with no playback quality gain
  (the viewer interpolates between snapshots anyway)
- At 5 Hz: ~14 MB for 20 minutes — fits on any drive, loads in <1 second

### Why record per-shell velocity instead of reconstructing from aim_point + dispersion?
- Dispersion uses a random seed that is not recorded
- The velocity vector is the only ground-truth record of where that shell actually went
- It is already computed in `Gun.fire()` and passed to `ProjectileManager.fireBullet()`

### Why record aim_point in snapshots even though we have per-gun rotation?
- The aim_point is what the ship is *trying to hit* — it changes continuously
  and drives all gun rotations
- Recording it allows the viewer to draw a "where is this ship aiming?" indicator
  without having to reverse-engineer it from gun angles

### Why separate ShellReplayer/TorpedoReplayer from GhostShip?
- Shells and torpedoes are not owned by a single ship once fired; they have
  independent lifecycles
- A single `ShellReplayer` managing all in-flight shells is simpler than
  distributing responsibility across 24 `GhostShip` nodes

### GhostShip uses the real ship scenes
- Load the same `.tscn` scenes but skip all physics, modules, and network nodes
  by calling `set_process(false)` and `set_physics_process(false)` recursively
  after instantiation, or by loading only the visual mesh child
- The exact turret rotation meshes are already part of the ship scene so gun
  rotations from snapshots will visually play back correctly

---

## 7. Out of Scope (Future Work)

- Secondary battery shell visualization (secondaries fire very rapidly; worth a
  separate SECONDARY_FIRED event type using the same SHELL_FIRED layout with a flag)
- Smoke screen visualization (would need a SMOKE_DEPLOYED event with position +
  radius + lifetime)
- Damage control particle effects (fire suppression animation)
- Audio playback (gun sounds synced to SHELL_FIRED events)
- Multiplayer co-spectating (share replay file over network, sync scrubber)
- Replay compression (zstd or similar on the raw bytes; trivial to add later)
- Export to video

---

## 8. Implementation Order (Recommended)

1. **`replay_event.gd`** — no dependencies, pure data
2. **`replay_recorder.gd`** + hook into `Gun.fire()` only → verify file is written
3. Add remaining hooks (`Stats`, `TorpedoManager`, `Fire`, `Flood`, `ConsumableManager`,
   `_Utils` signals, `server.gd` begin/end)
4. **`replay_file_reader.gd`** — test by loading and printing header + event counts
5. **`ghost_ship.gd`** — test standalone: load one ship scene, feed it snapshot data
6. **`replay_ballistics.gd`** + **`shell_replayer.gd`** + **`torpedo_replayer.gd`**
7. **`replay_playback.gd`** — unit-test with dummy data before connecting to scene
8. **`match_replay.tscn`** + **`match_replay.gd`** — wire everything together
9. **`replay_browser.tscn`** + **`replay_browser.gd`** — file picker
10. Port integration edits (`main_menu_ui.gd`, `utils.gd`, `project.godot`)
