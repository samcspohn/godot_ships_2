class_name TorpedoReplayer
extends Node3D

## Manages torpedo visuals during replay playback.
## ReplayPlayback adds this as a child node and calls update_torpedos() every frame.
## Torpedoes are tracked by their integer torpedo_id, which is unique within a match.

# ---------------------------------------------------------------------------
# Constants  (mirror torpedo_manager.gd)
# ---------------------------------------------------------------------------

## Torpedo flight-time multiplier the match ran at; set from the replay being played.
var speed_multiplier: float = 3.0

## Knots → metres-per-second conversion factor.
const KNOTS_TO_MS: float = 0.514444

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## Map of torpedo_id (int) → entry Dictionary.
## Entry fields:
##   event      : Dictionary         – original TORPEDO_FIRED event dict
##   mesh       : MeshInstance3D     – cylinder visual
##   material   : StandardMaterial3D – direct ref for colour changes
##   armed      : bool
##   detected   : bool
##   fire_timestamp : float          – replay-relative fire time (preamble ts)
var _active_torpedos: Dictionary = {}

## When true, skip GPU emitter allocation for all active torpedos.
## Set by ReplayPlayback during seek to prevent spurious trails from the
## re-spawned torpedos jumping from their recorded start position to the
## current seek position.
var is_seeking: bool = false

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Spawn a torpedo visual from a TORPEDO_FIRED event dictionary.
##
## event fields used:
##   torpedo_id      : int    – unique ID assigned by TorpedoManager
##   start_pos       : Vector3
##   direction       : Vector3 – normalised travel direction
##   fire_timestamp  : float
##   speed_knts      : float  – torpedo speed in knots
##   range_m         : float  – maximum range in metres
##   detection_range : float  – (reserved; not currently displayed)
func spawn_torpedo(event: Dictionary) -> void:
	var torp_id: int = event.get("torpedo_id", -1)
	if torp_id < 0:
		return

	# Guard against duplicate spawns (can happen after a seek that replays events).
	if _active_torpedos.has(torp_id):
		return

	# ---- CylinderMesh matching torpedo_manager.gd ----
	var cylinder := CylinderMesh.new()
	cylinder.top_radius    = 0.6
	cylinder.bottom_radius = 0.6
	cylinder.height        = 6.0
	cylinder.radial_segments = 16
	cylinder.rings         = 0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.6, 1.0)   # blue = unarmed
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cylinder.material = mat

	var instance := MeshInstance3D.new()
	instance.mesh = cylinder
	add_child(instance)

	# Wake emitter is allocated lazily in update_torpedos() at the torpedo's
	# actual position rather than here at start_pos.  This avoids a spurious
	# trail stretching from the original fire point to the seek destination
	# whenever spawn_torpedo() is called during a seek.

	_active_torpedos[torp_id] = {
		"event"        : event,
		"mesh"         : instance,
		"material"     : mat,
		"armed"        : false,
		"detected"     : false,
		"fire_timestamp" : event.get("timestamp", 0.0),
	}


## Advance every active torpedo to its computed position at current_time.
## Torpedoes that have exceeded their maximum range are removed.
## Called every frame by ReplayPlayback._process().
func update_torpedos(current_time: float) -> void:
	var to_remove: Array = []

	for torp_id in _active_torpedos:
		var entry: Dictionary   = _active_torpedos[torp_id]
		var event: Dictionary   = entry.event
		var fire_ts: float      = entry.fire_timestamp

		var t_flight: float     = (current_time - fire_ts) * speed_multiplier

		# Torpedo hasn't been fired yet in replay time (e.g. after a backward seek).
		if t_flight < 0.0:
			entry.mesh.visible = false
			continue

		var speed_ms: float = event.get("speed_knts", 30.0) * KNOTS_TO_MS
		var dir: Vector3    = event.get("direction",  Vector3.FORWARD)
		var start: Vector3  = event.get("start_pos",  Vector3.ZERO)

		var pos: Vector3 = dir * speed_ms * t_flight + start
		pos.y = maxf(pos.y - t_flight * 10.0, -2.0)

		# Horizontal distance check for max range (ignores depth change).
		var horiz: Vector3 = pos - start
		horiz.y = 0.0
		if horiz.length() > event.get("range_m", 10000.0):
			to_remove.append(torp_id)
			continue

		var mesh_inst: MeshInstance3D = entry.mesh
		if not is_instance_valid(mesh_inst):
			to_remove.append(torp_id)
			continue

		# Position and orient the cylinder so its Y axis aligns with travel direction.
		if dir.length_squared() > 0.0001:
			var d: Vector3 = dir.normalized()
			var up_ref: Vector3 = Vector3.FORWARD if absf(d.dot(Vector3.UP)) > 0.99 else Vector3.UP
			var right: Vector3 = d.cross(up_ref).normalized()
			var back: Vector3  = right.cross(d)
			var b := Basis()
			b.x = right
			b.y = d
			b.z = back
			mesh_inst.transform = Transform3D(b, pos)
		else:
			mesh_inst.global_position = pos
		mesh_inst.visible = true

		# Seeking restarts the trail at the restored position instead of drawing
		# a line from wherever the torpedo was before the jump.
		if is_instance_valid(WaveManager):
			if is_seeking:
				WaveManager.end_trail(mesh_inst)
			else:
				WaveManager.trail_point(mesh_inst, pos)

	# Deferred removal to avoid mutating the dict while iterating.
	for dead_id in to_remove:
		if _active_torpedos.has(dead_id):
			_free_torpedo_entry(_active_torpedos[dead_id])
			_active_torpedos.erase(dead_id)


