# src/client/shell_replay.gd
extends Node

# References to UI elements
@onready var back_button: Button = $CanvasLayer/UIPanel/BackButton
var result_label: Label = null   ## created programmatically in _setup_armor_log_browser

# References to 3D world elements
@onready var world_3d: Node3D = $CanvasLayer/SubViewportContainer/SubViewport/World3D
var ship: Node3D = null  # Will be dynamically spawned
@onready var camera: Camera3D = $CanvasLayer/SubViewportContainer/SubViewport/World3D/Camera3D
@onready var shell_trail: Node3D = $CanvasLayer/SubViewportContainer/SubViewport/World3D/ShellTrail
@onready var sub_viewport: SubViewport = $CanvasLayer/SubViewportContainer/SubViewport
@onready var sub_viewport_container: SubViewportContainer = $CanvasLayer/SubViewportContainer

# Shell representation
var shell: MeshInstance3D
var shell_material: StandardMaterial3D

# Replay state
var events: Array = []
var current_event_index: int = 0
var is_playing: bool = false
var playback_speed: float = 0.1  # Time between events in seconds
var time_accumulator: float = 0.0

# Trail visualization
var trail_points: Array = []
var trail_mesh: ImmediateMesh
var trail_mesh_instance: MeshInstance3D

# Simulated trail visualization
var sim_trail_points: Array = []
var sim_trail_mesh: ImmediateMesh
var sim_trail_mesh_instance: MeshInstance3D

# Hit result tracking
var hit_citadel: bool = false
var over_penetration: bool = false
var last_armor_result: String = ""
var shell_velocity_zero: bool = false

# Validation mode
var is_validating: bool = false
var validation_results: Array = []
var _validation_pending: bool = false
var _validation_shell_data: Dictionary = {}
var _validation_wait_frames: int = 0


# Camera control
var camera_rotation: Vector2 = Vector2.ZERO
var camera_distance: float = 100.0
var camera_target: Vector3 = Vector3.ZERO
var camera_speed: float = 50.0
var rotate_speed: float = 0.005
var zoom_speed: float = 5.0
var is_dragging: bool = false
var last_mouse_pos: Vector2 = Vector2.ZERO

# Armor overlay system
var armor_overlay: ArmorViewportOverlay

# ---------------------------------------------------------------------------
# Armor Log Browser — added programmatically in _ready()
# ---------------------------------------------------------------------------
var _armor_log_reader: ArmorLogReader = null
var _armor_hits_list:  ItemList       = null
var _armor_log_hits:   Array          = []   ## Array[Dictionary], parsed hits (master, never filtered)
var _filtered_hits:    Array          = []   ## Array[Dictionary], after applying active filters
var _armor_log_file_dialog: FileDialog = null
var _current_ship_scene_path: String = ""   ## scene path of the currently loaded ship
var _vis: ArmorTrailVisualizer = null   ## shows selected hit path in World3D
var _filter_victim_btn: OptionButton = null  ## victim ship filter
var _filter_result_btn: OptionButton = null  ## hit result filter
var _filter_count_lbl:  Label        = null  ## "X / Y hits" counter

## Result type int -> readable string (matches ArmorInteraction.HitResult)
const _HIT_RESULT_NAMES: Array = [
	"PENETRATION", "PARTIAL_PEN", "RICOCHET", "OVERPENETRATION",
	"SHATTER", "CITADEL", "CITADEL_OVERPEN", "WATER", "TERRAIN"
]
## Step result int -> readable string (matches ArmorInteraction.ArmorResult)
const _STEP_RESULT_NAMES: Array = [
	"RICOCHET", "OVERPEN", "PEN", "PARTIAL_PEN", "SHATTER"
]

func _ready():
	# Connect button signals
	back_button.pressed.connect(_on_back_pressed)

	# Create shell mesh
	create_shell()

	# Create trail mesh
	create_trail_mesh()

	# Initially hide the shell
	shell.visible = false

	# Initialize camera
	camera_rotation = Vector2(-PI / 6, 0)  # Start with slight downward angle
	update_camera_transform()

	# Armor path visualizer — shows selected armor log hit as lines + spheres.
	_vis = ArmorTrailVisualizer.new()
	_vis.camera    = camera
	_vis.is_playing  = false
	_vis.is_seeking  = false
	world_3d.add_child(_vis)

	# Setup armor overlay in embedded mode — overlay composites inside the
	# SubViewportContainer alongside the 3D SubViewport
	_setup_armor_overlay()

	_setup_armor_log_browser()

func _setup_armor_overlay():
	armor_overlay = ArmorViewportOverlay.new()
	armor_overlay.name = "ArmorViewportOverlay"
	# Add to tree first so _ready fires and loads the opaque material,
	# then immediately call setup_embedded to replace the standalone setup
	add_child(armor_overlay)
	armor_overlay.setup_embedded(camera, sub_viewport_container, sub_viewport)

# ---------------------------------------------------------------------------
# Armor Log Browser Setup
# ---------------------------------------------------------------------------

