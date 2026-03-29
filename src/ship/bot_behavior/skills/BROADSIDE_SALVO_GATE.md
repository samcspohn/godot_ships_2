# Broadside Salvo Gate — Implementation Plan

## Overview

The broadside post-processor (`SkillBroadside`) currently oscillates the ship's
heading between an angled stance and a broadside (all-guns-bearing) stance on a
reload-timed cycle, gated only by whether the turrets have traversed toward the
threat.

This document describes a second gate: **only allow the broadside swing when the
most dangerous enemy's salvo has just splashed**, exploiting the enemy's reload
window to safely unmask all guns without exposing the ship's broadside to
incoming fire.

---

## Rationale

A skilled player intuitively:

1. Angles armor while enemy shells are in the air or the enemy is about to fire.
2. Watches for the enemy salvo to land (splash).
3. Swings to broadside during the reload window to fire a full salvo.
4. Returns to an angled stance before the next enemy salvo arrives.

This mirrors real gameplay knowledge — players know roughly how long each ship
class takes to reload (BB ~25-30s, CA ~10-15s, DD ~5-8s) and time their
broadsides accordingly.

---

## Existing Shell Tracking API

### ProjectileManager (C++ autoload singleton)

Shells are registered on fire with pre-computed landing positions:

```
struct ShellLandingEntry {
    int   shell_id;
    float landing_x, landing_z;    // predicted world XZ impact
    float time_to_impact;          // total flight time (shell-time units)
    float fire_time;               // timestamp when fired
    float caliber;                 // mm
    int   team_id;                 // firing team
};
```

Query method (callable from GDScript):

```
ProjectileManager.get_shells_near_position(
    position: Vector2,     # XZ world position to query around
    radius: float,         # search radius (meters)
    exclude_team_id: int   # filter out own-team shells
) -> Array[Dictionary]
```

Each returned dictionary:

| Key              | Type  | Description                              |
|------------------|-------|------------------------------------------|
| `shell_id`       | int   | unique shell identifier                  |
| `landing_x`      | float | predicted impact X                       |
| `landing_z`      | float | predicted impact Z                       |
| `time_remaining` | float | real seconds until splash (updates live) |
| `caliber`        | float | shell caliber in mm                      |

Shells with `time_remaining <= 0` are automatically excluded (already splashed).

### BotControllerV4 (GDScript, per-ship)

Already polls `ProjectileManager` every few physics frames (staggered per bot):

```
const SHELL_QUERY_RANGE: float = 1000.0

func _update_shell_threats() -> void:
    navigator.clear_incoming_shells()
    var shells: Array = ProjectileManager.get_shells_near_position(
        my_pos_2d, SHELL_QUERY_RANGE, my_team_id
    )
    _debug_shell_obstacles = shells
    for s in shells:
        navigator.add_incoming_shell(s["shell_id"], ...)
```

The `_debug_shell_obstacles` array is accessible via `get_debug_shell_obstacles()`.

### ShipNavigator (C++ GDExtension, per-ship)

Stores `incoming_shells_: vector<IncomingShell>` and uses them to penalize
steering arcs that lead into predicted shell landing zones. This is the
**evasion** layer — it steers away from incoming fire. The broadside gate is
a **behavior** layer concern and does not need to modify the navigator.

---

## Enemy Reload Time

Accessible via any enemy ship reference:

```
enemy.artillery_controller.get_params().reload_time  # float, seconds
```

This is on `GunParams` (extends `TurretParams`). It represents the full reload
cycle. A real player can intuit this from game knowledge, so reading it is fair.

---

## Design

### New State: `_salvo_window` tracker on `SkillBroadside`

Add lightweight state to `SkillBroadside` that tracks whether the ship is in a
safe broadside window.

#### State Variables

```
## Timestamp of the last detected enemy salvo splash near this ship.
var _last_splash_time: float = 0.0

## Whether we are currently in a safe broadside window.
var _in_salvo_window: bool = false

## Cached: the reload time of the most dangerous nearby enemy.
var _enemy_reload_time: float = 30.0

## Cached: estimated shell flight time from the most dangerous enemy.
var _enemy_flight_time: float = 5.0

## Set of shell IDs we were tracking last frame (to detect splashes).
var _tracked_shell_ids: Dictionary = {}  # shell_id -> true
```

