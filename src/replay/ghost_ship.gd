class_name GhostShip
extends Node3D

## Visual-only ship node used during replay playback.
## No physics, no RPC, no networking — purely decorative.

# ---------------------------------------------------------------------------
# Public state
# ---------------------------------------------------------------------------
var ship_entry: Dictionary = {}     # ShipManifestEntry dict from ReplayFileReader
var current_hp: float = 1.0
var max_hp: float = 1.0
var team_id: int = 0
var is_sunk: bool = false
var detection_type: int = 0
var visible_to_enemy: bool = false

# ---------------------------------------------------------------------------
# Interpolation state
# ---------------------------------------------------------------------------
var _pos_a: Vector3 = Vector3.ZERO
var _pos_b: Vector3 = Vector3.ZERO
var _rot_a: float = 0.0
var _rot_b: float = 0.0

# ---------------------------------------------------------------------------
# Particle emitter tracking
# ---------------------------------------------------------------------------
## All GPUParticles3D nodes found in the ship model.
## Populated by _find_gun_nodes() (deferred).  Used for freeze/thaw during seeks
## and to suppress emission before the ship is placed at its real position.
var _particle_emitters: Array = []

## Set to true on the first apply_snapshot() call.  Prevents thaw_particles()
## from enabling emissions before the ship has been moved out of the origin.
var _is_placed: bool = false

# ---------------------------------------------------------------------------
# Child node references
# ---------------------------------------------------------------------------
var _model: Node3D = null           # The loaded ship scene instance
var _gun_pivots: Array = []         # Turret yaw nodes  (Node3D)
var _barrel_pivots: Array = []      # Barrel pitch nodes (Node3D)
var _secondary_gun_pivots: Array = []   # Secondary turret yaw nodes (Gun)
var _secondary_barrel_pivots: Array = [] # Secondary barrel pitch nodes (Node3D)
var _name_label: Label3D = null
var _fire_particles: Array = []     # GPUParticles3D / placeholder nodes
var _flood_particles: Array = []    # GPUParticles3D / placeholder nodes

# ---------------------------------------------------------------------------
# Sinking animation
# ---------------------------------------------------------------------------
var _is_sinking: bool = false
var _sink_time: float = 0.0
const SINK_DURATION: float = 30.0

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

## Initialise this ghost from a manifest entry.  Call once after add_child.
func setup(entry: Dictionary) -> void:
	ship_entry = entry
	team_id    = entry.get("team_id", 0)

	var scene_path: String = entry.get("scene_path", "")
	var loaded_scene: PackedScene = null

	if scene_path != "":
		loaded_scene = load(scene_path) as PackedScene

	if loaded_scene != null:
		_model = loaded_scene.instantiate() as Node3D
		_disable_processing(_model)
		# Collect and suppress all ParticleEmitter nodes BEFORE add_child so that
		# _ready() / _try_initialize() fires with auto_start = false.  This prevents
		# any wake or exhaust emitter from allocating a GPU trail at Vector3.ZERO
		# before the ship is placed at its real replay position.
		_collect_and_disable_particle_emitters(_model)
		add_child(_model)
		# Turret._ready() calls cleanup.call_deferred(), which reparents each Gun
		# and queue_frees its wrapper parent.  We must wait one frame so those
		# deferred calls complete before we store any node references.
		_find_gun_nodes.call_deferred()
	else:
		# Fallback: show a simple box so we can see the ship's position
		push_warning("GhostShip: could not load scene '%s', using fallback mesh." % scene_path)
		var fallback := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(10.0, 3.0, 40.0)
		fallback.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.3, 0.6, 1.0, 0.7)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fallback.material_override = mat
		_model = fallback
		add_child(_model)

	# Name label
	_name_label = Label3D.new()
	_name_label.text         = entry.get("ship_name", "???") + "\n" + entry.get("player_name", "")
	_name_label.font_size    = 24
	_name_label.pixel_size   = 0.00025   # default 0.01 makes the label a ~0.24-unit speck
	_name_label.billboard    = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.fixed_size   = true   # constant screen-space size regardless of distance
	_name_label.no_depth_test = true  # render on top of ship geometry
	_name_label.outline_size  = 6     # improves legibility against varied backgrounds
	_name_label.modulate     = Color(0.2, 1.0, 0.2) if team_id == 0 else Color(1.0, 0.3, 0.3)
	_name_label.position     = Vector3(0.0, 50.0, 0.0)
	add_child(_name_label)