func _setup_armor_log_browser() -> void:
	var vbox: VBoxContainer = $CanvasLayer/UIPanel/VBoxContainer

	# Row: Load button + file path label
	var hbox := HBoxContainer.new()
	vbox.add_child(hbox)

	var load_btn := Button.new()
	load_btn.text = "Load Armor Log"
	load_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	load_btn.pressed.connect(_on_load_armor_log_pressed)
	hbox.add_child(load_btn)

	var path_lbl := Label.new()
	path_lbl.text = "No file loaded"
	path_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_lbl.clip_text = true
	path_lbl.name = "ArmorLogPathLabel"
	hbox.add_child(path_lbl)

	# Row: Victim filter
	var vic_row := HBoxContainer.new()
	vbox.add_child(vic_row)
	var vic_lbl := Label.new()
	vic_lbl.text = "Victim:"
	vic_lbl.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	vic_row.add_child(vic_lbl)
	_filter_victim_btn = OptionButton.new()
	_filter_victim_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter_victim_btn.item_selected.connect(_on_filter_changed)
	_filter_victim_btn.add_item("All Victims")
	_filter_victim_btn.disabled = true
	vic_row.add_child(_filter_victim_btn)

	# Row: Result filter
	var res_row := HBoxContainer.new()
	vbox.add_child(res_row)
	var res_lbl := Label.new()
	res_lbl.text = "Result:"
	res_lbl.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	res_row.add_child(res_lbl)
	_filter_result_btn = OptionButton.new()
	_filter_result_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter_result_btn.item_selected.connect(_on_filter_changed)
	_filter_result_btn.add_item("All Results")
	_filter_result_btn.disabled = true
	res_row.add_child(_filter_result_btn)

	# Count label: "X / Y hits"
	_filter_count_lbl = Label.new()
	_filter_count_lbl.text = ""
	_filter_count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vbox.add_child(_filter_count_lbl)

	# Hits list — expands to fill available sidebar height
	_armor_hits_list = ItemList.new()
	_armor_hits_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_armor_hits_list.item_selected.connect(_on_armor_hit_selected)
	vbox.add_child(_armor_hits_list)

	# One-line summary label shown below the list when a hit is selected
	result_label = Label.new()
	result_label.text = ""
	result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result_label.custom_minimum_size = Vector2(0, 48)
	vbox.add_child(result_label)

	# FileDialog
	_armor_log_file_dialog = FileDialog.new()
	_armor_log_file_dialog.file_mode   = FileDialog.FILE_MODE_OPEN_FILE
	_armor_log_file_dialog.access      = FileDialog.ACCESS_FILESYSTEM
	_armor_log_file_dialog.add_filter("*.armorlog", "Armor Log Files")
	_armor_log_file_dialog.current_dir = ProjectSettings.globalize_path("user://replays")
	_armor_log_file_dialog.file_selected.connect(_on_armor_log_file_selected)
	add_child(_armor_log_file_dialog)

func _on_load_armor_log_pressed() -> void:
	_armor_log_file_dialog.popup_centered_ratio(0.6)

func _on_armor_log_file_selected(path: String) -> void:
	_armor_log_reader = ArmorLogReader.new()
	var err: Error = _armor_log_reader.load_file(path)
	if err != OK:
		result_label.text = "Failed to load armor log (error %d)" % err
		_armor_log_reader = null
		return

	# Master list — sorted by timestamp, never filtered.
	_armor_log_hits = _armor_log_reader.hits_by_uid.values()
	_armor_log_hits.sort_custom(func(a, b): return a.get("timestamp", 0.0) < b.get("timestamp", 0.0))

	_populate_filter_dropdowns()
	_rebuild_filter()

	# Update path label
	var path_lbl: Label = get_node_or_null("CanvasLayer/UIPanel/VBoxContainer/ArmorLogPathLabel")
	if path_lbl:
		path_lbl.text = path.get_file()

	_vis.armor_log_reader = _armor_log_reader

func _populate_filter_dropdowns() -> void:
	# --- Victim dropdown ---
	_filter_victim_btn.clear()
	_filter_victim_btn.add_item("All Victims")  # index 0 — always means "no filter"
	# Collect unique victim_ship_id → player_name pairs, then sort by player name.
	var seen_victims: Dictionary = {}  # ship_id → player_name
	for hit in _armor_log_hits:
		var vid: int         = hit.get("victim_ship_id", 255)
		var vname: String    = hit.get("victim_player_name", "?")
		seen_victims[vid] = vname
	var victim_pairs: Array = seen_victims.keys()
	victim_pairs.sort_custom(func(a, b): return seen_victims[a] < seen_victims[b])
	for vid in victim_pairs:
		_filter_victim_btn.add_item(seen_victims[vid], vid)  # explicit ship_id as item id
	_filter_victim_btn.select(0)
	_filter_victim_btn.disabled = false

	# --- Result dropdown ---
	_filter_result_btn.clear()
	_filter_result_btn.add_item("All Results")  # index 0 — always means "no filter"
	# Collect only results that appear in this log, in HitResult order.
	var seen_results: Dictionary = {}  # hit_type_int → true
	for hit in _armor_log_hits:
		seen_results[hit.get("final_hit_type", 0)] = true
	for ht in range(_HIT_RESULT_NAMES.size()):
		if seen_results.has(ht):
			_filter_result_btn.add_item(_HIT_RESULT_NAMES[ht], ht)  # explicit HitResult int as item id
	_filter_result_btn.select(0)
	_filter_result_btn.disabled = false

func _on_filter_changed(_idx: int) -> void:
	_rebuild_filter()

func _rebuild_filter() -> void:
	# Index 0 is always the "All" entry — selected==0 means no filter on that axis.
	var vic_sel: int = _filter_victim_btn.selected
	var res_sel: int = _filter_result_btn.selected
	var vic_id: int  = -1 if vic_sel <= 0 else _filter_victim_btn.get_item_id(vic_sel)
	var res_id: int  = -1 if res_sel <= 0 else _filter_result_btn.get_item_id(res_sel)

	_filtered_hits = []
	for hit in _armor_log_hits:
		if vic_id != -1 and hit.get("victim_ship_id", 255) != vic_id:
			continue
		if res_id != -1 and hit.get("final_hit_type", 0) != res_id:
			continue
		_filtered_hits.append(hit)

	_filter_count_lbl.text = "%d / %d hits" % [_filtered_hits.size(), _armor_log_hits.size()]
	_populate_hits_list()