#### Detection Logic: `_update_salvo_window()`

Called each frame inside `apply()`, before the blend calculation.

```
func _update_salvo_window(ship: Ship, ctx: SkillContext) -> void:
    var now: float = Time.get_ticks_msec() / 1000.0
    var my_team_id: int = ship.team.team_id
    var my_pos_2d := Vector2(ship.global_position.x, ship.global_position.z)

    # --- Query incoming shells near this ship ---
    var shells: Array = ProjectileManager.get_shells_near_position(
        my_pos_2d, 1000.0, my_team_id
    )

    # --- Detect splash: shells we were tracking that are no longer in the list ---
    var current_ids: Dictionary = {}
    for s in shells:
        current_ids[s["shell_id"]] = true

    var splash_detected: bool = false
    for old_id in _tracked_shell_ids:
        if not current_ids.has(old_id):
            splash_detected = true
            break

    _tracked_shell_ids = current_ids

    # --- Update most dangerous enemy's reload & flight time ---
    _update_enemy_timing(ship, ctx)

    # --- Window logic ---
    if splash_detected:
        _last_splash_time = now
        _in_salvo_window = true

    if _in_salvo_window:
        var time_since_splash: float = now - _last_splash_time
        # Close the window before the next salvo arrives.
        # Safe duration = enemy_reload_time - enemy_flight_time
        # (need to be back to angled before shells are in the air again)
        var safe_duration: float = maxf(_enemy_reload_time - _enemy_flight_time, 0.0)
        # Add a safety margin — start closing up 2s early
        safe_duration = maxf(safe_duration - 2.0, 0.0)
        if time_since_splash >= safe_duration:
            _in_salvo_window = false
```

#### Enemy Timing: `_update_enemy_timing()`

Find the most dangerous enemy (highest caliber, closest) and cache their reload
time and estimated flight time.

```
func _update_enemy_timing(ship: Ship, ctx: SkillContext) -> void:
    var best_threat_weight: float = 0.0
    var server = ctx.server
    if server == null:
        return

    for enemy in server.get_valid_targets(ship.team.team_id):
        if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
            continue
        var dist: float = ship.global_position.distance_to(enemy.global_position)
        var enemy_range: float = enemy.artillery_controller.get_params()._range
        if dist > enemy_range:
            continue

        # Weight: closer + larger caliber = more dangerous
        var range_weight: float = 1.0 - clampf(dist / enemy_range, 0.0, 1.0)
        var reload: float = enemy.artillery_controller.get_params().reload_time
        # Shorter reload = more dangerous (less window)
        var reload_weight: float = 30.0 / maxf(reload, 1.0)
        var weight: float = range_weight * reload_weight

        if weight > best_threat_weight:
            best_threat_weight = weight
            _enemy_reload_time = reload

            # Estimate flight time from shell speed and distance.
            # Rough approximation: flight_time ≈ dist / shell_speed
            # (drag makes it longer, but this is conservative — better to
            #  close the window slightly early than too late)
            var shell_params = enemy.artillery_controller.get_shell_params()
            if shell_params != null:
                _enemy_flight_time = clampf(dist / maxf(shell_params.speed, 1.0), 1.0, 15.0)
            else:
                _enemy_flight_time = 5.0
```

### Integration into `apply()`

The salvo window gate stacks with the existing gun-aimed gate. Both must be true
for the broadside blend to be non-zero:

```
# Current code:
if blend > 0.001:
    var ship_heading: float = ctx.behavior._get_ship_heading()
    if not _guns_aimed_toward_broadside(guns, ship_heading, ...):
        blend = 0.0

# Add after:
if blend > 0.001:
    if not _in_salvo_window:
        blend = 0.0
```

The `_update_salvo_window()` call goes at the top of `apply()`, right after the
early-exit checks and before the oscillation math.

### Gate Ordering

Both gates must pass for broadside oscillation:

1. **Oscillation timer** produces `blend > 0` (reload-timed sinusoid)
2. **Gun-aimed gate** — turrets have traversed toward the threat
3. **Salvo window gate** — enemy shells just splashed, we're in the reload gap

If either gate fails, `blend = 0.0` and the ship holds its angled heading.

### Reset

Add to `reset()`:

```
func reset() -> void:
    _osc_timer = 0.0
    _last_splash_time = 0.0
    _in_salvo_window = false
    _tracked_shell_ids.clear()
```

---

## Window Timing Diagram

```
Enemy fires        Shells in air       Shells splash       Enemy reloads         Enemy fires again
    |──── flight_time ────|                  |──── reload_time ────────────────────────|
                                             |                                        |
                                             |◄── safe_duration (reload - flight - 2s margin) ──►|
                                             |                                        |
                              ANGLED ────────|── BROADSIDE ALLOWED ──|── ANGLED ──────|
```

At close range, `flight_time` is short but the window is the same
(`reload_time - flight_time`). The 2s safety margin accounts for:
- The ship's turning time to get back to angled
- Slight inaccuracies in flight time estimation

At very close range where `reload_time - flight_time - 2s <= 0`, the window
never opens — the ship stays permanently angled. This is correct behavior:
at point-blank range you should never show broadside.

---

## Edge Cases

### No enemy shells detected yet
`_in_salvo_window` starts `false`. The ship stays angled until the first enemy
salvo splashes. This is conservative but safe — the ship won't show broadside
until it has timing information.

**Alternative:** Could default `_in_salvo_window = true` for the first few
seconds of engagement so the ship can fire initially. Or gate this entire
feature behind "has enemy fired at me at least once" — if no shells have been
tracked yet, fall back to the existing oscillation-only behavior.

### Multiple enemies
`_update_enemy_timing()` tracks the **most dangerous** enemy (shortest effective
window). The ship times its broadside to the tightest constraint. If a BB and a
DD are both shooting, the DD's faster reload dominates — the window is shorter.

This is conservative. A more aggressive version could track per-enemy salvos and
only require the heaviest-caliber enemy's salvo to have splashed (since DD shells
don't punish broadside much). Left as a future refinement.

### Enemy stops firing
If the enemy hasn't fired in a while, no new splashes are detected, and
`_in_salvo_window` stays `false`. The ship remains angled. This is acceptable —
if no one is shooting at you, angling isn't costly.

**Alternative:** Could add a timeout (e.g., if no shells tracked for
`2 × enemy_reload_time`, assume safe and open window). This handles enemies that
are reloading but haven't fired yet.

### Shell tracking polling rate
`ProjectileManager.get_shells_near_position()` returns shells with
`time_remaining > 0`. Splash detection works by noticing shell IDs disappear
from the query results between frames. Since `apply()` runs every physics frame
(~60Hz), the detection latency is at most ~16ms — negligible.

Note: The bot controller's own shell query (`_update_shell_threats`) runs on a
staggered schedule (every `OBSTACLE_UPDATE_INTERVAL = 4` frames). The broadside
skill queries `ProjectileManager` independently, so it doesn't share this
stagger. If performance is a concern, could align to the same schedule, but the
query is spatial-grid-based and fast.

---

## Performance Notes

- `get_shells_near_position()` uses a 500m-cell spatial grid — O(1) cell lookup,
  iterates only shells in nearby cells. Very fast even with many shells in flight.
- `_update_enemy_timing()` iterates `get_valid_targets()` — same list the
  behavior already iterates for other purposes. Could cache if needed.
- Dictionary-based `_tracked_shell_ids` for splash detection is O(n) where n is
  shells near the ship (typically 0-20). Negligible cost.

---

## Files to Modify

| File | Change |
|------|--------|
| `skills/skill_broadside.gd` | Add `_update_salvo_window()`, `_update_enemy_timing()`, state vars, gate in `apply()` |

No other files need changes — the gate is entirely internal to `SkillBroadside`.
The `ProjectileManager` singleton is already available globally.

---

## Testing Checklist

- [ ] Ship stays angled while enemy shells are in the air
- [ ] Ship swings to broadside within 1-2s of enemy salvo splashing
- [ ] Ship returns to angled before next enemy salvo arrives
- [ ] Window duration scales with enemy reload time (longer for BBs, shorter for DDs)
- [ ] At very close range (window <= 0), ship never shows broadside
- [ ] Multiple enemies: window tracks the most dangerous (tightest timing)
- [ ] No shells fired at ship: ship stays angled (conservative default)
- [ ] Gun-aimed gate still works — broadside only if turrets are ready AND window is open
- [ ] `reset()` clears all salvo tracking state