## Walk the loaded model tree to collect main-battery Gun nodes.
## Uses ArtilleryController.guns directly — this @export array is set in the
## editor and contains only main-battery guns in the same order the recorder
## iterates them.  Using it avoids picking up secondary Gun nodes that also
## live in the scene tree after Turret.cleanup() reparents everything to
## ShipRoot.
## Called deferred so Turret.cleanup.call_deferred() has already run.
func _find_gun_nodes() -> void:
	if not is_instance_valid(_model):
		return

	_gun_pivots.clear()
	_barrel_pivots.clear()

	# ArtilleryController.guns is the authoritative ordered list of main-battery
	# Gun nodes — identical to what replay_recorder iterates.
	var artillery: ArtilleryController = _model.find_child("ArtilleryController", true, false) as ArtilleryController
	if artillery == null:
		push_warning("GhostShip: ArtilleryController not found in '%s'" % ship_entry.get("scene_path", "?"))
		return

	for gun: Gun in artillery.guns:
		if not is_instance_valid(gun):
			continue
		_gun_pivots.append(gun)
		# gun.barrel is set by @onready in Gun.gd; valid because _ready() has run.
		var barrel: Node3D = gun.barrel if is_instance_valid(gun.barrel) else null
		_barrel_pivots.append(barrel)
	# _particle_emitters is already built (filtered to trail-type only) by
	# _collect_and_disable_particle_emitters() before add_child().  No re-collection
	# here — find_children would return ALL ParticleEmitters (including fire),
	# overwriting the filtered list and causing non-trail emitters to thaw.

	# Secondary guns — iterated in sub_controller order to match the recorder.
	_secondary_gun_pivots.clear()
	_secondary_barrel_pivots.clear()
	var secondary_ctrl: SecondaryController_ = _model.find_child("SecondaryController", true, false) as SecondaryController_
	if secondary_ctrl != null:
		for sc in secondary_ctrl.sub_controllers:
			for gun: Gun in sc.guns:
				if not is_instance_valid(gun):
					continue
				_secondary_gun_pivots.append(gun)
				var sec_barrel: Node3D = gun.barrel if is_instance_valid(gun.barrel) else null
				_secondary_barrel_pivots.append(sec_barrel)


# ---------------------------------------------------------------------------
# Processing control
# ---------------------------------------------------------------------------

## Recursively disable all processing on a node tree so the instantiated scene
## doesn't try to run any game logic during replay.
## ParticleEmitter nodes are intentionally SKIPPED so their _process() keeps
## running: wake.gd needs it to follow the ship's interpolated position via
## auto_update_position and the parent-relative local_offset transform.
func _disable_processing(node: Node) -> void:
	if node == null:
		return
	if node is ParticleEmitter:
		return  # leave emitter _process() enabled for position tracking
	node.set_process(false)
	node.set_physics_process(false)
	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	for child in node.get_children():
		_disable_processing(child)


## Walk the model tree BEFORE add_child() and suppress every ParticleEmitter:
## - sets auto_start = false on ALL emitters (prevents any emission at Vector3.ZERO)
## - only collects trail-type emitters (template.is_trail == true) into
##   _particle_emitters so that thaw_particles() re-enables wakes and exhaust
##   but leaves fire / explosion emitters permanently off during replay.
## Called on the instantiated scene before it enters the tree, so _ready()
## hasn't fired yet and auto_start is still mutable.
func _collect_and_disable_particle_emitters(node: Node) -> void:
	if node == null:
		return
	if node is ParticleEmitter:
		var pe := node as ParticleEmitter
		pe.auto_start = false
		# Only wake / exhaust / trail emitters should restart once the ship is
		# positioned.  Fire, explosion, and burst emitters stay suppressed and
		# are managed externally (fire mask, hit events, etc.).
		if pe.template != null and pe.template.is_trail:
			_particle_emitters.append(pe)
		return  # ParticleEmitter nodes don't contain further ParticleEmitters
	for child in node.get_children():
		_collect_and_disable_particle_emitters(child)