func _populate_hits_list() -> void:
	_armor_hits_list.clear()
	for hit in _filtered_hits:
		var ts: float        = hit.get("timestamp", 0.0)
		var ht: int          = hit.get("final_hit_type", 0)
		var steps: Array     = hit.get("steps", [])
		var cal: float       = hit.get("caliber", 0.0)
		var att_name: String = hit.get("attacker_name", "?")
		var st: int          = hit.get("shell_type", 1)  # 0=HE, 1=AP
		var stype_str: String = "HE" if st == 0 else "AP"
		var ht_name: String  = _HIT_RESULT_NAMES[clampi(ht, 0, _HIT_RESULT_NAMES.size() - 1)]
		_armor_hits_list.add_item("T+%.1fs  %s:%s:%.0fmm  %-14s  %d plates" % [
			ts, att_name, stype_str, cal, ht_name, steps.size()])

func _on_armor_hit_selected(idx: int) -> void:
	if idx < 0 or idx >= _filtered_hits.size():
		return
	var hit: Dictionary = _filtered_hits[idx]

	# Load the victim ship from the scene path stored in the armor log.
	# Reuse the existing instance if it's already the correct ship type.
	var scene_path: String = hit.get("victim_scene_path", "")
	if scene_path != "":
		if scene_path != _current_ship_scene_path:
			if ship != null and is_instance_valid(ship):
				ship.queue_free()
				ship = null
			var ship_scene = load(scene_path)
			if ship_scene != null:
				ship = ship_scene.instantiate()
				world_3d.add_child(ship)
				if ship is RigidBody3D:
					ship.gravity_scale = 0.0
					ship.freeze = true
				_enable_armor_overlay(ship)
				_current_ship_scene_path = scene_path
		if ship != null and is_instance_valid(ship):
			ship.global_position = Vector3(
				hit.get("victim_pos_x", 0.0),
				ship.global_position.y,
				hit.get("victim_pos_z", 0.0))
			ship.rotation.y = hit.get("victim_rot_y", 0.0)

	# Show armor path in 3D — clear previous, then display selected hit.
	_vis.on_begin_seek()
	_vis.on_shell_hit({"shell_uid": hit.get("shell_uid", -1)})

	# Focus camera on the centroid of the hit's waypoints.
	var steps: Array    = hit.get("steps", [])
	var final_pos: Vector3 = hit.get("final_pos", Vector3.ZERO)
	var center: Vector3 = final_pos
	for step in steps:
		center += step.get("pos", Vector3.ZERO)
	if steps.size() > 0:
		center /= float(steps.size() + 1)
	camera_target   = center
	camera_distance = 30.0
	update_camera_transform()

	# Show a brief summary — full details are visible in the 3D view.
	var ht_name: String = _HIT_RESULT_NAMES[clampi(hit.get("final_hit_type", 0), 0, _HIT_RESULT_NAMES.size() - 1)]
	var st_sel: int = hit.get("shell_type", 1)
	var type_name_sel: String = "HE" if st_sel == 0 else "AP"
	var vic_pname: String = hit.get("victim_player_name", "?")
	var vic_sname: String = hit.get("victim_name", "?")
	result_label.text = "T+%.1fs  %s %s  (%d plates)  victim: %s (%s)" % [
		hit.get("timestamp", 0.0), type_name_sel, ht_name,
		steps.size(), vic_pname, vic_sname]

