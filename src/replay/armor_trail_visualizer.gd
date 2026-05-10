## ArmorTrailVisualizer — shows internal shell armor penetration paths during
## match replay.  Lives inside the SubViewport World3D.
##
## Receives on_shell_hit() calls from ReplayPlayback when a SHELL_HIT event
## fires.  Looks up armor interaction data from an ArmorLogReader and adds
## the hit to a queue.
##
## Rendering rules:
##   - Only renders during play (not seeking).
##   - Visual duration: 0.5 s of non-paused wall-clock time.
##   - While paused, visual timer is frozen — paths stay visible.
##   - Queue lifetime: 2 s of wall-clock time (entries expire regardless of pause).
##   - Distance cull: only renders hits within 600 m of camera position.
##   - Paths and waypoint spheres render over geometry (no_depth_test = true).
extends Node3D
class_name ArmorTrailVisualizer

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
const QUEUE_LIFETIME:   float = 2.0    ## seconds before hit expires from queue
const VISUAL_DURATION:  float = 0.5    ## seconds a path is visible (non-paused time)
const CULL_DISTANCE:    float = 600.0  ## metres from camera
const CULL_DIST_SQ:     float = CULL_DISTANCE * CULL_DISTANCE
## Spheres per result type.  6 types × 16 = 96 pre-allocated nodes total.
## Each pool's spheres have their material assigned permanently at startup.
const POOL_SIZE_PER_TYPE: int = 16

## Internal result color indices — used to index STEP_COLORS, STEP_SCALES,
## and _step_materials.  Distinct from both ArmorResult and HitResult enums.
const RES_RICOCHET:    int = 0
const RES_OVERPEN:     int = 1
const RES_PEN:         int = 2
const RES_PARTIAL_PEN: int = 3
const RES_SHATTER:     int = 4
const RES_CITADEL:     int = 5   ## is_citadel flag was set on this plate

## Color per result index.
const STEP_COLORS: Array = [
	Color(1.00, 0.82, 0.00, 1.0),  # 0 RICOCHET     — amber
	Color(0.00, 0.85, 1.00, 1.0),  # 1 OVERPEN      — cyan
	Color(0.25, 1.00, 0.30, 1.0),  # 2 PEN          — green
	Color(1.00, 0.45, 0.00, 1.0),  # 3 PARTIAL_PEN  — orange
	Color(1.00, 0.12, 0.05, 1.0),  # 4 SHATTER      — red
	Color(1.00, 0.00, 0.95, 1.0),  # 5 CITADEL      — magenta (glows)
]

## Sphere radius scale per result index (applied to the MeshInstance3D scale).
## Final-stop marker is rendered at 2× these values.
const STEP_SCALES: Array = [
	0.5,   # 0 RICOCHET
	0.5,   # 1 OVERPEN
	1.0,   # 2 PEN
	1.5,   # 3 PARTIAL_PEN
	1.5,   # 4 SHATTER
	2.5,   # 5 CITADEL
]

## Maps HitResult enum values (used in final_hit_type) to our RES_* indices.
## HitResult: PENETRATION=0 PARTIAL_PEN=1 RICOCHET=2 OVERPENETRATION=3
##            SHATTER=4 CITADEL=5 CITADEL_OVERPEN=6 WATER=7 TERRAIN=8
const FINAL_HIT_TO_RES: Array = [
	RES_PEN,          # 0 PENETRATION
	RES_PARTIAL_PEN,  # 1 PARTIAL_PEN
	RES_RICOCHET,     # 2 RICOCHET
	RES_OVERPEN,      # 3 OVERPENETRATION
	RES_SHATTER,      # 4 SHATTER
	RES_CITADEL,      # 5 CITADEL
	RES_CITADEL,      # 6 CITADEL_OVERPEN
	RES_OVERPEN,      # 7 WATER  (should not appear in armorlog)
	RES_PARTIAL_PEN,  # 8 TERRAIN (should not appear in armorlog)
]

