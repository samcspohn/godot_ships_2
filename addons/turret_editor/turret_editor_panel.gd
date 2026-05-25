# addons/turret_editor/turret_editor_panel.gd
@tool
extends Control

var plugin: EditorPlugin
var turret: Turret
var undo_redo: EditorUndoRedoManager
var last_min_angle: float = 0.0
var last_max_angle: float = 0.0
var _last_fire_arc_count: int = -1
var _suppress_arc_signals: bool = false

# Mirror state — purely editor-side; never serialized into the ship/scene.
var partner: Turret = null
var mirroring_enabled: bool = false
const MIRROR_POSITION_TOLERANCE: float = 0.5     # meters
const MIRROR_CENTERLINE_THRESHOLD: float = 0.5   # meters; |x| < this disables mirror
const MIRROR_ANGLE_EPS: float = 1.0e-3           # radians (~0.06°)

# Slew limit UI
@onready var slew_limits_enabled = $VBoxContainer/RotationLimits/EnabledContainer/EnabledCheckBox
@onready var min_angle_spinner = $VBoxContainer/RotationLimits/MinAngleContainer/MinAngleSpinBox
@onready var max_angle_spinner = $VBoxContainer/RotationLimits/MaxAngleContainer/MaxAngleSpinBox
@onready var apply_button = $VBoxContainer/ApplyButton
@onready var debug_info = $VBoxContainer/DebugContainer/DebugInfo

# Fire arc UI
@onready var convert_expand_button = $VBoxContainer/ConvertExpandButton
@onready var fire_arc_add_button = $VBoxContainer/FireArcsSection/HeaderRow/AddButton
@onready var fire_arc_clear_button = $VBoxContainer/FireArcsSection/HeaderRow/ClearButton
@onready var fire_arcs_list = $VBoxContainer/FireArcsSection/ArcsList

# Mirror UI
@onready var mirror_section = $VBoxContainer/MirrorSection
@onready var mirror_checkbox = $VBoxContainer/MirrorSection/MirrorRow/MirrorCheckBox
@onready var mirror_partner_label = $VBoxContainer/MirrorSection/MirrorRow/MirrorPartnerLabel

func _ready():
	undo_redo = EditorInterface.get_editor_undo_redo()

	min_angle_spinner.min_value = 0
	min_angle_spinner.max_value = 360
	max_angle_spinner.min_value = 0
	max_angle_spinner.max_value = 360

	slew_limits_enabled.toggled.connect(_on_rotation_limits_toggled)
	min_angle_spinner.value_changed.connect(_on_min_angle_changed)
	max_angle_spinner.value_changed.connect(_on_max_angle_changed)
	apply_button.pressed.connect(_on_apply_pressed)
	convert_expand_button.pressed.connect(_on_convert_expand_pressed)
	fire_arc_add_button.pressed.connect(_on_add_fire_arc_pressed)
	fire_arc_clear_button.pressed.connect(_on_clear_fire_arcs_pressed)
	mirror_checkbox.toggled.connect(_on_mirror_toggled)

func _process(_delta):
	if not is_instance_valid(turret):
		return
	# Slew angle sync
	var current_min_angle = rad_to_deg_0_360(turret.slew_min_angle)
	var current_max_angle = rad_to_deg_0_360(turret.slew_max_angle)
	if abs(current_min_angle - last_min_angle) > 0.01:
		min_angle_spinner.set_value_no_signal(current_min_angle)
		last_min_angle = current_min_angle
	if abs(current_max_angle - last_max_angle) > 0.01:
		max_angle_spinner.set_value_no_signal(current_max_angle)
		last_max_angle = current_max_angle
	# Rebuild fire arc rows when the array shape changes (add/remove/external edit).
	if turret.fire_arcs.size() != _last_fire_arc_count:
		_rebuild_fire_arc_rows()
	else:
		_sync_fire_arc_row_values()
	# Convert button: disabled when slew_limits off, when current rotation is
	# already inside the slew arc, or when the slew arc is the "not configured"
	# sentinel (slew_min == slew_max).
	convert_expand_button.disabled = not _convert_expand_available()
	_refresh_mirror_tracking()
	_update_default_debug_info()