# ---------------------------------------------------------------------------
# Snapshot application
# ---------------------------------------------------------------------------

## Hard-set this ghost's state from a snapshot dictionary for one ship.
func apply_snapshot(ship_data: Dictionary) -> void:
	if ship_data.is_empty():
		return

	var pos: Vector3 = ship_data.get("pos", Vector3.ZERO)
	global_position = Vector3(pos.x, 0.0, pos.z)
	rotation.y     = ship_data.get("rot_y", 0.0)
	current_hp     = ship_data.get("hp", 0.0)

	var flags: int = ship_data.get("flags", 0)
	visible_to_enemy = (flags & 0x01) != 0
	detection_type   = (flags >> 1) & 0x03
	is_sunk          = (flags & 0x08) != 0

	# Reconcile sinking visual state so seeks in either direction work correctly.
	# This must happen regardless of whether start_sinking() was ever called,
	# because the SHIP_SUNK event is not re-dispatched during a seek().
	if is_sunk:
		# Seeking forward into / past a sinking: collapse to fully-sunk instantly.
		_is_sinking = false
		visible     = false
		if _name_label != null:
			_name_label.visible = false
	else:
		# Seeking backward before a sinking (or ship never sank): restore alive state.
		_is_sinking = false
		_sink_time  = 0.0
		visible     = true
		rotation.z  = 0.0
		if _name_label != null:
			_name_label.visible = true

	# Gun rotations
	var guns: Array = ship_data.get("guns", [])
	for i in min(_gun_pivots.size(), guns.size()):
		var pivot: Node3D = _gun_pivots[i]
		if pivot == null or not is_instance_valid(pivot):
			continue
		pivot.rotation.y = guns[i].get("rot_y", 0.0)
		if i < _barrel_pivots.size():
			var barrel: Node3D = _barrel_pivots[i]
			if barrel != null and is_instance_valid(barrel):
				barrel.rotation.x = guns[i].get("barrel_rot_x", 0.0)

	# Secondary gun rotations
	# When active=true the snapshot carries per-gun transforms; when false (guns
	# returning to base) we snap them to base rotation (0, 0) immediately so the
	# replay matches the pass-flag optimization used by the recorder.
	var sec_active: bool = ship_data.get("secondary_active", false)
	var sec_guns: Array  = ship_data.get("secondary_guns", [])
	for si in _secondary_gun_pivots.size():
		var sec_pivot: Node3D = _secondary_gun_pivots[si]
		if sec_pivot == null or not is_instance_valid(sec_pivot):
			continue
		if sec_active and si < sec_guns.size():
			sec_pivot.rotation.y = sec_guns[si].get("rot_y", 0.0)
		else:
			sec_pivot.rotation.y = 0.0
		if si < _secondary_barrel_pivots.size():
			var sec_barrel: Node3D = _secondary_barrel_pivots[si]
			if sec_barrel != null and is_instance_valid(sec_barrel):
				sec_barrel.rotation.x = sec_guns[si].get("barrel_rot_x", 0.0) if (sec_active and si < sec_guns.size()) else 0.0

	# Fire and flood visual state
	set_active_fires(ship_data.get("fire_mask", 0))
	set_active_floods(ship_data.get("flood_mask", 0))

	# Update name label tint based on detection state
	if _name_label != null:
		if detection_type > 0:
			# Radar / hydro detected — shift toward orange
			_name_label.modulate = Color(1.0, 0.8, 0.0)
		elif team_id == 0:
			_name_label.modulate = Color(0.2, 1.0, 0.2)
		else:
			_name_label.modulate = Color(1.0, 0.3, 0.3)

	# Reset interpolation anchors to the new hard position
	_pos_a = global_position
	_pos_b = global_position
	_rot_a = rotation.y
	_rot_b = rotation.y

	# Mark the ship as positioned on the first snapshot.  Particle emitters are
	# thawed here only when _particle_emitters is already populated (i.e. after
	# _find_gun_nodes has run deferred).  If it is not yet populated, the deferred
	# _find_gun_nodes call will thaw once it finishes collecting nodes.
	if not _is_placed:
		_is_placed = true
		thaw_particles()