func _format_hit_details(hit: Dictionary) -> String:
	var lines: PackedStringArray = PackedStringArray()

	var ts: float    = hit.get("timestamp", 0.0)
	var ht: int      = hit.get("final_hit_type", 0)
	var vx: float    = hit.get("victim_pos_x", 0.0)
	var vz: float    = hit.get("victim_pos_z", 0.0)
	var vy: float    = hit.get("victim_rot_y", 0.0)
	var fpos: Vector3 = hit.get("final_pos", Vector3.ZERO)
	var steps: Array  = hit.get("steps", [])
	var ht_name: String = _HIT_RESULT_NAMES[clampi(ht, 0, _HIT_RESULT_NAMES.size() - 1)]

	lines.append("=== Armor Hit @ T+%.2fs ==" % ts)
	lines.append("Result:   %s  [%s]" % [ht_name, "HE" if hit.get("shell_type", 1) == 0 else "AP"])
	lines.append("Attacker: %s (%s)" % [hit.get("attacker_player_name", "?"), hit.get("attacker_name", "?")])
	lines.append("Victim:   %s (%s)" % [hit.get("victim_player_name", "?"), hit.get("victim_name", "?")])
	lines.append("Victim pos: (%.1f, %.1f)  rot_y: %.1f°" % [vx, vz, rad_to_deg(vy)])
	lines.append("Shell stopped at: (%.1f, %.1f, %.1f)" % [fpos.x, fpos.y, fpos.z])
	lines.append("Armor plates hit: %d" % steps.size())
	lines.append("")

	for i in steps.size():
		var s: Dictionary   = steps[i]
		var res: int        = s.get("result", 2)
		var res_name: String = _STEP_RESULT_NAMES[clampi(res, 0, _STEP_RESULT_NAMES.size() - 1)]
		var cit: bool       = s.get("is_citadel", false)
		var amm: float      = s.get("armor_mm", 0.0)
		var emm: float      = s.get("effective_mm", 0.0)
		var ang: float      = rad_to_deg(s.get("impact_angle", 0.0))
		var pen: float      = s.get("pen", 0.0)
		var intg: float     = s.get("integrity", 1.0)
		var path: String    = s.get("armor_path", "?")
		var pos: Vector3    = s.get("pos", Vector3.ZERO)
		var spd: float      = s.get("vel", Vector3.ZERO).length()

		lines.append("[Step %d] %s%s" % [i + 1, res_name, "  [CITADEL]" if cit else ""])
		lines.append("  Part:    %s" % path)
		lines.append("  Armor:   %.0fmm / %.0fmm eff  (angle %.1f°)" % [amm, emm, ang])
		var is_he: bool = hit.get("shell_type", 1) == 0
		if is_he:
			lines.append("  Overmatch: %.0fmm threshold   Speed: %.0f m/s" % [pen, spd])
		else:
			lines.append("  Pen:     %.0fmm   Integrity: %.2f   Speed: %.0f m/s" % [pen, intg, spd])
		lines.append("  Pos:     (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z])
		lines.append("")

	return "\n".join(lines)

func _input(event):
	# Only process camera input when the mouse is over the 3D viewport.
	var mouse_pos: Vector2   = get_viewport().get_mouse_position()
	var vp_rect:   Rect2     = sub_viewport_container.get_global_rect()
	if not vp_rect.has_point(mouse_pos):
		return

	# Handle mouse button for camera rotation
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			is_dragging = event.pressed
			if event.pressed:
				last_mouse_pos = event.position
		# Handle zoom with mouse wheel
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = max(10.0, camera_distance - zoom_speed)
			update_camera_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = min(500.0, camera_distance + zoom_speed)
			update_camera_transform()

	# Handle mouse motion for camera rotation
	if event is InputEventMouseMotion and is_dragging:
		var delta_mouse = event.position - last_mouse_pos
		last_mouse_pos = event.position

		camera_rotation.y -= delta_mouse.x * rotate_speed
		camera_rotation.x = clamp(camera_rotation.x + delta_mouse.y * rotate_speed, -PI / 2, PI / 2)
		update_camera_transform()

func _physics_process(delta: float):
	# Handle WASD camera movement
	var move_input = Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		move_input.z -= 1
	if Input.is_key_pressed(KEY_S):
		move_input.z += 1
	if Input.is_key_pressed(KEY_A):
		move_input.x -= 1
	if Input.is_key_pressed(KEY_D):
		move_input.x += 1
	if Input.is_key_pressed(KEY_Q):
		move_input.y -= 1
	if Input.is_key_pressed(KEY_E):
		move_input.y += 1

	if move_input.length() > 0:
		move_input = move_input.normalized()
		# Transform movement relative to camera rotation
		var forward = Vector3(sin(camera_rotation.y), 0, cos(camera_rotation.y))
		var right = Vector3(cos(camera_rotation.y), 0, -sin(camera_rotation.y))
		camera_target += (forward * move_input.z + right * move_input.x + Vector3.UP * move_input.y) * camera_speed * delta
		call_deferred("update_camera_transform")

	# Handle replay playback
	process_replay(delta)

	# Run pending validation on the physics thread where direct_space_state is safe
	if _validation_pending:
		if _validation_wait_frames > 0:
			_validation_wait_frames -= 1
		else:
			_validation_pending = false
			run_validation_simulation(_validation_shell_data)

func create_shell():
	# Create a simple sphere to represent the shell
	shell = MeshInstance3D.new()
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 0.5
	sphere_mesh.height = 1.0
	shell.mesh = sphere_mesh

	# Create material for the shell
	shell_material = StandardMaterial3D.new()
	shell_material.albedo_color = Color(1.0, 0.5, 0.0)  # Orange color
	shell_material.emission_enabled = true
	shell_material.emission = Color(1.0, 0.3, 0.0)
	shell_material.emission_energy_multiplier = 2.0
	shell_material.no_depth_test = true
	shell_material.render_priority = 2
	shell.material_override = shell_material

	world_3d.add_child(shell)

func create_trail_mesh():
	# Create an ImmediateMesh for drawing the logged trail (yellow/orange)
	trail_mesh = ImmediateMesh.new()
	trail_mesh_instance = MeshInstance3D.new()
	trail_mesh_instance.mesh = trail_mesh

	# Create material for the logged trail
	var trail_material = StandardMaterial3D.new()
	trail_material.albedo_color = Color(1.0, 0.8, 0.0, 0.8)  # Yellow
	trail_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_material.no_depth_test = true
	trail_material.render_priority = 2
	trail_mesh_instance.material_override = trail_material

	shell_trail.add_child(trail_mesh_instance)

	# Create an ImmediateMesh for drawing the simulated trail (cyan/blue)
	sim_trail_mesh = ImmediateMesh.new()
	sim_trail_mesh_instance = MeshInstance3D.new()
	sim_trail_mesh_instance.mesh = sim_trail_mesh

	# Create material for the simulated trail
	var sim_trail_material = StandardMaterial3D.new()
	sim_trail_material.albedo_color = Color(0.0, 0.8, 1.0, 0.8)  # Cyan
	sim_trail_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sim_trail_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sim_trail_material.no_depth_test = true
	sim_trail_material.render_priority = 2
	sim_trail_mesh_instance.material_override = sim_trail_material

	shell_trail.add_child(sim_trail_mesh_instance)

func _on_play_pressed():
	if is_playing:
		# Stop playback
		stop_replay()
	else:
		# Start playback
		start_replay()

func _on_validate_pressed():
	if is_validating:
		# Stop validation
		stop_validation()
	else:
		# Start validation
		start_validation()

func _on_back_pressed():
	get_tree().change_scene_to_file("res://src/port/main_menu/main_menu.tscn")

func start_replay():
	# Text-paste workflow removed — start_replay requires events set externally.
	var input_text: String = ""
	events = ShellEventParser.parse_events(input_text)

	if events.is_empty():
		push_warning("No events parsed from input")
		return

	# Load the ship from the first Ship event
	var ship_scene_path: String = ""
	for event in events:
		if event.event_type == "Ship" and event.data.has("scene_path"):
			ship_scene_path = event.data["scene_path"]
			break

	if ship_scene_path.is_empty():
		push_warning("No ship scene path found in events")
		return

	# Remove old ship if exists
	if ship != null:
		ship.queue_free()
		ship = null

	# Load and instantiate the ship
	var ship_scene = load(ship_scene_path)
	if ship_scene == null:
		push_error("Failed to load ship scene: " + ship_scene_path)
		return

	ship = ship_scene.instantiate()
	world_3d.add_child(ship)

	# Enable armor visualization via dual-viewport overlay
	_enable_armor_overlay(ship)

	# Reset state
	current_event_index = 0
	trail_points.clear()
	time_accumulator = 0.0
	is_playing = true
	shell.visible = true
	hit_citadel = false
	over_penetration = false
	last_armor_result = ""
	shell_velocity_zero = false
	result_label.text = "Result: Processing..."

	# Disable physics on the ship if it's a RigidBody3D
	if ship != null and ship is RigidBody3D:
		ship.gravity_scale = 0.0
		ship.freeze = true

	# Position ship if we have ship data
	if ship != null:
		for event in events:
			if event.event_type == "Ship":
				ship.position = event.data["position"]
				# Rotation is already in radians (x, y, z) = (pitch, yaw, roll)
				var rot = event.data["rotation"]
				ship.rotation = Vector3(rot.x, rot.y, rot.z)
				break

	# Position camera to view the ship and shell trajectory
	update_camera_position()

func _enable_armor_overlay(ship_node: Node) -> void:
	# Hide armor meshes in the 3D SubViewport (they render in the overlay instead)
	_set_armor_visibility_main(ship_node, false)
	armor_overlay.set_main_camera(camera)
	armor_overlay.enable()
	armor_overlay.populate_armor_meshes(ship_node)

func _disable_armor_overlay(ship_node: Node) -> void:
	armor_overlay.disable()
	if ship_node != null:
		_set_armor_visibility_main(ship_node, false)

func _set_armor_visibility_main(node: Node, enabled: bool) -> void:
	if node is MeshInstance3D and String(node.name).contains("_col"):
		node.layers = 1 if enabled else 0
	for child in node.get_children():
		_set_armor_visibility_main(child, enabled)

func stop_replay():
	is_playing = false
	shell.visible = false
	if ship != null:
		_disable_armor_overlay(ship)

func update_camera_transform():
	# Calculate camera position based on target, rotation, and distance
	var offset = Vector3(
		cos(camera_rotation.x) * sin(camera_rotation.y),
		sin(camera_rotation.x),
		cos(camera_rotation.x) * cos(camera_rotation.y)
	) * camera_distance

	camera.position = camera_target + offset
	camera.look_at(camera_target, Vector3.UP)

func process_replay(delta: float):
	if not is_playing:
		return

	time_accumulator += delta

	# Process events at the specified playback speed
	while time_accumulator >= playback_speed and current_event_index < events.size():
		process_event(events[current_event_index])
		current_event_index += 1
		time_accumulator -= playback_speed

		# Check if we've reached the end
		if current_event_index >= events.size():
			is_playing = false
			calculate_final_result()
			break

func process_event(event):
	match event.event_type:
		"Ship":
			# Update ship position/rotation if needed
			ship.position = event.data["position"]
			var rot = event.data["rotation"]
			ship.rotation = Vector3(rot.x, rot.y, rot.z)

		"Shell":
			# Update shell position
			var pos = event.data["position"]
			shell.position = pos

			# Track if shell stopped
			if event.data.has("velocity"):
				var vel = event.data["velocity"]
				if vel.length() < 0.1:
					shell_velocity_zero = true

			# Add to trail
			trail_points.append(pos)
			update_trail()

			# Optionally rotate shell to face velocity direction
			if event.data.has("velocity"):
				var vel = event.data["velocity"]
				if vel.length() > 0.1:
					shell.look_at(pos + vel.normalized(), Vector3.UP)

		"Armor":
			# Create a visual indicator at the impact point
			# We'll use the last shell position as the impact point
			if trail_points.size() > 0:
				var impact_pos = trail_points[-1]
				create_impact_marker(impact_pos, event.data["result"])

			# Track hit results
			last_armor_result = event.data["result"]
			var is_citadel_armor = event.data.get("is_citadel", false)

			if is_citadel_armor:
				hit_citadel = true

			if event.data["result"] == "OVERPEN":
				over_penetration = true

func update_trail():
	# Redraw the logged trail using ImmediateMesh
	trail_mesh.clear_surfaces()

	if trail_points.size() < 2:
		return

	trail_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)

	for point in trail_points:
		trail_mesh.surface_add_vertex(point)

	trail_mesh.surface_end()