func rad_to_deg_0_360(rad_value: float) -> float:
	var deg_value = rad_to_deg(rad_value)
	while deg_value < 0:
		deg_value += 360
	while deg_value >= 360:
		deg_value -= 360
	return deg_value

func deg_0_360_to_rad(deg_value: float) -> float:
	while deg_value < 0:
		deg_value += 360
	while deg_value >= 360:
		deg_value -= 360
	return deg_to_rad(deg_value)

func set_turret(new_turret):
	turret = new_turret
	_last_fire_arc_count = -1  # force rebuild
	# Re-derive mirror state from the new selection: enabled iff a partner
	# exists and the arcs are already mirrored.
	partner = _find_mirror_partner(turret)
	mirroring_enabled = (partner != null) and _arcs_are_mirrored(turret, partner)
	update_editor()

func update_editor():
	if not is_instance_valid(turret):
		return
	# Use *_no_signal setters: writing UI values back from the model must not
	# trigger our own change handlers, which would create no-op undo actions
	# and dirty the scene every time the user clicks a turret.
	slew_limits_enabled.set_pressed_no_signal(turret.slew_limits_enabled)
	var min_angle_deg = rad_to_deg_0_360(turret.slew_min_angle)
	var max_angle_deg = rad_to_deg_0_360(turret.slew_max_angle)
	min_angle_spinner.set_value_no_signal(min_angle_deg)
	max_angle_spinner.set_value_no_signal(max_angle_deg)
	last_min_angle = min_angle_deg
	last_max_angle = max_angle_deg
	min_angle_spinner.editable = slew_limits_enabled.button_pressed
	max_angle_spinner.editable = slew_limits_enabled.button_pressed
	_rebuild_fire_arc_rows()
	_update_mirror_ui()

func update_debug_info(text: String):
	if debug_info:
		debug_info.text = text

func update_gizmos():
	if plugin:
		plugin.update_gizmos()

# --- Slew limit handlers (existing behavior, unchanged) ---

func _on_rotation_limits_toggled(enabled):
	if not is_instance_valid(turret):
		return
	undo_redo.create_action("Toggle Rotation Limits", UndoRedo.MERGE_DISABLE, turret)
	undo_redo.add_do_property(turret, "slew_limits_enabled", enabled)
	undo_redo.add_undo_property(turret, "slew_limits_enabled", turret.slew_limits_enabled)
	if _mirror_active():
		undo_redo.add_do_property(partner, "slew_limits_enabled", enabled)
		undo_redo.add_undo_property(partner, "slew_limits_enabled", partner.slew_limits_enabled)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()
	min_angle_spinner.editable = enabled
	max_angle_spinner.editable = enabled

func _on_min_angle_changed(value):
	if not is_instance_valid(turret):
		return
	var rad_value = deg_0_360_to_rad(value)
	undo_redo.create_action("Change Min Angle", UndoRedo.MERGE_DISABLE, turret)
	undo_redo.add_do_property(turret, "slew_min_angle", rad_value)
	undo_redo.add_undo_property(turret, "slew_min_angle", turret.slew_min_angle)
	if _mirror_active():
		# Mirror: source slew_min  -> partner slew_max (negated).
		var mirrored = _mirror_angle(rad_value)
		undo_redo.add_do_property(partner, "slew_max_angle", mirrored)
		undo_redo.add_undo_property(partner, "slew_max_angle", partner.slew_max_angle)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()
	last_min_angle = value

func _on_max_angle_changed(value):
	if not is_instance_valid(turret):
		return
	var rad_value = deg_0_360_to_rad(value)
	undo_redo.create_action("Change Max Angle", UndoRedo.MERGE_DISABLE, turret)
	undo_redo.add_do_property(turret, "slew_max_angle", rad_value)
	undo_redo.add_undo_property(turret, "slew_max_angle", turret.slew_max_angle)
	if _mirror_active():
		# Mirror: source slew_max -> partner slew_min (negated).
		var mirrored = _mirror_angle(rad_value)
		undo_redo.add_do_property(partner, "slew_min_angle", mirrored)
		undo_redo.add_undo_property(partner, "slew_min_angle", partner.slew_min_angle)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()
	last_max_angle = value

func _on_apply_pressed():
	if is_instance_valid(turret):
		update_gizmos()

# --- Fire arc list management ---