# ---------------------------------------------------------------------------
# Public state (set by match_replay.gd / replay_playback.gd)
# ---------------------------------------------------------------------------
var armor_log_reader: ArmorLogReader = null
var ghost_ships:      Array          = []   ## Array[GhostShip] indexed by ship_id
var camera:           Camera3D       = null
var is_seeking:  bool = false
var is_playing:  bool = false
var show_labels: bool = true    ## set false to suppress per-plate popups (e.g. match replay)

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
## Hit queue: shell_uid(int) → {hit_data, wall_time_added, visual_elapsed}
var _hit_queue: Dictionary = {}

## Line mesh (rebuilt each frame from active visible hits)
var _line_mesh:     ImmediateMesh      = null
var _line_instance: MeshInstance3D    = null
var _line_material: StandardMaterial3D = null

## Per-frame line data accumulated before building the mesh — avoids calling
## surface_begin/end when there is nothing to draw (which crashes ImmediateMesh).
## Reusing PackedArrays avoids per-frame heap allocation.
var _line_verts:  PackedVector3Array = PackedVector3Array()
var _line_colors: PackedColorArray   = PackedColorArray()

## Pre-baked materials — one per result color index, never mutated after creation.
var _step_materials: Array = []   ## Array[StandardMaterial3D]

## Per-result-type sphere pools.  _sphere_pools[RES_*] is an Array[MeshInstance3D]
## whose nodes have their material permanently assigned at startup.
var _sphere_pools:  Array           = []   ## Array[Array[MeshInstance3D]]
var _label_pools:   Array           = []   ## Array[Array[Label3D]], parallel to _sphere_pools
var _sphere_mesh:   SphereMesh      = null
## Active sphere count per type this frame and last frame (for hide-only-active logic).
var _sphere_active: PackedInt32Array = PackedInt32Array()   ## current frame
var _sphere_prev:   PackedInt32Array = PackedInt32Array()   ## previous frame

# ---------------------------------------------------------------------------
# Godot callbacks
# ---------------------------------------------------------------------------

func _ready() -> void:
	_setup_step_materials()
	_setup_line_mesh()
	_setup_sphere_pool()