func update_sim_trail():
	# Redraw the simulated trail using ImmediateMesh
	sim_trail_mesh.clear_surfaces()

	if sim_trail_points.size() < 2:
		return

	sim_trail_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)

	for point in sim_trail_points:
		sim_trail_mesh.surface_add_vertex(point)

	sim_trail_mesh.surface_end()

func create_impact_marker(position: Vector3, result: String):
	# Create a small sphere at the impact point
	var marker = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	marker.mesh = sphere

	# Color based on result type
	var material = StandardMaterial3D.new()
	match result:
		"OVERPEN":
			material.albedo_color = Color(0.5, 0.5, 1.0)  # Blue
		"RICOCHET":
			material.albedo_color = Color(1.0, 1.0, 0.0)  # Yellow
		"SHATTER":
			material.albedo_color = Color(0.5, 0.5, 0.5)  # Gray
		"PENETRATION":
			material.albedo_color = Color(1.0, 0.0, 0.0)  # Red
		_:
			material.albedo_color = Color(1.0, 1.0, 1.0)  # White

	material.emission_enabled = true
	material.emission = material.albedo_color
	material.emission_energy_multiplier = 1.5
	material.no_depth_test = true
	material.render_priority = 2
	marker.material_override = material

	marker.position = position
	shell_trail.add_child(marker)