func _rebuild_fire_arc_rows() -> void:
	if not is_instance_valid(turret) or not is_instance_valid(fire_arcs_list):
		return
	_suppress_arc_signals = true
	for c in fire_arcs_list.get_children():
		c.queue_free()
	for i in turret.fire_arcs.size():
		var arc: FireArc = turret.fire_arcs[i]
		if arc == null:
			continue
		fire_arcs_list.add_child(_build_fire_arc_row(i, arc))
	_last_fire_arc_count = turret.fire_arcs.size()
	_suppress_arc_signals = false

func _sync_fire_arc_row_values() -> void:
	# Refresh spinbox values when an arc resource is edited externally (Inspector,
	# gizmo handle drag, etc.) without rebuilding the rows.
	if not is_instance_valid(turret) or not is_instance_valid(fire_arcs_list):
		return
	var rows = fire_arcs_list.get_children()
	if rows.size() != turret.fire_arcs.size():
		return
	_suppress_arc_signals = true
	for i in rows.size():
		var arc: FireArc = turret.fire_arcs[i]
		if arc == null:
			continue
		var row = rows[i]
		var min_sb: SpinBox = row.get_node("MinSpin")
		var max_sb: SpinBox = row.get_node("MaxSpin")
		var min_deg = rad_to_deg_0_360(arc.min_angle)
		var max_deg = rad_to_deg_0_360(arc.max_angle)
		if abs(min_sb.value - min_deg) > 0.01:
			min_sb.set_value_no_signal(min_deg)
		if abs(max_sb.value - max_deg) > 0.01:
			max_sb.set_value_no_signal(max_deg)
	_suppress_arc_signals = false

func _build_fire_arc_row(index: int, arc: FireArc) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Row%d" % index

	var label := Label.new()
	label.text = "Arc %d:" % index
	label.custom_minimum_size.x = 48
	row.add_child(label)

	var min_sb := SpinBox.new()
	min_sb.name = "MinSpin"
	min_sb.min_value = 0
	min_sb.max_value = 360
	min_sb.step = 0.1
	min_sb.suffix = "°"
	min_sb.value = rad_to_deg_0_360(arc.min_angle)
	min_sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	min_sb.value_changed.connect(_on_fire_arc_min_changed.bind(index))
	row.add_child(min_sb)

	var max_sb := SpinBox.new()
	max_sb.name = "MaxSpin"
	max_sb.min_value = 0
	max_sb.max_value = 360
	max_sb.step = 0.1
	max_sb.suffix = "°"
	max_sb.value = rad_to_deg_0_360(arc.max_angle)
	max_sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	max_sb.value_changed.connect(_on_fire_arc_max_changed.bind(index))
	row.add_child(max_sb)

	var del_btn := Button.new()
	del_btn.text = "X"
	del_btn.tooltip_text = "Remove this fire arc"
	del_btn.pressed.connect(_on_fire_arc_delete_pressed.bind(index))
	row.add_child(del_btn)

	return row

func _on_fire_arc_min_changed(value: float, index: int) -> void:
	if _suppress_arc_signals or not is_instance_valid(turret):
		return
	if index < 0 or index >= turret.fire_arcs.size():
		return
	var arc: FireArc = turret.fire_arcs[index]
	if arc == null:
		return
	var rad_value = deg_0_360_to_rad(value)
	undo_redo.create_action("Change Fire Arc %d Min" % index, UndoRedo.MERGE_DISABLE, turret)
	undo_redo.add_do_property(arc, "min_angle", rad_value)
	undo_redo.add_undo_property(arc, "min_angle", arc.min_angle)
	# Mirror: source arc.min  -> partner arc.max (negated).
	var partner_arc = _partner_fire_arc_for_propagation(index)
	if partner_arc != null:
		undo_redo.add_do_property(partner_arc, "max_angle", _mirror_angle(rad_value))
		undo_redo.add_undo_property(partner_arc, "max_angle", partner_arc.max_angle)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()