# ---------------------------------------------------------------------------
# Interpolation
# ---------------------------------------------------------------------------

## Set the two keyframe data dictionaries used for smooth interpolation.
## Call this once per rendered frame (or whenever the playhead advances).
func set_interpolation_targets(from_data: Dictionary, to_data: Dictionary) -> void:
	if from_data.is_empty() or to_data.is_empty():
		return
	var from_pos: Vector3 = from_data.get("pos", Vector3.ZERO)
	var to_pos: Vector3   = to_data.get("pos", Vector3.ZERO)
	_pos_a = Vector3(from_pos.x, 0.0, from_pos.z)
	_pos_b = Vector3(to_pos.x, 0.0, to_pos.z)
	_rot_a = from_data.get("rot_y", 0.0)
	_rot_b = to_data.get("rot_y", 0.0)


## Drive the ghost to the interpolated position between the A and B keyframes.
## alpha in [0, 1]: 0 = fully at A, 1 = fully at B.
func advance_interpolation(alpha: float) -> void:
	global_position = _pos_a.lerp(_pos_b, alpha)

	# Shortest-path angular interpolation.
	# wrapf correctly handles the ±PI boundary where fmod can flip sign and
	# produce a full ~2π rotation instead of a tiny correction.
	var rot_diff: float = wrapf(_rot_b - _rot_a, -PI, PI)
	rotation.y = _rot_a + rot_diff * alpha


# ---------------------------------------------------------------------------
# Particle freeze / thaw  (used by ReplayPlayback during seek)
# ---------------------------------------------------------------------------

## Tracks whether each emitter was actively emitting before the last
## freeze_particles() call.  Keyed by ParticleEmitter node reference.
## Empty = no freeze has happened yet (first thaw starts all trail emitters).
var _emitter_was_active: Dictionary = {}


## Disable emission on all tracked trail-type ParticleEmitter nodes.
## Records each emitter's active state so thaw_particles() can restore
## exactly what was running rather than unconditionally restarting everything.
func freeze_particles() -> void:
	_emitter_was_active.clear()
	for pe in _particle_emitters:
		if is_instance_valid(pe):
			var emitter := pe as ParticleEmitter
			_emitter_was_active[pe] = emitter.is_emitting()
			emitter.stop_emitting()


## Re-enable emission on tracked trail-type ParticleEmitter nodes.
## On the first call (no prior freeze), starts all trail emitters unconditionally.
## On subsequent calls (after freeze_particles()), only restarts emitters that
## were actually running before the freeze — emitters already stopped are
## left stopped.
func thaw_particles() -> void:
	if not _is_placed:
		return
	for pe in _particle_emitters:
		if is_instance_valid(pe):
			# Default true: first thaw (no prior freeze record) starts all trail
			# emitters.  After a seek, only those flagged active resume.
			if _emitter_was_active.get(pe, true):
				(pe as ParticleEmitter).start_emitting()
	_emitter_was_active.clear()


# ---------------------------------------------------------------------------
# Fire / flood visual masks
# ---------------------------------------------------------------------------

func set_active_fires(mask: int) -> void:
	for i in _fire_particles.size():
		var p = _fire_particles[i]
		if p != null and is_instance_valid(p) and p.has_method("set"):
			p.emitting = ((mask >> i) & 1) == 1


func set_active_floods(mask: int) -> void:
	for i in _flood_particles.size():
		var p = _flood_particles[i]
		if p != null and is_instance_valid(p) and p.has_method("set"):
			p.emitting = ((mask >> i) & 1) == 1


# ---------------------------------------------------------------------------
# Sinking
# ---------------------------------------------------------------------------

func start_sinking() -> void:
	is_sunk      = true
	_is_sinking  = true
	_sink_time   = 0.0
	if _name_label != null:
		_name_label.visible = false


# ---------------------------------------------------------------------------
# _process
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _is_sinking:
		return

	_sink_time += delta
	var t: float = minf(_sink_time / SINK_DURATION, 1.0)

	# Tilt and slowly submerge
	rotation.z = lerp(0.0, deg_to_rad(15.0), t)
	position.y = lerp(0.0, -20.0, t)

	if t >= 1.0:
		visible    = false
		_is_sinking = false
