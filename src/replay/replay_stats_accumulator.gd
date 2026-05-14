extends RefCounted
class_name ReplayStatsAccumulator

## Duck-typed Stats-mirror used by the replay HUD.
##
## Exposes the same field names that `HitStatCounters` reads from the live
## `Stats` object so the same UI scene can be driven by replay events.
##
## Usage:
##   var acc := ReplayStatsAccumulator.new()
##   acc.set_followed_ship(ship_id, ship_name_lookup_dict)
##   playback.event_fired.connect(acc.handle_event)
##   playback.seek_jumped.connect(func(t):
##       acc.reset()
##       acc.replay_events(reader.read_events_in_range(0.0, t)))
##
## When the followed ship changes, call set_followed_ship() and feed it
## events from t=0 to current_time again.

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
# Followed-ship filtering
# ---------------------------------------------------------------------------
var _followed_ship_id: int = -1

## ship_id (int) -> "player_name (ship_name)" string used as the key in
## ships_damaged. Pass in the ships array from ReplayFileReader.
var _ship_display_name_by_id: Dictionary = {}

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

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Wipe every counter back to zero. Call before replay_events() on seek.
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

## Process a single replay event. `silent=true` suppresses damage_events
## (used during seek-rebuild so the temp flash counters don't go off for
## historical hits).
func handle_event(ev: Dictionary, silent: bool = false) -> void:
	if _followed_ship_id < 0:
		return
	var et: int = ev.get("type", -1)
	match et:
		ReplayEvent.SHELL_DAMAGE:
			_handle_shell_damage(ev, silent)
		ReplayEvent.TORPEDO_DESTROYED:
			_handle_torpedo_destroyed(ev, silent)
		ReplayEvent.FIRE_STARTED:
			_handle_fire_started(ev, silent)
		ReplayEvent.FLOOD_STARTED:
			_handle_flood_started(ev, silent)
		ReplayEvent.SHIP_SUNK:
			_handle_ship_sunk(ev, silent)

## Replay a batch of historical events, suppressing flash effects.
## Used after a seek to reconstruct stats up to the new current_time.
func replay_events(events: Array) -> void:
	for ev in events:
		handle_event(ev, true)
	# Clear any inadvertent pushes (handle_event respects silent, but be defensive)
	damage_events.clear()

# ---------------------------------------------------------------------------
# Per-event handlers
# ---------------------------------------------------------------------------

func _handle_shell_damage(ev: Dictionary, silent: bool) -> void:
	if ev.get("attacker_ship_id", -1) != _followed_ship_id:
		return
	var hit_type: int   = ev.get("hit_type", -1)
	var damage: float   = ev.get("damage", 0.0)
	var is_secondary: bool = ev.get("is_secondary", false)
	var victim_id: int  = ev.get("victim_ship_id", 255)
	var position: Vector3 = ev.get("hit_pos", Vector3.ZERO)

	total_damage += damage

	if is_secondary:
		sec_damage += damage
		secondary_count += 1
	else:
		main_damage += damage
		main_hits += 1

	# Hit-result counter
	var counter_name: String = HIT_TYPE_COUNTERS.get(hit_type, "")
	if counter_name != "":
		var full_name: String = ("sec_" + counter_name) if is_secondary else counter_name
		set(full_name, get(full_name) + 1)

	# Damage-by-victim
	if victim_id >= 0 and victim_id != 255:
		var key: String = _ship_display_name_by_id.get(victim_id, "Ship %d" % victim_id)
		ships_damaged[key] = ships_damaged.get(key, 0.0) + damage

	if not silent:
		damage_events.append({
			"type": "hit",
			"hit_type": hit_type,
			"sec": is_secondary,
			"damage": damage,
			"position": position,
		})

func _handle_torpedo_destroyed(ev: Dictionary, silent: bool) -> void:
	# We don't currently know which ship fired the torpedo from this event.
	# torpedo_id ties back to EVT_TORPEDO_FIRED if we ever want attribution.
	# For now, count any torpedo hit *attributed to the followed ship*: we'd
	# need a torpedo_id -> attacker map. Skipping per-followed filtering means
	# all torp hits would be counted; that's wrong. So: build the map.
	# Done in _torpedo_attackers (populated by replay_events / handle_event).
	var hit_ship_id: int = ev.get("hit_ship_id", 255)
	if hit_ship_id == 255 or hit_ship_id < 0:
		return
	var torp_id: int = ev.get("torpedo_id", -1)
	var attacker_id: int = _torpedo_attackers.get(torp_id, -1)
	if attacker_id != _followed_ship_id:
		return
	var damage: float = _torpedo_damages.get(torp_id, 0.0)
	torpedo_count += 1
	torpedo_damage += damage
	total_damage += damage
	if hit_ship_id != 255:
		var key: String = _ship_display_name_by_id.get(hit_ship_id, "Ship %d" % hit_ship_id)
		ships_damaged[key] = ships_damaged.get(key, 0.0) + damage
	if not silent:
		damage_events.append({
			"type": "torp",
			"damage": damage,
			"position": ev.get("pos", Vector3.ZERO),
		})

func _handle_fire_started(ev: Dictionary, silent: bool) -> void:
	if ev.get("caused_by_ship_id", 255) != _followed_ship_id:
		return
	fire_count += 1
	if not silent:
		damage_events.append({"type": "fire"})

func _handle_flood_started(ev: Dictionary, silent: bool) -> void:
	if ev.get("caused_by_ship_id", 255) != _followed_ship_id:
		return
	flood_count += 1
	if not silent:
		damage_events.append({"type": "flood"})

func _handle_ship_sunk(ev: Dictionary, silent: bool) -> void:
	if ev.get("sinker_ship_id", 255) != _followed_ship_id:
		return
	frags += 1
	if not silent:
		damage_events.append({"type": "sunk"})

# ---------------------------------------------------------------------------
# Torpedo attribution (built up as TORPEDO_FIRED events arrive)
# ---------------------------------------------------------------------------
## torpedo_id -> attacker ship_id. Populated by handle_event() when it sees
## TORPEDO_FIRED. Persists across followed-ship changes; reset() does NOT
## clear it because it is keyed by globally-unique torpedo_id and we want
## to retain attribution when re-binding to a different followed ship after
## the same replay-load.
var _torpedo_attackers: Dictionary = {}
var _torpedo_damages: Dictionary = {}

## Call this from the playback's event_fired BEFORE handle_event so that
## TORPEDO_FIRED attribution is recorded for every torpedo. (The HUD wires
## this for us by always invoking observe_for_attribution() first.)
func observe_for_attribution(ev: Dictionary) -> void:
	if ev.get("type", -1) == ReplayEvent.TORPEDO_FIRED:
		var tid: int = ev.get("torpedo_id", -1)
		if tid >= 0:
			_torpedo_attackers[tid] = ev.get("ship_id", 255)
			_torpedo_damages[tid]   = ev.get("damage", 0.0)

## Wipe torpedo attribution. Use only when loading a fresh replay.
func clear_attribution() -> void:
	_torpedo_attackers.clear()
	_torpedo_damages.clear()
