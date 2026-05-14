extends RefCounted
class_name ReplayStatsAccumulator

## Duck-typed Stats-mirror used by the replay HUD.
##
## Exposes the same field names that `HitStatCounters` reads from the live
## `Stats` object so the same UI scene can be driven by replay events.
##
## Bidirectional cursor model:
##   The accumulator tracks the current playhead via `_cursor_index` (next
##   event in `all_events` to apply forward) and `_cursor_time`.  Seeking
##   forward applies events one-by-one; seeking backward UNAPPLIES events
##   in reverse order using the inverse of each per-event handler.  This
##   means scrubbing one second back is exactly as cheap as one second of
##   forward playback \u2014 no rebuild from t=0 is ever required.
##
## Usage:
##   var acc := ReplayStatsAccumulator.new()
##   acc.set_followed_ship(ship_id, reader.ships)
##   acc.seek_to(playback.current_time, reader.all_events)
##   playback.event_fired.connect(func(ev):
##       acc.seek_to(ev.timestamp, reader.all_events)
##       acc.push_flash(ev))
##   playback.seek_jumped.connect(func(t):
##       acc.seek_to(t, reader.all_events))
##
## When the followed ship changes, call set_followed_ship() then reset()
## then seek_to(current_time, all_events).

# ---------------------------------------------------------------------------
# Stats fields (names mirror src/stats/stats.gd exactly)
# ---------------------------------------------------------------------------
var total_damage: float = 0.0
var potential_damage: float = 0.0

# Hit-result counters (main battery)
var penetration_count: int = 0
var partial_pen_count: int = 0
var ricochet_count: int = 0
var overpen_count: int = 0
var shatter_count: int = 0
var citadel_count: int = 0
var citadel_overpen_count: int = 0

# Hit-result counters (secondary battery)
var sec_penetration_count: int = 0
var sec_partial_pen_count: int = 0
var sec_ricochet_count: int = 0
var sec_overpen_count: int = 0
var sec_shatter_count: int = 0
var sec_citadel_count: int = 0
var sec_citadel_overpen_count: int = 0

# Per-weapon damage / counts
var main_hits: int = 0
var main_damage: float = 0.0
var secondary_count: int = 0
var sec_damage: float = 0.0
var torpedo_count: int = 0
var torpedo_damage: float = 0.0
var fire_count: int = 0
var fire_damage: float = 0.0
var flood_count: int = 0
var flood_damage: float = 0.0
var spotting_count: int = 0
var spotting_damage: float = 0.0

var frags: int = 0

# Damage-by-victim, keyed by display name (matches Stats.ships_damaged contract)
var ships_damaged: Dictionary = {}

# Damage events for HitStatCounters' temp flash counters.
# HitStatCounters._physics_process clears this each frame after processing.
# Populated only by push_flash() (i.e. live events); silent forward/backward
# walks via seek_to() never push to this list.
var damage_events: Array = []

# ---------------------------------------------------------------------------
# Same HIT_TYPE_COUNTERS table as Stats.gd (kept inline to avoid coupling)
# ---------------------------------------------------------------------------
const HIT_TYPE_COUNTERS := {
	0: "penetration_count",
	1: "partial_pen_count",
	2: "ricochet_count",
	3: "overpen_count",
	4: "shatter_count",
	5: "citadel_count",
	6: "citadel_overpen_count",
}

# ---------------------------------------------------------------------------
# Followed-ship filtering and cursor state
# ---------------------------------------------------------------------------
var _followed_ship_id: int = -1

## ship_id (int) -> "player_name (ship_name)" string used as the key in
## ships_damaged.  Built once in set_followed_ship().
var _ship_display_name_by_id: Dictionary = {}

## Bidirectional playhead state.
## _cursor_index is the index of the *next* event in all_events to be applied
## forward.  All events with index < _cursor_index have been applied; all
## with index >= _cursor_index have not.
var _cursor_index: int = 0
var _cursor_time:  float = 0.0

## Torpedo attribution maps.  Mutated by TORPEDO_FIRED apply/unapply, so they
## stay perfectly in sync with the cursor.  No need to clear or rebuild on
## ship switch \u2014 reset() takes care of it.
var _torpedo_attackers: Dictionary = {}   # torpedo_id -> attacker ship_id
var _torpedo_damages:   Dictionary = {}   # torpedo_id -> damage value


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func set_followed_ship(ship_id: int, ships_manifest: Array) -> void:
	_followed_ship_id = ship_id
	_ship_display_name_by_id.clear()
	for entry in ships_manifest:
		var sid: int = entry.get("ship_id", -1)
		if sid < 0:
			continue
		var sname: String = entry.get("ship_name", "Ship")
		var pname: String = entry.get("player_name", "")
		_ship_display_name_by_id[sid] = "%s: %s" % [pname, sname] if pname != "" else sname


