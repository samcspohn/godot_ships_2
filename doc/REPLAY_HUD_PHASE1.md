# Replay HUD — Phase 1

## Goal

Bring the in-game HUD's *visible* feel into match replay (`src/replay/match_replay.tscn`)
**without** refactoring `src/ui/camera_ui_scene.gd` and **without** changing the
replay file format.

Phase 1 is purely additive: we build a new, smaller `ReplayHUD` scene that reuses
already-self-contained widgets (`KillFeed`, `HitStatCounters`, `Minimap`) and
draws the rest from data already present in the replay format.

The existing replay controls (top bar, scrubber, speed, follow dropdown) stay
where they are. Phase 1 is layered *underneath* those controls.

---

## Inventory of what we already have

### Per-snapshot, per ship (from `replay_recorder._write_snapshot` /
`replay_file_reader._parse_snapshot`)

- `pos`, `rot_y`, `velocity`
- `hp`
- `flags`: `visible_to_enemy`, `detection_type`, `sunk`
- `throttle` (–1..4), `rudder` (–1..1)
- `aim_point`, `bloom_radius`, `shell_index`
- `fire_mask`, `flood_mask`, `consumable_mask`
- per-gun `rot_y`, `barrel_rot_x`, **`reload`**
- secondary gun states

### Per-event

- `EVT_SHELL_FIRED` (attacker, gun, shell type, muzzle/velocity, caliber, …)
- `EVT_SHELL_HIT` (attacker, victim, **`hit_type`**, world `hit_pos`, shell uid)
- `EVT_TORPEDO_FIRED` / `ARMED` / `DETECTED` / `DESTROYED`
- `EVT_FIRE_STARTED` / `EVT_FIRE_ENDED` (zone + cause)
- `EVT_FLOOD_STARTED` / `EVT_FLOOD_ENDED`
- `EVT_CONSUMABLE_USED` / `EVT_CONSUMABLE_ENDED` (slot id)
- `EVT_DETECTION_CHANGED`
- `EVT_SHIP_SUNK` (victim, sinker, damage_type, pos)
- `EVT_MATCH_END` with per-ship final stats (total/main/torp/fire/flood damage,
  frags, main_hits, citadels, pens, overpens)

### Per ship, in the manifest

- `ship_name`, `player_name`, `team_id`, `is_bot`
- `gun_count`, `secondary_gun_count`, `fire_count`, `flood_count`
- `consumables: [ {slot_id, type, label} … ]`

### Conclusion

We have enough to drive **most** of the in-game HUD's read-only widgets without
touching the recorder. The only missing pieces are derived-stat values (which we
can synthesise by accumulating events as the playhead advances) and a few
gameplay-only widgets that have no replay meaning (aim crosshair, weapon
buttons, sniper reticle, minimap target indicator).

---

## Scope

### In scope (Phase 1)

The "followed" ship — the one currently selected via the existing
`ShipFollowOption` dropdown — gets the following HUD elements driven from
replay data:

| HUD element | Source widget | Data source |
|---|---|---|
| Kill feed | already wired ✅ | `EVT_SHIP_SUNK` |
| FPS readout | new `Label` | `Engine.get_frames_per_second()` |
| HP bar (no healable) | new bar (copy of `HPBar` styling) | snapshot `hp` for followed ship |
| Speed (knots) | new `Label` | `snapshot.velocity.length() * 1.94384` |
| Throttle indicator | new `Label` + `VSlider` (display-only) | `snapshot.throttle` |
| Rudder indicator | new `Label` + `HSlider` (display-only) | `snapshot.rudder` |
| Visibility indicator | reuse `ColorRect` block | `snapshot.flags` (`detection_type`) |
| Fire status icons | new icons | `snapshot.fire_mask` (count of bits) |
| Flood status icons | new icons | `snapshot.flood_mask` |
| Gun reload bars | reuse `ReloadBarTemplate` styling | per-gun `reload` from snapshot |
| Active consumables strip | small icon row | `snapshot.consumable_mask` + manifest |
| Hit/stat counters | reuse `HitStatCounters` scene | derived `Stats` (see below) |
| Team tracker (top-center) | reuse template `TeamTrackerContainer` styling | iterate `GhostShip`s with HP, team, is_sunk, detection |
| Minimap | `Minimap` if adapter built (see below) | ghost ship transforms |

### Out of scope (deferred to Phase 2)

- Aim crosshair / time-to-target / penetration-power readouts (replay has no
  player aim state — we'd have to fake it from `aim_point` if the followed ship
  has an `aim_point`; could be added later as a subset).
- Sniper reticle, target lock label.
- Weapon buttons (`Shell1Button` etc.) — these are interactive selectors with
  shortcuts; meaningless to a passive viewer.