func _on_fire_arc_max_changed(value: float, index: int) -> void:
	if _suppress_arc_signals or not is_instance_valid(turret):
		return
	if index < 0 or index >= turret.fire_arcs.size():
		return
	var arc: FireArc = turret.fire_arcs[index]
	if arc == null:
		return
	var rad_value = deg_0_360_to_rad(value)
	undo_redo.create_action("Change Fire Arc %d Max" % index, UndoRedo.MERGE_DISABLE, turret)
	undo_redo.add_do_property(arc, "max_angle", rad_value)
	undo_redo.add_undo_property(arc, "max_angle", arc.max_angle)
	var partner_arc = _partner_fire_arc_for_propagation(index)
	if partner_arc != null:
		undo_redo.add_do_property(partner_arc, "min_angle", _mirror_angle(rad_value))
		undo_redo.add_undo_property(partner_arc, "min_angle", partner_arc.min_angle)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()

func _on_add_fire_arc_pressed() -> void:
	if not is_instance_valid(turret):
		return
	var new_arcs: Array[FireArc] = turret.fire_arcs.duplicate()
	var arc := FireArc.new()
	# Seed with the current slew range if available, otherwise a 90° arc ahead.
	if turret.slew_limits_enabled and turret.slew_min_angle != turret.slew_max_angle:
		arc.min_angle = turret.slew_min_angle
		arc.max_angle = turret.slew_max_angle
	else:
		arc.min_angle = 0.0
		arc.max_angle = deg_to_rad(90)
	new_arcs.append(arc)
	undo_redo.create_action("Add Fire Arc", UndoRedo.MERGE_DISABLE, turret)
	undo_redo.add_do_property(turret, "fire_arcs", new_arcs)
	undo_redo.add_undo_property(turret, "fire_arcs", turret.fire_arcs.duplicate())
	if _mirror_active():
		var partner_new: Array[FireArc] = partner.fire_arcs.duplicate()
		var mirrored := FireArc.new()
		# Swap-negate per the mirror formula: source.min -> partner.max, etc.
		mirrored.min_angle = _mirror_angle(arc.max_angle)
		mirrored.max_angle = _mirror_angle(arc.min_angle)
		partner_new.append(mirrored)
		undo_redo.add_do_property(partner, "fire_arcs", partner_new)
		undo_redo.add_undo_property(partner, "fire_arcs", partner.fire_arcs.duplicate())
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()

func _on_fire_arc_delete_pressed(index: int) -> void:
	if not is_instance_valid(turret):
		return
	if index < 0 or index >= turret.fire_arcs.size():
		return
	var new_arcs: Array[FireArc] = turret.fire_arcs.duplicate()
	new_arcs.remove_at(index)
	undo_redo.create_action("Remove Fire Arc %d" % index, UndoRedo.MERGE_DISABLE, turret)
	undo_redo.add_do_property(turret, "fire_arcs", new_arcs)
	undo_redo.add_undo_property(turret, "fire_arcs", turret.fire_arcs.duplicate())
	if _mirror_active():
		if index >= partner.fire_arcs.size():
			push_error("Mirror: partner fire_arcs size mismatch during delete (idx=%d, partner_size=%d)" % [index, partner.fire_arcs.size()])
		else:
			var partner_new: Array[FireArc] = partner.fire_arcs.duplicate()
			partner_new.remove_at(index)
			undo_redo.add_do_property(partner, "fire_arcs", partner_new)
			undo_redo.add_undo_property(partner, "fire_arcs", partner.fire_arcs.duplicate())
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()

func _on_clear_fire_arcs_pressed() -> void:
	if not is_instance_valid(turret) or turret.fire_arcs.is_empty():
		return
	var empty_arcs: Array[FireArc] = []
	undo_redo.create_action("Clear Fire Arcs", UndoRedo.MERGE_DISABLE, turret)
	undo_redo.add_do_property(turret, "fire_arcs", empty_arcs)
	undo_redo.add_undo_property(turret, "fire_arcs", turret.fire_arcs.duplicate())
	if _mirror_active():
		var partner_empty: Array[FireArc] = []
		undo_redo.add_do_property(partner, "fire_arcs", partner_empty)
		undo_redo.add_undo_property(partner, "fire_arcs", partner.fire_arcs.duplicate())
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()

# --- Convert + Expand button ---