func update_camera_position():
	# Calculate bounds of the trajectory
	if trail_points.is_empty() and events.is_empty():
		return

	var min_pos = Vector3.ZERO
	var max_pos = Vector3.ZERO
	var has_points = false

	# Get ship position
	if ship != null:
		min_pos = ship.position
		max_pos = ship.position
		has_points = true

	# Get all shell positions to calculate bounds
	for event in events:
		if event.event_type == "Shell":
			var pos = event.data["position"]
			if not has_points:
				min_pos = pos
				max_pos = pos
				has_points = true
			else:
				min_pos.x = min(min_pos.x, pos.x)
				min_pos.y = min(min_pos.y, pos.y)
				min_pos.z = min(min_pos.z, pos.z)
				max_pos.x = max(max_pos.x, pos.x)
				max_pos.y = max(max_pos.y, pos.y)
				max_pos.z = max(max_pos.z, pos.z)

	if has_points:
		# Calculate center and size
		var center = (min_pos + max_pos) / 2.0
		var size = (max_pos - min_pos).length()

		# Set camera target and distance to view the entire scene
		camera_target = center
		camera_distance = max(size * 1.5, 50.0)
		update_camera_transform()

func calculate_final_result():
	# Replicate the logic from ArmorInteraction.gd to determine final hit result
	# This needs to match the exact logic from process_hit() around line 370-390

	var final_result = "UNKNOWN"

	if ship == null:
		result_label.text = "Final Result: NO SHIP"
		return

	# Get the final shell position
	var final_shell_pos = trail_points[-1] if trail_points.size() > 0 else Vector3.ZERO

	var d = PrecisionPhysicsWorld.precision_get_part_hit(ship, final_shell_pos)

	# var damage_result = ArmorInteraction.HitResult.WATER
	# final_result = "WATER"
	# Check definitive outcomes first (shatter/ricochet)
	if over_penetration:
		final_result = "OVERPENETRATION"
	elif last_armor_result == "SHATTER":
		final_result = "SHATTER"
	elif last_armor_result == "RICOCHET":
		final_result = "RICOCHET"
	# Then check penetration depth
	if d != null and (d.is_citadel or d.armor_path.find("Citadel") != -1):
		final_result = "CITADEL"
	elif hit_citadel: # overpen citadel but still could be inside hull
		final_result = "CITADEL OVERPEN"
	elif d != null: # inside hull
		final_result = "PENETRATION"

	# Update the label with color coding
	result_label.text = "Final Result: " + str(final_result)

	# Color code the result
	match final_result:
		"CITADEL":
			result_label.add_theme_color_override("font_color", Color.RED)
		"CITADEL OVERPEN":
			result_label.add_theme_color_override("font_color", Color.ORANGE)
		"PENETRATION":
			result_label.add_theme_color_override("font_color", Color.DARK_RED)
		"OVERPENETRATION":
			result_label.add_theme_color_override("font_color", Color.BLUE)
		"RICOCHET":
			result_label.add_theme_color_override("font_color", Color.YELLOW)
		"SHATTER":
			result_label.add_theme_color_override("font_color", Color.GRAY)
		_:
			result_label.add_theme_color_override("font_color", Color.WHITE)

#region Validation Mode

func start_validation():
	var input_text: String = ""
	events = ShellEventParser.parse_events(input_text)

	if events.is_empty():
		push_warning("start_validation: no events (text-paste workflow removed)")
		return

	# Load the ship
	var ship_scene_path: String = ""
	for event in events:
		if event.event_type == "Ship" and event.data.has("scene_path"):
			ship_scene_path = event.data["scene_path"]
			break

	if ship_scene_path.is_empty():
		return

	# Remove old ship if exists
	if ship != null:
		ship.queue_free()
		ship = null

	# Load and instantiate the ship
	var ship_scene = load(ship_scene_path)
	if ship_scene == null:
		return

	ship = ship_scene.instantiate()
	world_3d.add_child(ship)

	# Enable armor visualization via dual-viewport overlay
	_enable_armor_overlay(ship)

	# Place ship at its logged world position and rotation.
	for event in events:
		if event.event_type == "Ship":
			ship.position = event.data["position"]
			var rot = event.data["rotation"]
			ship.rotation = Vector3(rot.x, rot.y, rot.z)
			break

	# Disable physics on the ship
	if ship is RigidBody3D:
		ship.gravity_scale = 0.0
		ship.freeze = true

	# Extract shell parameters from events
	var shell_params = extract_shell_params()
	if shell_params == null:
		return

	# Position camera to view the ship and shell trajectory
	update_camera_position()

	# Clear simulated trail
	sim_trail_points.clear()
	update_sim_trail()

	# Defer the actual simulation to _physics_process where direct_space_state
	# is safe to access (project uses a separate physics thread).
	# Wait 2 physics frames so the ship's collision shapes are flushed into
	# the physics server before we raycast against them.
	_validation_shell_data = shell_params
	_validation_wait_frames = 2
	_validation_pending = true

	is_validating = true