- Consumable cooldown timer rings and shortcut overlays — the *active* state is
  fine in Phase 1; cooldown remaining requires per-consumable duration metadata
  the replay doesn't carry.
- Skills indicators (`init_ui`/`update_ui` are gameplay objects).
- Floating damage numbers (could be added later from `EVT_SHELL_HIT` deltas if
  desired; not Phase 1 essential).
- Battle-end screen integration (the replay has a definite end via
  `EVT_MATCH_END`; we can show a non-modal end overlay later).

---

## Architecture

### New files

```
src/replay/
  replay_hud.tscn                # new scene, instanced inside match_replay.tscn
  replay_hud.gd                  # script, extends CanvasLayer
  replay_stats_accumulator.gd    # plain Object/Resource, not a Node
  ghost_ship_view.gd             # tiny adapter: GhostShip → minimap-friendly API
```

`Minimap` currently calls `register_player_ship(ship: Ship)`. Either:
1. Make `Minimap.register_player_ship` accept a duck-typed object that exposes
   `global_position`, `team`, `ship_name`, OR
2. Skip the minimap in Phase 1.

Recommendation: **skip the minimap in Phase 1**, address it in Phase 2 when we
introduce the proper view-model interface (`IShipView`).

### Wiring inside `match_replay.gd`

1. Add an `@onready` reference for `ReplayHUD`.
2. Move the existing `KillFeed` *into* `ReplayHUD` (the kill feed code already
   lives in `match_replay.gd`; lift it into the HUD).
3. After `playback.setup_ghost_ships(ghost_ships)`, call
   `replay_hud.bind(playback, ghost_ships)`.
4. Connect `playback.event_fired` to `replay_hud._on_event_fired` (kill feed +
   stats accumulator both consume events).
5. When the user picks a ship in `ShipFollowOption`, call
   `replay_hud.set_followed_ship_id(id)`.

`match_replay.gd` retains responsibility for:
- camera, scrubber, play/pause, speed, back button, ship-follow dropdown.

`ReplayHUD` owns:
- per-frame rendering of the followed ship's HP / speed / throttle / rudder /
  visibility / fire / flood / reload / consumable widgets,
- kill feed,
- stat counters,
- team tracker.

### Snapshot pull strategy

`ReplayPlayback` already maintains `_snap_a`/`_snap_b` (interpolation pair).
`ReplayHUD._process` reads from `playback._snap_b` (or, for less jitter, the
result of the same interpolation that ghost ships use):

```gdscript
var snap = playback._snap_b.get(_followed_ship_id, null)
if snap == null:
    return
hp_bar.value = snap["hp"] / max_hp_for_ship
throttle_label.text = THROTTLE_TEXT[snap["throttle"]]
# … etc.
```

`max_hp` is captured once on bind, from the corresponding `GhostShip.max_hp`
(GhostShip already tracks max_hp from the first apply_snapshot — we may need to
expose a "starting_hp" in the manifest if the *initial* max isn't trustworthy
yet; today GhostShip seeds max_hp on the first non-zero snapshot, which is fine
for display).

### Stats accumulator

`replay_stats_accumulator.gd` is a small object, **not** the real `Stats`, that
exposes the same field names `HitStatCounters` reads:

- `total_damage`, `main_damage`, `sec_damage`, `torpedo_damage`, `fire_damage`,
  `flood_damage`
- `frags`, `main_hits`, `secondary_count`
- `penetration_count`, `partial_pen_count`, `overpen_count`, `shatter_count`,
  `ricochet_count`, `citadel_count`, `citadel_overpen_count`
- corresponding `sec_*` counters
- `torpedo_count`, `fire_count`, `flood_count`
- `ships_damaged: Dictionary[String, float]`

Maintained by listening to the `event_fired` signal of `ReplayPlayback`:

- `EVT_SHELL_HIT`: bump the appropriate hit counter via `hit_type`; we **don't
  know damage per hit** in the recorded payload (it's not in the format), so we
  can't accumulate `total_damage` from shell hits alone.

> ⚠ This is a Phase 1 limitation. Damage values are only available in the
> *final* `EVT_MATCH_END` summary. Phase 1 will display **counts** accurately
> and either omit damage values or show "—" until end-of-match. Phase 2 will
> add a `damage` field to `EVT_SHELL_HIT` (small format bump) so damage tracks
> in real time.

- `EVT_TORPEDO_DESTROYED` with `hit_ship_id` matching a ship: count torpedo hit.
- `EVT_FIRE_STARTED`/`EVT_FLOOD_STARTED` where `caused_by_ship_id == followed`:
  bump fire/flood count.
- `EVT_SHIP_SUNK` where `sinker_ship_id == followed`: bump `frags`.

### Seek handling

`ReplayPlayback.seek()` already replays events in a "lookback" window. The
accumulator must:

- **Forward seek**: receive events normally as `event_fired` is emitted.
- **Backward seek / large jump**: be reset and replayed from `t=0` to the new
  current time.

Add a single `signal seek_jumped(new_time)` to `ReplayPlayback` (it already
distinguishes seek vs. natural play in `_begin_seeking`/`_end_seeking`). On
`seek_jumped`, `ReplayHUD` calls `_stats_accumulator.replay_from_zero_to(t)`
which uses `reader.read_events_in_range(0.0, t)` and re-feeds events.

This is cheap (events are O(few thousand) per match) and avoids any state
divergence on scrub.

---

## Followed-ship change handling

When the user changes the follow target:

- Throttle/rudder/HP/etc. labels start reading the new snapshot ship id.
- The stats accumulator **resets** and re-builds from `t=0..current_time`,
  filtering events by the new ship id.

This makes scrubbing + ship-switching consistent with no extra recording.

---

## Visual layout

Reuse the **same `MainContainer` panel layout** as `camera_ui.tscn` so the look
matches:

- `BottomLeftPanel`: speed / throttle / rudder
- `BottomCenterPanel`: HP bar + reload bars + active consumables + status icons
- `TopCenterPanel`: team tracker
- `TopLeftPanel`: FPS
- `MiddleRightPanel` (new, where bottom-right Minimap normally lives): the kill
  feed moves here from the side panel, freeing the side panel.

The replay control bars (TopBar, BottomBar with scrubber) live above
`ReplayHUD` and are unchanged.

---

## Implementation steps (suggested order)

1. **Create `replay_hud.tscn` + `replay_hud.gd`** as a `CanvasLayer` with empty
   panels matching the in-game layout. Verify it renders inside
   `match_replay.tscn` without crashing.
2. **Move kill feed** out of `match_replay.gd` into the HUD (no behaviour
   change).
3. **HP / speed / throttle / rudder / visibility** for followed ship (read
   directly from `playback._snap_b`). This is half the value of Phase 1 in one
   step.
4. **Gun reload bars** from per-gun `reload` field (we know `gun_count` from
   manifest, so we can pre-build N bars on bind).
5. **Fire / flood status icons** from masks.
6. **Active consumable strip** (icon greyed when inactive, lit when bit set).
   No timer ring yet.
7. **Add `seek_jumped` signal** to `ReplayPlayback` and wire it.
8. **`replay_stats_accumulator.gd`** + `HitStatCounters` integration. Counts
   only; damage shown as `—` (or hidden).
9. **Team tracker**: replicate the styling from
   `ShipUITemplates/TeamTrackerTemplate`, populate from `ghost_ships` with HP %
   and detection state.
10. **Polish pass**: colors, sizes, hide widgets cleanly when followed ship is
    sunk or `Free Camera` is selected.

---

## Risks / open questions

- **`max_hp` for the followed ship**: `GhostShip.max_hp` is bootstrapped from
  the first snapshot's HP. If `replay_recorder` ever begins recording before
  the ship's HP is fully initialised this could be wrong. Audit
  `GhostShip.apply_snapshot` and consider adding `max_hp` to the manifest.
- **Consumable icons**: the manifest stores a `label` and `type` per
  consumable; we need either a type→icon table or use textual labels in
  Phase 1.
- **`HitStatCounters` API surface**: it currently calls `set_stats(stats)` and
  reads fields directly. Verify that duck-typing a plain `Object` with the
  same field names works (it should — GDScript reads by name). If it
  type-checks `Stats`, replace those checks with a property-existence check.
- **Time wasted on seek-replay of events**: a 30-minute match has at most a
  few thousand events. `read_events_in_range(0, t)` for the longest possible
  scrub is still well below 1 ms; non-issue.
- **Damage-per-hit not in format** is the single biggest reason Phase 1 cannot
  fully reproduce the in-game stat counter. Documented above; resolved by the
  small format bump in Phase 2.

---

## Definition of done

- Open any `.replay` and the followed ship's HP, speed, throttle, rudder,
  visibility, fires, floods, gun reload bars, and active consumables update in
  sync with playback (and with scrubbing in either direction).
- Hit counts (P/Op/Pp/R/C/Co) accumulate correctly as the playhead advances
  forward and reset+replay correctly when scrubbing back.
- Switching the followed ship rebuilds the HUD and the accumulator from `t=0`
  to current time.
- Kill feed continues to work, now hosted by `ReplayHUD`.
- No changes to `replay_recorder.gd`, no changes to `replay_file_reader.gd`,
  no changes to `camera_ui_scene.gd`, no changes to the `.replay` format.