## Change a torpedo's colour to orange to indicate it has become armed.
## Triggered by the TORPEDO_ARMED event.
func mark_armed(torp_id: int) -> void:
	if not _active_torpedos.has(torp_id):
		return
	var entry: Dictionary = _active_torpedos[torp_id]
	entry.armed = true
	var mat: StandardMaterial3D = entry.get("material")
	if mat != null:
		mat.albedo_color = Color(1.0, 0.5, 0.0)   # orange = armed


## Change a torpedo's colour to red to indicate it has been detected.
## Triggered by the TORPEDO_DETECTED event.
func mark_detected(torp_id: int) -> void:
	if not _active_torpedos.has(torp_id):
		return
	var entry: Dictionary = _active_torpedos[torp_id]
	entry.detected = true
	var mat: StandardMaterial3D = entry.get("material")
	if mat != null:
		mat.albedo_color = Color(1.0, 0.15, 0.15)  # red = detected / threat


## Remove a torpedo and show an explosion flash at the given world pos.
## Triggered by the TORPEDO_DESTROYED event (hit or self-destruct).
func destroy_torpedo(torp_id: int, world_pos: Vector3) -> void:
	if not _active_torpedos.has(torp_id):
		return
	var entry: Dictionary = _active_torpedos[torp_id]
	# Read damage before erasing.
	var damage: float = entry.event.get("damage", 10000.0)
	_free_torpedo_entry(entry)
	_active_torpedos.erase(torp_id)

	if is_instance_valid(HitEffects):
		# Radius formula matches destroyTorpedo_c() in torpedo_manager.gd.
		var radius: float = damage * 8.0 / 20000.0
		HitEffects.he_explosion_effect(world_pos, radius, Vector3.UP)
		HitEffects.sparks_effect(world_pos, radius, Vector3.UP)
		HitEffects.splash_effect(Vector3(world_pos.x, 0.0, world_pos.z), radius)
		if is_instance_valid(WaveManager):
			WaveManager.add_muzzle_blast(Vector3(world_pos.x, 0.0, world_pos.z), radius)


## Immediately destroy all torpedo visuals.
## Called by ReplayPlayback on seek or scene teardown.
func clear_all() -> void:
	for torp_id in _active_torpedos:
		_free_torpedo_entry(_active_torpedos[torp_id])
	_active_torpedos.clear()

## Same dicts as the navigator's get_debug_torpedo_threat_points, for armed, detected torpedoes from enemy_ids.
func threat_points(ship_pos: Vector3, enemy_ids: Dictionary, current_time: float, track_range: float = 3000.0) -> Array:
	const VIS_DIST := 3000.0
	var out := []
	for torp_id in _active_torpedos:
		var entry: Dictionary = _active_torpedos[torp_id]
		var event: Dictionary = entry.event
		if not entry.armed or not entry.detected or not enemy_ids.has(event.get("ship_id", -1)):
			continue
		var t_flight: float = (current_time - entry.fire_timestamp) * speed_multiplier
		var dir3: Vector3 = event.get("direction", Vector3.FORWARD)
		var dir := Vector2(dir3.x, dir3.z)
		if t_flight < 0.0 or dir.length_squared() < 1e-6:
			continue
		dir = dir.normalized()
		var speed_ms: float = event.get("speed_knts", 30.0) * KNOTS_TO_MS
		var start: Vector3 = event.get("start_pos", Vector3.ZERO)
		var pos := Vector2(start.x, start.z) + dir * speed_ms * t_flight
		var to_ship := Vector2(ship_pos.x, ship_pos.z) - pos
		if to_ship.length() > track_range:
			continue
		var center := pos + dir * VIS_DIST * 0.5
		var end := pos + dir * VIS_DIST
		out.append({
			"landing_x": center.x, "landing_z": center.y,
			"time_remaining": maxf(to_ship.dot(dir) / (speed_ms * speed_multiplier), 0.0), "caliber": 2000.0,
			"line_start_x": pos.x, "line_start_z": pos.y, "line_end_x": end.x, "line_end_z": end.y,
		})
	return out


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Free the mesh and wake emitter for one torpedo entry.
func _free_torpedo_entry(entry: Dictionary) -> void:
	if is_instance_valid(entry.get("mesh")):
		entry.mesh.queue_free()
	if is_instance_valid(WaveManager):
		WaveManager.end_trail(entry.get("mesh"))