# Predict the turret's rotation.y at runtime. Turret.cleanup() reparents the
# turret from its mount to the ship while preserving global_transform, which
# bakes the mount's Y yaw into the turret's local rotation.y. Slew is enforced
# against that post-cleanup value, so any editor math reasoning about whether
# the rest pose is inside the slew arc must use this frame.
func _runtime_rotation_y() -> float:
	if not is_instance_valid(turret):
		return 0.0
	var parent_node := turret.get_parent()
	if parent_node == null or not (parent_node is Node3D):
		return wrapf(turret.rotation.y, 0.0, TAU)
	var grand := parent_node.get_parent()
	if grand == null or not (grand is Node3D):
		return wrapf(turret.rotation.y, 0.0, TAU)
	# Recompute turret's local rotation as if reparented to grand while
	# keeping its global transform — same operation as cleanup().
	var new_basis: Basis = (grand as Node3D).global_basis.inverse() * turret.global_basis
	return wrapf(new_basis.get_euler().y, 0.0, TAU)

func _convert_expand_available() -> bool:
	if not is_instance_valid(turret):
		return false
	if not turret.slew_limits_enabled:
		return false
	if turret.slew_min_angle == turret.slew_max_angle:
		return false  # "not configured" sentinel
	var arc: float = wrapf(turret.slew_max_angle - turret.slew_min_angle, 0.0, TAU)
	var off: float = wrapf(_runtime_rotation_y() - turret.slew_min_angle, 0.0, TAU)
	return off > arc

func _on_convert_expand_pressed() -> void:
	if not _convert_expand_available():
		update_debug_info("Convert+Expand: nothing to do (slew disabled, unconfigured, or rotation already inside arc).")
		return
	var arc: float = wrapf(turret.slew_max_angle - turret.slew_min_angle, 0.0, TAU)
	var rot_norm: float = _runtime_rotation_y()
	var off: float = wrapf(rot_norm - turret.slew_min_angle, 0.0, TAU)

	# 1. Preserve original slew arc as a FireArc.
	var new_arcs: Array[FireArc] = turret.fire_arcs.duplicate()
	var fa := FireArc.new()
	fa.min_angle = turret.slew_min_angle
	fa.max_angle = turret.slew_max_angle
	new_arcs.append(fa)

	# 2. Expand slew arc to contain the runtime rotation. Choose the cheaper
	#    extension:
	#    - extend slew_min CCW back to rotation (cost = TAU - off), OR
	#    - extend slew_max CW forward to rotation (cost = off - arc).
	var extend_min_cost: float = TAU - off
	var extend_max_cost: float = off - arc
	var new_slew_min: float = turret.slew_min_angle
	var new_slew_max: float = turret.slew_max_angle
	if extend_min_cost <= extend_max_cost:
		new_slew_min = rot_norm
	else:
		new_slew_max = rot_norm

	undo_redo.create_action("Convert Slew to Fire Arc + Expand Slew", UndoRedo.MERGE_DISABLE, turret)
	undo_redo.add_do_property(turret, "fire_arcs", new_arcs)
	undo_redo.add_do_property(turret, "slew_min_angle", new_slew_min)
	undo_redo.add_do_property(turret, "slew_max_angle", new_slew_max)
	undo_redo.add_undo_property(turret, "fire_arcs", turret.fire_arcs.duplicate())
	undo_redo.add_undo_property(turret, "slew_min_angle", turret.slew_min_angle)
	undo_redo.add_undo_property(turret, "slew_max_angle", turret.slew_max_angle)
	if _mirror_active():
		# Mirror the resulting state onto the partner so the relationship is
		# preserved across the operation. We mirror final values directly
		# rather than re-running the runtime-rotation math on the partner,
		# which would diverge if the two turrets rest at non-mirrored angles.
		var partner_new_arcs: Array[FireArc] = []
		for src in new_arcs:
			if src == null:
				continue
			var m := FireArc.new()
			m.min_angle = _mirror_angle(src.max_angle)
			m.max_angle = _mirror_angle(src.min_angle)
			partner_new_arcs.append(m)
		var partner_new_slew_min := _mirror_angle(new_slew_max)
		var partner_new_slew_max := _mirror_angle(new_slew_min)
		undo_redo.add_do_property(partner, "fire_arcs", partner_new_arcs)
		undo_redo.add_do_property(partner, "slew_min_angle", partner_new_slew_min)
		undo_redo.add_do_property(partner, "slew_max_angle", partner_new_slew_max)
		undo_redo.add_undo_property(partner, "fire_arcs", partner.fire_arcs.duplicate())
		undo_redo.add_undo_property(partner, "slew_min_angle", partner.slew_min_angle)
		undo_redo.add_undo_property(partner, "slew_max_angle", partner.slew_max_angle)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()
	update_debug_info("Saved old slew arc as Fire Arc %d, expanded slew.%s" % [
		new_arcs.size() - 1,
		" Mirrored to %s." % partner.name if _mirror_active() else ""
	])