func _process(delta: float) -> void:
	# Hide only the spheres and labels that were active last frame, per type.
	for ti in _sphere_pools.size():
		var pool:     Array = _sphere_pools[ti]
		var lbl_pool: Array = _label_pools[ti]
		for i in range(_sphere_prev[ti]):
			pool[i].visible     = false
			lbl_pool[i].visible = false
	_sphere_active.fill(0)

	_line_mesh.clear_surfaces()

	# Early-out: nothing to render.
	if is_seeking or _hit_queue.is_empty():
		return

	var now: float       = Time.get_ticks_msec() / 1000.0
	var cam_pos: Vector3 = camera.global_position if is_instance_valid(camera) else Vector3.ZERO
	var to_remove: Array = []

	_line_verts.clear()
	_line_colors.clear()

	for uid in _hit_queue:
		var entry: Dictionary = _hit_queue[uid]

		# Expire entries that have outlived the queue window — only while playing.
		# When paused, entries stay in the queue indefinitely.
		if is_playing and now - entry["wall_time_added"] > QUEUE_LIFETIME:
			to_remove.append(uid)
			continue

		# Visual timer ticks only while playing.  The expiry check lives
		# inside this block intentionally: when paused the timer freezes and
		# paths remain visible until playback resumes.
		if is_playing:
			entry["visual_elapsed"] += delta
			if entry["visual_elapsed"] >= VISUAL_DURATION:
				continue

		var hit_data: Dictionary = entry["hit_data"]
		var steps: Array         = hit_data.get("steps", [])
		if steps.is_empty():
			continue

		# Distance cull against the first armor-plate waypoint.
		var first_pos: Vector3 = steps[0].get("pos", Vector3.ZERO)
		if (first_pos - cam_pos).length_squared() > CULL_DIST_SQ:
			continue

		# Build waypoint list: one entry per armor plate hit + the shell's final position.
		var waypoints: Array = []
		for step in steps:
			waypoints.append(step.get("pos", Vector3.ZERO))
		waypoints.append(hit_data.get("final_pos", Vector3.ZERO))

		# Color index for the final stop — derived from final_hit_type (HitResult enum).
		var final_fht: int = hit_data.get("final_hit_type", 0)
		var final_ci: int  = FINAL_HIT_TO_RES[clampi(final_fht, 0, FINAL_HIT_TO_RES.size() - 1)]

		for i in range(waypoints.size()):
			var wp: Vector3  = waypoints[i]
			var is_final: bool = (i == waypoints.size() - 1)
			var ci: int
			if is_final:
				ci = final_ci
			else:
				ci = _step_res_index(steps[i])

			# Accumulate a line segment to the next waypoint (colored by the plate just hit).
			if i + 1 < waypoints.size():
				_line_verts.append(wp)
				_line_verts.append(waypoints[i + 1])
				_line_colors.append(STEP_COLORS[ci])
				_line_colors.append(STEP_COLORS[ci])

			# Place a sphere and its info label from the per-type pool.
			var si: int = _sphere_active[ci]
			if si < POOL_SIZE_PER_TYPE:
				var sph: MeshInstance3D = _sphere_pools[ci][si]
				var lbl: Label3D        = _label_pools[ci][si]
				sph.global_position = wp
				# Final stop renders at 2× the per-result scale so it's clearly distinct.
				var s: float = STEP_SCALES[ci] * (2.0 if is_final else 1.0)
				sph.scale   = Vector3(s, s, s)
				sph.visible = true
				# Show step info popup for armor plate hits; hide for the final stop marker.
				if not is_final and show_labels:
					var step      = steps[i]
					var amm: float = step.get("armor_mm",     0.0)
					var emm: float = step.get("effective_mm", 0.0)
					var ang: float = rad_to_deg(step.get("impact_angle", 0.0))
					var pen: float = step.get("pen",          0.0)
					lbl.text            = "%.0f/%.0fmm eff\n%.1f\u00b0 | %.0fmm pen" % [amm, emm, ang, pen]
					lbl.global_position = wp + Vector3(0.0, 1.75 + s * 0.5, 0.0)
					lbl.visible         = true
				else:
					lbl.visible = false
				_sphere_active[ci] = si + 1

	# Build line mesh only if there are vertices to draw — ImmediateMesh
	# panics on surface_end() with an empty vertex list.
	# The material is re-applied every frame alongside the mesh rebuild because
	# clear_surfaces() causes Godot to resize the instance override array to 0,
	# discarding any material set during a previous frame.
	if not _line_verts.is_empty():
		_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		for i in _line_verts.size():
			_line_mesh.surface_set_color(_line_colors[i])
			_line_mesh.surface_add_vertex(_line_verts[i])
		_line_mesh.surface_end()
		# material_override is set once at creation and survives clear_surfaces().
		# No per-frame material assignment needed.

	# Save active counts so next frame knows which spheres to hide.
	for ti in _sphere_pools.size():
		_sphere_prev[ti] = _sphere_active[ti]

	for uid in to_remove:
		_hit_queue.erase(uid)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Called by ReplayPlayback when a SHELL_HIT event fires.
func on_shell_hit(ev: Dictionary) -> void:
	if armor_log_reader == null:
		return
	var uid: int = ev.get("shell_uid", -1)
	if uid <= 0:
		return
	var hit_data: Dictionary = armor_log_reader.get_hit_by_uid(uid)
	if hit_data.is_empty():
		return

	_hit_queue[uid] = {
		"hit_data":        hit_data,
		"wall_time_added": Time.get_ticks_msec() / 1000.0,
		"visual_elapsed":  0.0,
	}