## Wipe every counter back to zero AND rewind the cursor to t=0.
## Use before re-seeking to a new followed ship perspective.
func reset() -> void:
	total_damage = 0.0
	potential_damage = 0.0
	penetration_count = 0
	partial_pen_count = 0
	ricochet_count = 0
	overpen_count = 0
	shatter_count = 0
	citadel_count = 0
	citadel_overpen_count = 0
	sec_penetration_count = 0
	sec_partial_pen_count = 0
	sec_ricochet_count = 0
	sec_overpen_count = 0
	sec_shatter_count = 0
	sec_citadel_count = 0
	sec_citadel_overpen_count = 0
	main_hits = 0
	main_damage = 0.0
	secondary_count = 0
	sec_damage = 0.0
	torpedo_count = 0
	torpedo_damage = 0.0
	fire_count = 0
	fire_damage = 0.0
	flood_count = 0
	flood_damage = 0.0
	spotting_count = 0
	spotting_damage = 0.0
	frags = 0
	ships_damaged.clear()
	damage_events.clear()
	_torpedo_attackers.clear()
	_torpedo_damages.clear()
	_cursor_index = 0
	_cursor_time  = 0.0


## Walk the cursor forward (apply) or backward (unapply) until the playhead
## is at time `t`.  All forward and backward steps are silent (no flash).
##
## Forward and backward seeks are symmetric and incremental: seeking from
## t=120 to t=121 only walks events in (120, 121]; seeking from t=121 back
## to t=120 walks the same events in reverse and un-applies them.
func seek_to(t: float, all_events: Array) -> void:
	if t > _cursor_time:
		_advance_to(t, all_events)
	elif t < _cursor_time:
		_rewind_to(t, all_events)
	_cursor_time = t


## Push a flash entry for a single live event.  Call this AFTER seek_to() so
## the cursor is past the event.  HitStatCounters._physics_process consumes
## damage_events to drive its temp counters.
func push_flash(ev: Dictionary) -> void:
	if _followed_ship_id < 0:
		return
	var et: int = ev.get("type", -1)
	match et:
		ReplayEvent.SHELL_DAMAGE:
			if ev.get("attacker_ship_id", -1) != _followed_ship_id:
				return
			damage_events.append({
				"type":     "hit",
				"hit_type": ev.get("hit_type", -1),
				"sec":      ev.get("is_secondary", false),
				"damage":   ev.get("damage", 0.0),
				"position": ev.get("hit_pos", Vector3.ZERO),
			})
		ReplayEvent.TORPEDO_DESTROYED:
			var torp_id: int = ev.get("torpedo_id", -1)
			if _torpedo_attackers.get(torp_id, -1) != _followed_ship_id:
				return
			damage_events.append({
				"type":     "torp",
				"damage":   _torpedo_damages.get(torp_id, 0.0),
				"position": ev.get("pos", Vector3.ZERO),
			})
		ReplayEvent.FIRE_STARTED:
			if ev.get("caused_by_ship_id", 255) == _followed_ship_id:
				damage_events.append({"type": "fire"})
		ReplayEvent.FLOOD_STARTED:
			if ev.get("caused_by_ship_id", 255) == _followed_ship_id:
				damage_events.append({"type": "flood"})
		ReplayEvent.SHIP_SUNK:
			if ev.get("sinker_ship_id", 255) == _followed_ship_id:
				damage_events.append({"type": "sunk"})


# ---------------------------------------------------------------------------
# Cursor walking (private)
# ---------------------------------------------------------------------------

func _advance_to(t: float, all_events: Array) -> void:
	var n: int = all_events.size()
	while _cursor_index < n:
		var ev: Dictionary = all_events[_cursor_index]
		if ev.get("timestamp", 0.0) > t:
			break
		_apply_event(ev)
		_cursor_index += 1


func _rewind_to(t: float, all_events: Array) -> void:
	while _cursor_index > 0:
		var prev: Dictionary = all_events[_cursor_index - 1]
		if prev.get("timestamp", 0.0) <= t:
			break
		_cursor_index -= 1
		_unapply_event(prev)


# ---------------------------------------------------------------------------
# Per-event handlers \u2014 every apply has a matching unapply that exactly
# reverses its mutations.  TORPEDO_FIRED mutates the attribution maps so
# those stay in sync with the cursor too.
# ---------------------------------------------------------------------------

func _apply_event(ev: Dictionary) -> void:
	var et: int = ev.get("type", -1)
	match et:
		ReplayEvent.TORPEDO_FIRED:
			# Attribution must be tracked regardless of followed ship so that
			# a later TORPEDO_DESTROYED can credit the correct attacker.
			var tid: int = ev.get("torpedo_id", -1)
			if tid >= 0:
				_torpedo_attackers[tid] = ev.get("ship_id", 255)
				_torpedo_damages[tid]   = ev.get("damage", 0.0)
		ReplayEvent.SHELL_DAMAGE:
			_apply_shell_damage(ev, +1)
		ReplayEvent.TORPEDO_DESTROYED:
			_apply_torpedo_destroyed(ev, +1)
		ReplayEvent.FIRE_DAMAGE:
			_apply_dot_damage(ev, +1, true)
		ReplayEvent.FLOOD_DAMAGE:
			_apply_dot_damage(ev, +1, false)
		ReplayEvent.FIRE_STARTED:
			if ev.get("caused_by_ship_id", 255) == _followed_ship_id:
				fire_count += 1
		ReplayEvent.FLOOD_STARTED:
			if ev.get("caused_by_ship_id", 255) == _followed_ship_id:
				flood_count += 1
		ReplayEvent.SHIP_SUNK:
			if ev.get("sinker_ship_id", 255) == _followed_ship_id:
				frags += 1