# --- Default debug readout ---

func _update_default_debug_info() -> void:
	if not is_instance_valid(turret) or debug_info == null:
		return
	# Don't clobber a recent action message; only repaint when the label is the
	# default state or a previously-default state.
	var arc: float = wrapf(turret.slew_max_angle - turret.slew_min_angle, 0.0, TAU)
	var rot_runtime: float = _runtime_rotation_y()
	var off: float = wrapf(rot_runtime - turret.slew_min_angle, 0.0, TAU)
	var in_slew = (turret.slew_limits_enabled and turret.slew_min_angle != turret.slew_max_angle and off <= arc)
	var status = "in slew arc" if in_slew else ("outside slew arc" if turret.slew_limits_enabled else "slew disabled")
	var txt = "rotation.y = %.2f° (runtime)  (%s)\nfire arcs: %d" % [
		rad_to_deg_0_360(rot_runtime), status, turret.fire_arcs.size()
	]
	# Only overwrite if previous text is auto-generated (starts with "rotation.y" or is the default).
	if debug_info.text.begins_with("rotation.y") or debug_info.text == "(No debug info)":
		debug_info.text = txt

# --- Mirror feature ---
#
# State is purely editor-side. The ship file never stores any mirror
# relationship; pairing is re-derived from positions whenever a turret is
# selected. Two turrets are "mirror candidates" when their ship-local
# positions match across the longitudinal (X) axis within
# MIRROR_POSITION_TOLERANCE on every axis (i.e. (-x, y, z)). The Mirror
# checkbox is only visible when a candidate exists AND the selected turret
# is off-centerline.
#
# Arc mirror formula (port <-> starboard, ship-local Y rotation):
#   partner.slew_min = wrap(-source.slew_max)
#   partner.slew_max = wrap(-source.slew_min)
# Same swap-negate applies per FireArc (min<->max).
# Mirroring covers ONLY: slew_min/max, slew_limits_enabled, fire_arcs.
# It does NOT propagate base_rotation, traverse rate, scene structure, etc.

func _mirror_active() -> bool:
	return mirroring_enabled and partner != null and is_instance_valid(partner)

func _mirror_angle(a: float) -> float:
	return wrapf(-a, 0.0, TAU)

func _angles_match(a: float, b: float) -> bool:
	return absf(wrapf(a - b, -PI, PI)) <= MIRROR_ANGLE_EPS

func _refresh_mirror_tracking() -> void:
	if not is_instance_valid(turret):
		partner = null
		mirroring_enabled = false
		return
	var new_partner := _find_mirror_partner(turret)
	if new_partner != partner:
		partner = new_partner
		mirroring_enabled = (partner != null) and _arcs_are_mirrored(turret, partner)
		_update_mirror_ui()

func _update_mirror_ui() -> void:
	if mirror_section == null:
		return
	if not is_instance_valid(turret):
		mirror_section.visible = false
		return
	var ship := _find_ship_ancestor(turret)
	if ship == null:
		mirror_section.visible = false
		return
	var local_pos: Vector3 = ship.to_local(turret.global_position)
	if absf(local_pos.x) < MIRROR_CENTERLINE_THRESHOLD:
		mirror_section.visible = false
		return
	if partner == null:
		mirror_section.visible = false
		return
	mirror_section.visible = true
	mirror_partner_label.text = "with: %s" % partner.name
	if mirror_checkbox.button_pressed != mirroring_enabled:
		mirror_checkbox.set_pressed_no_signal(mirroring_enabled)

func _find_ship_ancestor(n: Node) -> Node:
	var cur: Node = n
	while cur != null:
		var scr = cur.get_script()
		if scr != null and str(scr.get_global_name()) == "Ship":
			return cur
		cur = cur.get_parent()
	# Fallback: scene root owner.
	if n != null and n.owner != null:
		return n.owner
	return null