## Called when seeking begins — flush the queue and hide all visuals.
func on_begin_seek() -> void:
	_hit_queue.clear()
	_line_mesh.clear_surfaces()
	for pool in _sphere_pools:
		for sph in pool:
			sph.visible = false
	for lbl_pool in _label_pools:
		for lbl in lbl_pool:
			lbl.visible = false
	_sphere_active.fill(0)
	_sphere_prev.fill(0)

## Called when seeking ends — is_seeking is cleared by the caller.
func on_end_seek() -> void:
	pass

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Build one StandardMaterial3D per result color index.  Never mutated after creation.
## RES_CITADEL gets emission so it glows through geometry.
func _setup_step_materials() -> void:
	for i in STEP_COLORS.size():
		var c: Color = STEP_COLORS[i]
		var mat := StandardMaterial3D.new()
		mat.shading_mode    = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color    = c
		mat.no_depth_test   = true
		mat.render_priority = 1
		if i == RES_CITADEL:
			mat.emission_enabled           = true
			mat.emission                   = c
			mat.emission_energy_multiplier = 2.0
		_step_materials.append(mat)

## Return the RES_* color index for a single armor interaction step.
## Checks is_citadel before falling back to the ArmorResult value.
func _step_res_index(step: Dictionary) -> int:
	if step.get("is_citadel", false):
		return RES_CITADEL
	return clampi(step.get("result", RES_PEN), 0, RES_SHATTER)

func _setup_line_mesh() -> void:
	_line_mesh     = ImmediateMesh.new()
	_line_material = StandardMaterial3D.new()
	_line_material.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.vertex_color_use_as_albedo = true
	_line_material.no_depth_test              = true
	_line_material.render_priority            = 1
	_line_instance = MeshInstance3D.new()
	_line_instance.mesh              = _line_mesh
	_line_instance.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# material_override is a MeshInstance3D node property — it is NOT cleared by
	# ImmediateMesh.clear_surfaces(), so this assignment never needs repeating.
	_line_instance.material_override = _line_material
	add_child(_line_instance)

func _setup_sphere_pool() -> void:
	_sphere_mesh        = SphereMesh.new()
	_sphere_mesh.radius = 0.5
	_sphere_mesh.height = 1.0
	_sphere_active.resize(STEP_COLORS.size())
	_sphere_active.fill(0)
	_sphere_prev.resize(STEP_COLORS.size())
	_sphere_prev.fill(0)
	# One pool per result type.  Each node's material is assigned once here and
	# never changed — eliminating all runtime set_surface_override_material calls.
	# Each sphere gets a sibling Label3D for per-plate info popups.
	for type_idx in STEP_COLORS.size():
		var pool:     Array = []
		var lbl_pool: Array = []
		for _i in range(POOL_SIZE_PER_TYPE):
			var mi := MeshInstance3D.new()
			mi.mesh              = _sphere_mesh
			mi.visible           = false
			mi.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.material_override = _step_materials[type_idx]
			add_child(mi)
			pool.append(mi)

			var lbl := Label3D.new()
			lbl.pixel_size           = 0.001
			lbl.font_size            = 14
			lbl.billboard            = BaseMaterial3D.BILLBOARD_ENABLED
			lbl.no_depth_test        = true
			lbl.fixed_size           = true
			lbl.render_priority      = 1
			lbl.modulate             = STEP_COLORS[type_idx]
			lbl.outline_size         = 4
			lbl.outline_modulate     = Color(0.0, 0.0, 0.0, 0.8)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			lbl.vertical_alignment   = VERTICAL_ALIGNMENT_TOP
			lbl.visible              = false
			add_child(lbl)
			lbl_pool.append(lbl)

		_sphere_pools.append(pool)
		_label_pools.append(lbl_pool)
