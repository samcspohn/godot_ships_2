# addons/turret_editor/turret_editor_panel.gd
@tool
extends Control

var plugin: EditorPlugin
var turret: Gun
var undo_redo: EditorUndoRedoManager
var last_min_angle: float = 0.0
var last_max_angle: float = 0.0

# UI Elements
@onready var barrel_count_spinner = $VBoxContainer/BarrelSettings/BarrelCountContainer/BarrelCountSpinner
@onready var barrel_spacing_slider = $VBoxContainer/BarrelSettings/BarrelSpacingContainer/BarrelSpacingSlider
@onready var rotation_limits_enabled = $VBoxContainer/RotationLimits/EnabledContainer/EnabledCheckBox
@onready var min_angle_spinner = $VBoxContainer/RotationLimits/MinAngleContainer/MinAngleSpinBox
@onready var max_angle_spinner = $VBoxContainer/RotationLimits/MaxAngleContainer/MaxAngleSpinBox
@onready var barrel_scene_selector = $VBoxContainer/BarrelSettings/BarrelSceneSelector
@onready var barrel_scene_button = $VBoxContainer/BarrelSettings/BarrelSceneButton
@onready var apply_button = $VBoxContainer/ApplyButton
@onready var debug_info = $VBoxContainer/DebugContainer/DebugInfo

func _ready():
	# Get undo/redo system reference
	undo_redo = EditorInterface.get_editor_undo_redo()
	
	# Set up UI ranges for 0-360 degrees
	min_angle_spinner.min_value = 0
	min_angle_spinner.max_value = 360
	max_angle_spinner.min_value = 0
	max_angle_spinner.max_value = 360
	
	# Initialize UI
	barrel_count_spinner.value_changed.connect(_on_barrel_count_changed)
	barrel_spacing_slider.value_changed.connect(_on_barrel_spacing_changed)
	rotation_limits_enabled.toggled.connect(_on_rotation_limits_toggled)
	min_angle_spinner.value_changed.connect(_on_min_angle_changed)
	max_angle_spinner.value_changed.connect(_on_max_angle_changed)
	barrel_scene_button.pressed.connect(_on_barrel_scene_button_pressed)
	barrel_scene_selector.file_selected.connect(_on_barrel_scene_selected)
	apply_button.pressed.connect(_on_apply_pressed)

func _process(delta):
	# Check if turret angles have changed (e.g., from gizmo manipulation)
	if is_instance_valid(turret):
		var current_min_angle = rad_to_deg_0_360(turret.min_rotation_angle)
		var current_max_angle = rad_to_deg_0_360(turret.max_rotation_angle)
		
		# Only update if values are different to avoid infinite loops
		if abs(current_min_angle - last_min_angle) > 0.01:
			min_angle_spinner.set_value_no_signal(current_min_angle)
			last_min_angle = current_min_angle
		
		if abs(current_max_angle - last_max_angle) > 0.01:
			max_angle_spinner.set_value_no_signal(current_max_angle)
			last_max_angle = current_max_angle

# Convert radians to degrees in 0-360 range
func rad_to_deg_0_360(rad_value: float) -> float:
	var deg_value = rad_to_deg(rad_value)
	
	# Normalize to 0-360 range
	while deg_value < 0:
		deg_value += 360
	
	while deg_value >= 360:
		deg_value -= 360
	
	return deg_value

# Convert degrees in 0-360 range to radians
func deg_0_360_to_rad(deg_value: float) -> float:
	# Normalize input to 0-360 range
	while deg_value < 0:
		deg_value += 360
	
	while deg_value >= 360:
		deg_value -= 360
	
	# Convert to radians
	return deg_to_rad(deg_value)

func set_turret(new_turret):
	turret = new_turret
	update_editor()

func update_editor():
	if not is_instance_valid(turret):
		return
	
	# Update UI based on turret properties
	barrel_count_spinner.value = turret.barrel_count
	barrel_spacing_slider.value = turret.barrel_spacing
	rotation_limits_enabled.button_pressed = turret.rotation_limits_enabled
	
	# Update angles and store their values (convert to 0-360 range)
	var min_angle_deg = rad_to_deg_0_360(turret.min_rotation_angle)
	var max_angle_deg = rad_to_deg_0_360(turret.max_rotation_angle)
	
	min_angle_spinner.value = min_angle_deg
	max_angle_spinner.value = max_angle_deg
	
	last_min_angle = min_angle_deg
	last_max_angle = max_angle_deg
	
	# Update enabled states
	min_angle_spinner.editable = rotation_limits_enabled.button_pressed
	max_angle_spinner.editable = rotation_limits_enabled.button_pressed
	
	# Update barrel scene path if available
	if turret.barrel_scene:
		var scene_path = turret.barrel_scene.resource_path
		barrel_scene_selector.current_path = scene_path

func update_debug_info(text: String):
	if debug_info:
		debug_info.text = text

# Notify the editor that gizmos should be updated
func update_gizmos():
	if plugin:
		plugin.update_gizmos()

# UI Signal handlers with undo/redo support
func _on_barrel_count_changed(value):
	if not is_instance_valid(turret):
		return
	
	undo_redo.create_action("Change Barrel Count")
	undo_redo.add_do_property(turret, "barrel_count", value)
	undo_redo.add_undo_property(turret, "barrel_count", turret.barrel_count)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()

func _on_barrel_spacing_changed(value):
	if not is_instance_valid(turret):
		return
	
	undo_redo.create_action("Change Barrel Spacing")
	undo_redo.add_do_property(turret, "barrel_spacing", value)
	undo_redo.add_undo_property(turret, "barrel_spacing", turret.barrel_spacing)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()

func _on_rotation_limits_toggled(enabled):
	if not is_instance_valid(turret):
		return
	
	undo_redo.create_action("Toggle Rotation Limits")
	undo_redo.add_do_property(turret, "rotation_limits_enabled", enabled)
	undo_redo.add_undo_property(turret, "rotation_limits_enabled", turret.rotation_limits_enabled)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()
	
	min_angle_spinner.editable = enabled
	max_angle_spinner.editable = enabled

func _on_min_angle_changed(value):
	if not is_instance_valid(turret):
		return
	
	var rad_value = deg_0_360_to_rad(value)
	
	undo_redo.create_action("Change Min Angle")
	undo_redo.add_do_property(turret, "min_rotation_angle", rad_value)
	undo_redo.add_undo_property(turret, "min_rotation_angle", turret.min_rotation_angle)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()
	
	# Update last known value
	last_min_angle = value

func _on_max_angle_changed(value):
	if not is_instance_valid(turret):
		return
	
	var rad_value = deg_0_360_to_rad(value)
	
	undo_redo.create_action("Change Max Angle")
	undo_redo.add_do_property(turret, "max_rotation_angle", rad_value)
	undo_redo.add_undo_property(turret, "max_rotation_angle", turret.max_rotation_angle)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()
	
	# Update last known value
	last_max_angle = value

func _on_barrel_scene_button_pressed():
	barrel_scene_selector.popup_centered()

func _on_barrel_scene_selected(path):
	if not is_instance_valid(turret):
		return
	
	var new_scene = load(path)
	
	undo_redo.create_action("Change Barrel Scene")
	undo_redo.add_do_property(turret, "barrel_scene", new_scene)
	undo_redo.add_undo_property(turret, "barrel_scene", turret.barrel_scene)
	undo_redo.add_do_method(self, "update_gizmos")
	undo_redo.add_undo_method(self, "update_gizmos")
	undo_redo.commit_action()

func _on_apply_pressed():
	if is_instance_valid(turret):
		# Force gizmo update through the plugin
		update_gizmos()