func _collect_turrets(node: Node, out: Array) -> void:
	if node == null:
		return
	if node is Turret:
		out.append(node)
	for c in node.get_children():
		_collect_turrets(c, out)

func _find_mirror_partner(t: Turret) -> Turret:
	if t == null or not is_instance_valid(t):
		return null
	var ship := _find_ship_ancestor(t)
	if ship == null:
		return null
	var local_pos: Vector3 = ship.to_local(t.global_position)
	if absf(local_pos.x) < MIRROR_CENTERLINE_THRESHOLD:
		return null
	var target := Vector3(-local_pos.x, local_pos.y, local_pos.z)
	var candidates: Array = []
	_collect_turrets(ship, candidates)
	var best: Turret = null
	var best_dist := MIRROR_POSITION_TOLERANCE
	for c in candidates:
		if c == t:
			continue
		var cp: Vector3 = ship.to_local(c.global_position)
		var d := cp - target
		if absf(d.x) > MIRROR_POSITION_TOLERANCE:
			continue
		if absf(d.y) > MIRROR_POSITION_TOLERANCE:
			continue
		if absf(d.z) > MIRROR_POSITION_TOLERANCE:
			continue
		var dist := d.length()
		if dist < best_dist:
			best_dist = dist
			best = c
	return best

func _arcs_are_mirrored(a: Turret, b: Turret) -> bool:
	if a == null or b == null:
		return false
	if a.slew_limits_enabled != b.slew_limits_enabled:
		return false
	if not _angles_match(a.slew_min_angle, _mirror_angle(b.slew_max_angle)):
		return false
	if not _angles_match(a.slew_max_angle, _mirror_angle(b.slew_min_angle)):
		return false
	if a.fire_arcs.size() != b.fire_arcs.size():
		return false
	for i in a.fire_arcs.size():
		var fa: FireArc = a.fire_arcs[i]
		var fb: FireArc = b.fire_arcs[i]
		if fa == null or fb == null:
			return false
		if not _angles_match(fa.min_angle, _mirror_angle(fb.max_angle)):
			return false
		if not _angles_match(fa.max_angle, _mirror_angle(fb.min_angle)):
			return false
	return true

func _build_mirrored_fire_arcs(source: Turret) -> Array[FireArc]:
	var out: Array[FireArc] = []
	for src in source.fire_arcs:
		if src == null:
			push_error("Mirror: source has null FireArc entry; skipping")
			continue
		var m := FireArc.new()
		m.min_angle = _mirror_angle(src.max_angle)
		m.max_angle = _mirror_angle(src.min_angle)
		out.append(m)
	return out

func _partner_fire_arc_for_propagation(index: int) -> FireArc:
	if not _mirror_active():
		return null
	if index >= partner.fire_arcs.size():
		push_error("Mirror: partner fire_arcs size mismatch on edit (idx=%d, partner_size=%d)" % [index, partner.fire_arcs.size()])
		return null
	return partner.fire_arcs[index]

func _on_mirror_toggled(enabled: bool) -> void:
	if not is_instance_valid(turret) or partner == null:
		mirror_checkbox.set_pressed_no_signal(false)
		mirroring_enabled = false
		return
	mirroring_enabled = enabled
	if not enabled:
		return
	var mirrored_min := _mirror_angle(turret.slew_max_angle)
	var mirrored_max := _mirror_angle(turret.slew_min_angle)
	var mirrored_arcs := _build_mirrored_fire_arcs(turret)
	undo_redo.create_action("Mirror Turret -> %s" % partner.name, UndoRedo.MERGE_DISABLE, turret)
	undo_redo.add_do_property(partner, "slew_limits_enabled", turret.slew_limits_enabled)
	undo_redo.add_undo_property(partner, "slew_limits_enabled", partner.slew_limits_enabled)
	undo_redo.add_do_property(partner, "slew_min_angle", mirrored_min)
	undo_redo.add_undo_property(partner, "slew_min_angle", partner.slew_min_angle)
	undo_redo.add_do_property(partner, "slew_max_angle", mirrored_max)
	undo_redo.add_undo_property(partner, "slew_max_angle", partner.slew_max_angle)
	undo_redo.add_do_property(partner, "fire_arcs", mirrored_arcs)
	undo_redo.add_undo_property(partner, "fire_arcs", partner.fire_arcs.duplicate())
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()