func stop_validation():
	_validation_pending = false
	_validation_shell_data = {}
	_validation_wait_frames = 0

	# if ship != null:
	# 	_disable_armor_overlay(ship)
	is_validating = false

func extract_shell_params() -> Dictionary:
	# Extract initial shell state from the first Shell event
	var first_shell_event = null

	for event in events:
		if event.event_type == "Shell":
			first_shell_event = event
			break

	if first_shell_event == null:
		return {}

	# Find the "Processing Shell" event which now contains all shell parameters
	var processing_event = null
	for event in events:
		if event.event_type == "Processing Shell":
			processing_event = event
			break

	var params: ShellParams = null

	# If the Processing Shell event has the full parameter set, use it directly
	if processing_event != null and processing_event.data.has("speed"):
		print("[ShellReplay] Constructing ShellParams from Processing Shell event data")
		params = ShellParams.new()
		params.caliber = float(processing_event.data["caliber"])
		params.type = int(processing_event.data["shell_type"])
		params.speed = float(processing_event.data["speed"])
		params.drag = float(processing_event.data["drag"])
		params.damage = float(processing_event.data["damage"])
		params.size = float(processing_event.data["size"])
		params.mass = float(processing_event.data["mass"])
		params.fire_buildup = float(processing_event.data["fire_buildup"])
		params.fuze_delay = float(processing_event.data["fuze_delay"])
		params.penetration_modifier = float(processing_event.data["pen_mod"])
		params.auto_bounce = deg_to_rad(float(processing_event.data["auto_bounce"]))
		params.ricochet_angle = deg_to_rad(float(processing_event.data["ricochet_angle"]))
		params.overmatch = int(processing_event.data["overmatch"])
		params.arming_threshold = int(processing_event.data["arming_threshold"])

	# Fallback: hardcoded 460mm AP shell parameters (Yamato)
	if params == null:
		print("[ShellReplay] Using fallback hardcoded 460mm AP shell parameters")
		params = ShellParams.new()
		params.speed = 780.0
		params.drag = 1.8e-05
		params.damage = 14500.0
		params.size = 4.6
		params.caliber = 460.0
		params.mass = 1460.0
		params.fire_buildup = 0.0
		params.fuze_delay = 0.035
		params.type = ShellParams.ShellType.AP
		params.penetration_modifier = 1.0
		params.auto_bounce = deg_to_rad(60.0)
		params.ricochet_angle = deg_to_rad(45.0)
		params.overmatch = 32
		params.arming_threshold = 76

	# Get position and velocity from first shell event
	var hit_pos: Vector3 = first_shell_event.data["position"]
	var vel: Vector3 = first_shell_event.data["velocity"]

	# Time step: 1/20 second
	const TIME_STEP = 1.0 / 20.0

	# The first Shell event position is already at the armor surface.
	# Place prev_pos a full timestep back so the ray starts well before the
	# hull, and current_pos a full timestep forward so it passes through.
	var prev_pos = hit_pos - vel * TIME_STEP

	# If prev_pos ended up underwater, extend it further back along the
	# trajectory so it's above the surface.  Water-drag detection relies on
	# prev_pos.y > 0 to know the shell crossed the waterline.
	if prev_pos.y < 0.0 and vel.y < -0.001:
		# Solve for t where (hit_pos - vel * t).y = 1.0  (1 m above surface for margin)
		var t_surface := (hit_pos.y - 1.0) / vel.y
		if t_surface > 0.0:
			prev_pos = hit_pos - vel * t_surface

	var current_pos = hit_pos + vel * TIME_STEP

	return {
		"params": params,
		"prev_pos": prev_pos,
		"current_pos": current_pos,
		"velocity": vel,
		"time_step": TIME_STEP
	}

func run_validation_simulation(shell_data: Dictionary):
	# This function MUST run inside _physics_process because the project uses
	# a separate physics thread and PhysicsDirectSpaceState3D is only safe to
	# access from the physics thread.
	validation_results.clear()

	# Create ProjectileData (now a standalone C++ class, not nested in ProjectileManager)
	var projectile = ProjectileData.new()
	var _ship = Ship.new()
	projectile.initialize(
		shell_data["prev_pos"],
		shell_data["velocity"],
		0.0,
		shell_data["params"],
		_ship,
		[]
	)
	# Set frame_count > 0 so process_travel applies its 10m backward ray
	# extension, matching what happens for in-flight shells in the real game.
	projectile.frame_count = 1

	var space_state = world_3d.get_world_3d().direct_space_state

	# Set current position from shell data
	var prev_pos = shell_data["prev_pos"]
	projectile.position = shell_data["current_pos"]
	var time_step: float = shell_data["time_step"]

	var sim_events: Array = []
	var result = ArmorInteraction.process_travel(projectile, prev_pos, time_step, space_state, sim_events)

	# Visualization and UI updates must happen on the main thread, so defer them
	call_deferred("_on_validation_complete", sim_events, result)