func _unapply_event(ev: Dictionary) -> void:
	var et: int = ev.get("type", -1)
	match et:
		ReplayEvent.TORPEDO_FIRED:
			var tid: int = ev.get("torpedo_id", -1)
			if tid >= 0:
				_torpedo_attackers.erase(tid)
				_torpedo_damages.erase(tid)
		ReplayEvent.SHELL_DAMAGE:
			_apply_shell_damage(ev, -1)
		ReplayEvent.TORPEDO_DESTROYED:
			_apply_torpedo_destroyed(ev, -1)
		ReplayEvent.FIRE_DAMAGE:
			_apply_dot_damage(ev, -1, true)
		ReplayEvent.FLOOD_DAMAGE:
			_apply_dot_damage(ev, -1, false)
		ReplayEvent.FIRE_STARTED:
			if ev.get("caused_by_ship_id", 255) == _followed_ship_id:
				fire_count -= 1
		ReplayEvent.FLOOD_STARTED:
			if ev.get("caused_by_ship_id", 255) == _followed_ship_id:
				flood_count -= 1
		ReplayEvent.SHIP_SUNK:
			if ev.get("sinker_ship_id", 255) == _followed_ship_id:
				frags -= 1


## Sign = +1 for apply (forward), -1 for unapply (backward).
func _apply_shell_damage(ev: Dictionary, dir: int) -> void:
	if ev.get("attacker_ship_id", -1) != _followed_ship_id:
		return
	var hit_type: int    = ev.get("hit_type", -1)
	var damage: float    = ev.get("damage", 0.0)
	var is_secondary: bool = ev.get("is_secondary", false)
	var victim_id: int   = ev.get("victim_ship_id", 255)

	total_damage += damage * dir

	if is_secondary:
		sec_damage += damage * dir
		secondary_count += dir
	else:
		main_damage += damage * dir
		main_hits += dir

	var counter_name: String = HIT_TYPE_COUNTERS.get(hit_type, "")
	if counter_name != "":
		var full_name: String = ("sec_" + counter_name) if is_secondary else counter_name
		set(full_name, get(full_name) + dir)

	if victim_id >= 0 and victim_id != 255:
		var key: String = _ship_display_name_by_id.get(victim_id, "Ship %d" % victim_id)
		var new_total: float = ships_damaged.get(key, 0.0) + damage * dir
		if absf(new_total) < 0.0001:
			ships_damaged.erase(key)
		else:
			ships_damaged[key] = new_total


func _apply_torpedo_destroyed(ev: Dictionary, dir: int) -> void:
	var hit_ship_id: int = ev.get("hit_ship_id", 255)
	if hit_ship_id == 255 or hit_ship_id < 0:
		return
	var torp_id: int = ev.get("torpedo_id", -1)
	var attacker_id: int = _torpedo_attackers.get(torp_id, -1)
	if attacker_id != _followed_ship_id:
		return
	var damage: float = _torpedo_damages.get(torp_id, 0.0)
	torpedo_count  += dir
	torpedo_damage += damage * dir
	total_damage   += damage * dir
	var key: String = _ship_display_name_by_id.get(hit_ship_id, "Ship %d" % hit_ship_id)
	var new_total: float = ships_damaged.get(key, 0.0) + damage * dir
	if absf(new_total) < 0.0001:
		ships_damaged.erase(key)
	else:
		ships_damaged[key] = new_total


## Per-tick fire/flood damage.  is_fire selects which weapon-damage bucket
## (fire_damage vs flood_damage) the delta is added to.  The fire_count /
## flood_count *instance* counters are NOT touched here — those are owned
## by FIRE_STARTED / FLOOD_STARTED.
func _apply_dot_damage(ev: Dictionary, dir: int, is_fire: bool) -> void:
	if ev.get("attacker_ship_id", -1) != _followed_ship_id:
		return
	var damage: float = ev.get("damage", 0.0)
	var victim_id: int = ev.get("victim_ship_id", 255)

	total_damage += damage * dir
	if is_fire:
		fire_damage += damage * dir
	else:
		flood_damage += damage * dir

	if victim_id >= 0 and victim_id != 255:
		var key: String = _ship_display_name_by_id.get(victim_id, "Ship %d" % victim_id)
		var new_total: float = ships_damaged.get(key, 0.0) + damage * dir
		if absf(new_total) < 0.0001:
			ships_damaged.erase(key)
		else:
			ships_damaged[key] = new_total