func _on_validation_complete(sim_events: Array, result):
	# Called on the main thread after physics simulation completes.
	# Visualize both trajectories
	visualize_trajectories(sim_events)

	# Print results from both logged events and simulated events
	print_comparison_results(sim_events, result)

func visualize_trajectories(sim_events: Array):
	# Visualize logged trajectory using world-space positions directly.
	trail_points.clear()
	for event in events:
		process_event(event)

	# Extract and visualize simulated trajectory from events
	sim_trail_points.clear()
	for event_str in sim_events:
		# Parse position from event strings like "Shell: ... pos=(x, y, z)"
		if event_str is String and event_str.contains("pos=(") and event_str.contains("Shell:"):
			var pos_start = event_str.find("pos=(") + 5
			var pos_end = event_str.find(")", pos_start)
			var pos_str = event_str.substr(pos_start, pos_end - pos_start)
			var parts = pos_str.split(",")
			if parts.size() >= 3:
				var pos = Vector3(
					float(parts[0].strip_edges()),
					float(parts[1].strip_edges()),
					float(parts[2].strip_edges())
				)
				sim_trail_points.append(pos)

		# Create markers for simulated armor hits
		if event_str is String and event_str.contains("Armor:"):
			# Parse result type
			var result_start = event_str.find("Armor: ") + 7
			var result_end = event_str.find(",", result_start)
			if result_end != -1:
				var result_type = event_str.substr(result_start, result_end - result_start).strip_edges()
				# Use the last position as the impact point
				if sim_trail_points.size() > 0:
					create_impact_marker(sim_trail_points[-1], result_type)

	update_sim_trail()

	# Update camera to view both trajectories
	update_camera_for_both_trajectories()

func update_camera_for_both_trajectories():
	# Calculate bounds of both trajectories
	var all_points: Array = []
	all_points.append_array(trail_points)
	all_points.append_array(sim_trail_points)

	if all_points.is_empty():
		return

	var min_pos = all_points[0]
	var max_pos = all_points[0]

	for pos in all_points:
		min_pos.x = min(min_pos.x, pos.x)
		min_pos.y = min(min_pos.y, pos.y)
		min_pos.z = min(min_pos.z, pos.z)
		max_pos.x = max(max_pos.x, pos.x)
		max_pos.y = max(max_pos.y, pos.y)
		max_pos.z = max(max_pos.z, pos.z)

	# Include ship position if available
	if ship != null:
		min_pos.x = min(min_pos.x, ship.position.x)
		min_pos.y = min(min_pos.y, ship.position.y)
		min_pos.z = min(min_pos.z, ship.position.z)
		max_pos.x = max(max_pos.x, ship.position.x)
		max_pos.y = max(max_pos.y, ship.position.y)
		max_pos.z = max(max_pos.z, ship.position.z)

	# Calculate center and size
	var center = (min_pos + max_pos) / 2.0
	var size = (max_pos - min_pos).length()

	# Set camera target and distance to view the entire scene
	camera_target = center
	camera_distance = max(size * 1.5, 50.0)
	update_camera_transform()

func print_comparison_results(sim_events: Array, sim_result):
	print("\\n========== SHELL REPLAY VALIDATION ==========")
	print("\\n--- LOGGED EVENTS ---")

	for event in events:
		match event.event_type:
			"Processing Shell":
				print("Processing Shell: %s" % event.data.get("shell_info", ""))
			"Ship":
				print("Ship: %s pos=(%.15f, %.15f, %.15f), rot=(%.10f, %.10f, %.10f), scene=%s" % [
					event.data.get("name", ""),
					event.data["position"].x, event.data["position"].y, event.data["position"].z,
					event.data["rotation"].x, event.data["rotation"].y, event.data["rotation"].z,
					event.data.get("scene_path", "")
				])
			"Shell":
				print("Shell: speed=%.15f vel=(%.15f, %.15f, %.15f) m/s, fuze=%.3f s, pos=(%.15f, %.15f, %.15f), pen: %.1f" % [
					event.data["speed"],
					event.data["velocity"].x, event.data["velocity"].y, event.data["velocity"].z,
					event.data["fuze"],
					event.data["position"].x, event.data["position"].y, event.data["position"].z,
					event.data["penetration"]
				])
			"Armor":
				print("Armor: %s, %s with %.1f/%.1fmm (angle %.1f°), is_citadel: %s" % [
					event.data["result"],
					event.data["part"],
					event.data["armor_thickness"],
					event.data["effective_thickness"],
					event.data["angle"],
					event.data.get("is_citadel", false)
				])
			"Final Hit Result":
				print("Final Hit Result: %s" % event.data["result"])

	print("\\n--- SIMULATED EVENTS ---")

	for event_str in sim_events:
		print(event_str)

	if sim_result != null:
		var result_name = ArmorInteraction.HitResult.keys()[sim_result.result_type]
		print("Final Simulated Result: %s" % result_name)
		if sim_result.armor_part != null:
			print("  Armor Part: %s (citadel: %s)" % [
				sim_result.armor_part.armor_path,
				sim_result.armor_part.is_citadel
			])
		print("  Position: (%.1f, %.1f, %.1f)" % [
			sim_result.explosion_position.x,
			sim_result.explosion_position.y,
			sim_result.explosion_position.z
		])
	else:
		print("Final Simulated Result: NO HIT")

	print("\\n==========================================\\n")

	print("Validation: See console for detailed comparison")

#endregion
