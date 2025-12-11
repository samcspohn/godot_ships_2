extends CanvasLayer

class_name CameraUIScene

# Preload the floating damage scene
const FloatingDamageScene = preload("res://scenes/floating_damage.tscn")

# Camera controller reference
var camera_controller: BattleCamera

# Properties that BattleCamera sets directly - these need to match the interface
var time_to_target: float = 0.0 : set = set_time_to_target
var distance_to_target: float = 0.0 : set = set_distance_to_target
var aim_position: Vector3 = Vector3.ZERO : set = set_aim_position
var max_range_reached: bool = false
var ship_speed: float = 0.0 : set = set_ship_speed
var locked_target = null : set = set_locked_target
var target_lock_enabled: bool = false : set = set_target_lock_enabled

# UI node references - these will be populated from the scene
@onready var crosshair_container: Control = $MainContainer/CrosshairContainer
@onready var time_label: Label = $MainContainer/CrosshairContainer/TargetInfo/TimeLabel
@onready var distance_label: Label = $MainContainer/CrosshairContainer/TargetInfo/DistanceLabel

@onready var fps_label: Label = $MainContainer/TopLeftPanel/FPSLabel
@onready var camera_angle_label: Label = $MainContainer/TopLeftPanel/CameraAngleLabel

@onready var secondary_count_label: Label = $MainContainer/TopRightPanel/HBoxContainer/SecondaryCounter/SecondaryContainer/SecondaryCount
@onready var main_count_label: Label = $MainContainer/TopRightPanel/HBoxContainer/MainCounter/MainContainer/MainCount
@onready var frag_count_label: Label = $MainContainer/TopRightPanel/HBoxContainer/FragCounter/FragContainer/FragCount

# Main hit counter labels (shown when hovering over MAIN)
@onready var penetration_count_label: Label = $MainContainer/TopRightPanel/MainVBox/MainHitCounters/PenetrationCounter/PenetrationContainer/PenetrationCount
@onready var overpenetration_count_label: Label = $MainContainer/TopRightPanel/MainVBox/MainHitCounters/OverpenetrationCounter/OverpenetrationContainer/OverpenetrationCount
@onready var shatter_count_label: Label = $MainContainer/TopRightPanel/MainVBox/MainHitCounters/ShatterCounter/ShatterContainer/ShatterCount
@onready var ricochet_count_label: Label = $MainContainer/TopRightPanel/MainVBox/MainHitCounters/RicochetCounter/RicochetContainer/RicochetCount
@onready var citadel_count_label: Label = $MainContainer/TopRightPanel/MainVBox/MainHitCounters/CitadelCounter/CitadelContainer/CitadelCount
@onready var main_damage_label: Label = $MainContainer/TopRightPanel/MainVBox/DamageCounter/DamageValue

# Secondary hit counter labels (shown when hovering over SEC)
@onready var sec_penetration_count_label: Label = $MainContainer/TopRightPanel/SecondaryCounter/SecondaryVBox/SecondaryHitCounters/SecPenetrationCounter/SecPenetrationContainer/SecPenetrationCount
@onready var sec_overpenetration_count_label: Label = $MainContainer/TopRightPanel/SecondaryCounter/SecondaryVBox/SecondaryHitCounters/SecOverpenetrationCounter/SecOverpenetrationContainer/SecOverpenetrationCount
@onready var sec_shatter_count_label: Label = $MainContainer/TopRightPanel/SecondaryCounter/SecondaryVBox/SecondaryHitCounters/SecShatterCounter/SecShatterContainer/SecShatterCount
@onready var sec_ricochet_count_label: Label = $MainContainer/TopRightPanel/SecondaryCounter/SecondaryVBox/SecondaryHitCounters/SecRicochetCounter/SecRicochetContainer/SecRicochetCount
@onready var sec_citadel_count_label: Label = $MainContainer/TopRightPanel/SecondaryCounter/SecondaryVBox/SecondaryHitCounters/SecCitadelCounter/SecCitadelContainer/SecCitadelCount
@onready var sec_damage_label: Label = $MainContainer/TopRightPanel/SecondaryVBox/DamageCounter/DamageValue

@onready var damage_value_label: Label = $MainContainer/TopRightPanel/HBoxContainer/DamageCounter/DamageValue

# Hit counter containers for hover functionality
@onready var secondary_hit_counters: VBoxContainer = $MainContainer/TopRightPanel/SecondaryVBox
@onready var main_hit_counters: VBoxContainer = $MainContainer/TopRightPanel/MainVBox

# Temporary hit counter containers
@onready var main_counter_temp: HBoxContainer = $MainContainer/TopRightPanel/MainCounterTemp
@onready var sec_counter_temp: HBoxContainer = $MainContainer/TopRightPanel/SecCounterTemp

# Temporary main hit counter references
@onready var temp_penetration_counter: Control = $MainContainer/TopRightPanel/MainCounterTemp/TempPenetrationCounter
@onready var temp_overpenetration_counter: Control = $MainContainer/TopRightPanel/MainCounterTemp/TempOverpenetrationCounter
@onready var temp_shatter_counter: Control = $MainContainer/TopRightPanel/MainCounterTemp/TempShatterCounter
@onready var temp_ricochet_counter: Control = $MainContainer/TopRightPanel/MainCounterTemp/TempRicochetCounter
@onready var temp_citadel_counter: Control = $MainContainer/TopRightPanel/MainCounterTemp/TempCitadelCounter

# Temporary main hit counter labels
@onready var temp_penetration_count_label: Label = $MainContainer/TopRightPanel/MainCounterTemp/TempPenetrationCounter/PenetrationContainer/PenetrationCount
@onready var temp_overpenetration_count_label: Label = $MainContainer/TopRightPanel/MainCounterTemp/TempOverpenetrationCounter/OverpenetrationContainer/OverpenetrationCount
@onready var temp_shatter_count_label: Label = $MainContainer/TopRightPanel/MainCounterTemp/TempShatterCounter/ShatterContainer/ShatterCount
@onready var temp_ricochet_count_label: Label = $MainContainer/TopRightPanel/MainCounterTemp/TempRicochetCounter/RicochetContainer/RicochetCount
@onready var temp_citadel_count_label: Label = $MainContainer/TopRightPanel/MainCounterTemp/TempCitadelCounter/CitadelContainer/CitadelCount

# Temporary secondary hit counter references
@onready var temp_sec_penetration_counter: Control = $MainContainer/TopRightPanel/SecCounterTemp/TempSecPenetrationCounter
@onready var temp_sec_overpenetration_counter: Control = $MainContainer/TopRightPanel/SecCounterTemp/TempSecOverpenetrationCounter
@onready var temp_sec_shatter_counter: Control = $MainContainer/TopRightPanel/SecCounterTemp/TempSecShatterCounter
@onready var temp_sec_ricochet_counter: Control = $MainContainer/TopRightPanel/SecCounterTemp/TempSecRicochetCounter
@onready var temp_sec_citadel_counter: Control = $MainContainer/TopRightPanel/SecCounterTemp/TempSecCitadelCounter

# Temporary secondary hit counter labels
@onready var temp_sec_penetration_count_label: Label = $MainContainer/TopRightPanel/SecCounterTemp/TempSecPenetrationCounter/SecPenetrationContainer/SecPenetrationCount
@onready var temp_sec_overpenetration_count_label: Label = $MainContainer/TopRightPanel/SecCounterTemp/TempSecOverpenetrationCounter/SecOverpenetrationContainer/SecOverpenetrationCount
@onready var temp_sec_shatter_count_label: Label = $MainContainer/TopRightPanel/SecCounterTemp/TempSecShatterCounter/SecShatterContainer/SecShatterCount
@onready var temp_sec_ricochet_count_label: Label = $MainContainer/TopRightPanel/SecCounterTemp/TempSecRicochetCounter/SecRicochetContainer/SecRicochetCount
@onready var temp_sec_citadel_count_label: Label = $MainContainer/TopRightPanel/SecCounterTemp/TempSecCitadelCounter/SecCitadelContainer/SecCitadelCount

# Main counter labels for hover detection
@onready var secondary_label: Label = $MainContainer/TopRightPanel/HBoxContainer/SecondaryCounter/SecondaryContainer/SecondarySec
@onready var main_label: Label = $MainContainer/TopRightPanel/HBoxContainer/MainCounter/MainContainer/MainMain

@onready var secondary_counter: Control = $MainContainer/TopRightPanel/HBoxContainer/SecondaryCounter
@onready var main_counter: Control = $MainContainer/TopRightPanel/HBoxContainer/MainCounter

@onready var top_right_panel: VBoxContainer = $MainContainer/TopRightPanel

# Visibility indicator
@onready var visibility_indicator: ColorRect = $MainContainer/VisibilityIndicator

# Team tracker references
@onready var top_center_panel: Control = $MainContainer/TopCenterPanel
@onready var friendly_ships_container: HBoxContainer = $MainContainer/TopCenterPanel/TeamTrackerContainer/FriendlyShipsContainer
@onready var enemy_ships_container: HBoxContainer = $MainContainer/TopCenterPanel/TeamTrackerContainer/EnemyShipsContainer

@onready var speed_label: Label = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/SpeedLabel
@onready var throttle_label: Label = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/ThrottleLabel
@onready var rudder_label: Label = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/RudderLabel
@onready var rudder_slider: HSlider = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/RudderSlider
@onready var throttle_slider: VSlider = $MainContainer/BottomLeftPanel/HBoxContainer/ThrottleSlider

@onready var hp_bar: ProgressBar = $MainContainer/BottomCenterPanel/HPContainer/HPBar
@onready var hp_label: Label = $MainContainer/BottomCenterPanel/HPContainer/HPBar/HPLabel

@onready var gun_reload_container: HBoxContainer = $MainContainer/BottomCenterPanel/HPContainer/GunReloadContainer
@onready var reload_bar_template: ProgressBar = $MainContainer/BottomCenterPanel/HPContainer/GunReloadContainer/ReloadBarTemplate

@onready var bottom_right_panel: Control = $MainContainer/BottomRightPanel

@onready var ship_ui_templates: Control = $MainContainer/ShipUITemplates
@onready var enemy_ship_template: Control = $MainContainer/ShipUITemplates/EnemyShipTemplate
@onready var friendly_ship_template: Control = $MainContainer/ShipUITemplates/FriendlyShipTemplate
@onready var team_tracker_template: Control = $MainContainer/ShipUITemplates/TeamTrackerTemplate

@onready var weapon_buttons: Array[Button] = [
	$MainContainer/BottomCenterPanel/UsableContainer/WeaponPanel/Shell1Button,
	$MainContainer/BottomCenterPanel/UsableContainer/WeaponPanel/Shell2Button,
	$MainContainer/BottomCenterPanel/UsableContainer/WeaponPanel/TorpedoButton
]

@onready var consumable_container: HBoxContainer = $MainContainer/BottomCenterPanel/UsableContainer/ConsumableContainer
@onready var consumable_template: TextureButton = $MainContainer/BottomCenterPanel/UsableContainer/ConsumableContainer/ConsumableTemplate
var consumable_buttons: Array[TextureButton] = []
var consumable_cooldown_bars: Array[ProgressBar] = []
var consumable_shortcut_labels: Array[Label] = []
var consumable_count_labels: Array[Label] = []

# Consumable action names for getting shortcuts from InputMap
var consumable_actions = ["consumable_1", "consumable_2", "consumable_3", "consumable_4", "consumable_5"]

# Get the keyboard shortcut letter for a given action
func get_keyboard_shortcut_for_action(action_name: String) -> String:
	if not InputMap.has_action(action_name):
		return ""

	var events = InputMap.action_get_events(action_name)
	for event in events:
		if event is InputEventKey:
			var key_event = event as InputEventKey
			# Convert physical keycode to character
			return OS.get_keycode_string(key_event.physical_keycode)

	return ""

# Gun reload tracking
var gun_reload_bars: Array[ProgressBar] = []
var gun_reload_timers: Array[Label] = []
var guns: Array[Gun] = []

# Minimap
var minimap: Minimap

# Ship tracking
var tracked_ships = {}
var ship_ui_elements = {}
var last_ship_search_time: float = 0.0
var ship_search_interval: float = 2.0  # Search for new ships every 2 seconds

# Target tracking for secondaries
var current_secondary_target: Ship = null

# Team tracker
var team_ship_indicators = {}  # Maps ship to its indicator ColorRect
var friendly_team_id: int = -1  # Will be set when camera_controller is available

# Hit counter system for temporary display
var active_hit_counters = {}
var active_hit_timers = {}
var hit_counter_display_time: float = 5.0  # Display for 5 seconds

# Hit counter references mapping
var hit_counter_styles = {}

func recurs_set_vis(n: Node):
	if n is CanvasItem:
		n.visibility_layer = 1 << 1
	for child in n.get_children():
		recurs_set_vis(child)

func _ready():
	# Add to camera_ui group for easy access
	add_to_group("camera_ui")

	# Connect weapon button signals
	for i in range(weapon_buttons.size()):
		weapon_buttons[i].connect("pressed", _on_weapon_button_pressed.bind(i))

	# Connect crosshair drawing
	crosshair_container.connect("draw", _on_crosshair_container_draw)

	# Setup hover functionality for counters
	setup_counter_hover_functionality()

	# Setup hit counter display system
	setup_hit_counter_system()

	# Setup consumable buttons
	setup_consumable_ui()

	# Setup minimap in the bottom right panel with automatic anchoring
	minimap = Minimap.new()
	minimap.set_anchors_preset(Control.PRESET_TOP_LEFT)
	minimap.position = Vector2(0, 0)  # Position at top-left of the panel
	bottom_right_panel.add_child(minimap)

	# Hide ship UI templates (they're visible in editor for design purposes)
	ship_ui_templates.visible = false

	# Setup gun reload bars (will be called again when camera_controller is set)
	if camera_controller:
		setup_gun_reload_bars()
	
	update_counters()

func _process(_delta: float) -> void:
	update_ship_ui()

func update_counters() -> void:
	var stats = camera_controller._ship.stats

	update_counter(damage_value_label, stats.total_damage)
	update_counter(main_count_label, stats.main_hits)
	update_counter(frag_count_label, stats.frags)
	update_counter(secondary_count_label, stats.secondary_count)
	update_counter(sec_citadel_count_label, stats.sec_citadel_count)
	update_counter(sec_damage_label, stats.sec_damage)

	# Update main hit counters
	update_counter(penetration_count_label, stats.penetration_count)
	update_counter(overpenetration_count_label, stats.overpen_count)
	update_counter(ricochet_count_label, stats.ricochet_count)
	update_counter(shatter_count_label, stats.shatter_count)
	update_counter(citadel_count_label, stats.citadel_count)
	update_counter(main_damage_label, stats.main_damage)

	# Update secondary hit counters
	update_counter(sec_penetration_count_label, stats.sec_penetration_count)
	update_counter(sec_overpenetration_count_label, stats.sec_overpen_count)
	update_counter(sec_ricochet_count_label, stats.sec_ricochet_count)
	update_counter(sec_shatter_count_label, stats.sec_shatter_count)
	update_counter(sec_citadel_count_label, stats.sec_citadel_count)
	update_counter(sec_damage_label, stats.sec_damage)

var accum: float = 0.0
func _physics_process(_delta):
	if not camera_controller:
		return

	# accum += _delta
	# if accum > 0.2:
	# 	accum = 0.0
	# 	update_team_tracker()  # Update team tracker

	_update_ui()
	_update_fps()
	_update_camera_angle_display()
	update_team_tracker()  # Update team tracker
	# cleanup_team_indicators()  # Clean up invalid indicators
	update_gun_reload_bars()
	check_hover_detection()  # Add manual hover detection
	update_hit_counters(_delta)  # Update hit counter timers
	update_visibility_indicator()  # Update visibility indicator
	update_consumable_ui()

	# Automatically detect current secondary target from ship's secondary controllers
	if camera_controller._ship and camera_controller._ship.secondary_controller:
		var detected_target = camera_controller._ship.secondary_controller.target

		# Update the target if it has changed
		if detected_target != current_secondary_target:
			current_secondary_target = detected_target

	if camera_controller and camera_controller._ship and camera_controller._ship.stats:
		var stats = camera_controller._ship.stats

		# Process damage events for hit counters
		if stats.damage_events.size() > 0:
			process_damage_events(stats.damage_events)
			# update_counters()
			update_counter(frag_count_label, stats.frags)
		update_counter(damage_value_label, stats.total_damage)
		# update_counter(damage_value_label, stats.total_damage)
		
	
	crosshair_container.queue_redraw()

func initialize_for_ship():
	# Call this after camera_controller is set and ship is available
	if camera_controller and camera_controller._ship:
		# Initialize team tracker
		if camera_controller._ship.team:
			friendly_team_id = camera_controller._ship.team.team_id

		minimap.register_player_ship(camera_controller._ship)
		await get_tree().process_frame
		minimap.take_map_snapshot(get_viewport())

		# Force an initial search for other ships
		update_ship_ui()
		update_team_tracker()  # Initialize team tracker

func setup_counter_hover_functionality():
	print("Setting up hover functionality...")

	# Enable mouse input for the counter containers
	secondary_counter.mouse_filter = Control.MOUSE_FILTER_PASS
	main_counter.mouse_filter = Control.MOUSE_FILTER_PASS

	print("Secondary counter: ", secondary_counter)
	print("Main counter: ", main_counter)
	print("Secondary hit counters: ", secondary_hit_counters)
	print("Main hit counters: ", main_hit_counters)

	# Instead of using signals, we'll check mouse position manually in _process
	print("Hover functionality setup complete - using manual detection")

func setup_hit_counter_system():
	"""Initialize the hit counter display system"""
	print("Setting up hit counter system...")

	# The hit counter containers are already created in the scene file
	# Just ensure they start hidden
	main_counter_temp.visible = false
	sec_counter_temp.visible = false

	# Map hit types to their counter references for easy access
	hit_counter_styles = {
		"penetration": {"main": temp_penetration_counter, "sec": temp_sec_penetration_counter, "main_label": temp_penetration_count_label, "sec_label": temp_sec_penetration_count_label},
		"overpenetration": {"main": temp_overpenetration_counter, "sec": temp_sec_overpenetration_counter, "main_label": temp_overpenetration_count_label, "sec_label": temp_sec_overpenetration_count_label},
		"shatter": {"main": temp_shatter_counter, "sec": temp_sec_shatter_counter, "main_label": temp_shatter_count_label, "sec_label": temp_sec_shatter_count_label},
		"ricochet": {"main": temp_ricochet_counter, "sec": temp_sec_ricochet_counter, "main_label": temp_ricochet_count_label, "sec_label": temp_sec_ricochet_count_label},
		"citadel": {"main": temp_citadel_counter, "sec": temp_sec_citadel_counter, "main_label": temp_citadel_count_label, "sec_label": temp_sec_citadel_count_label}
	}

	print("Hit counter system setup complete")

func setup_hit_counter_styles():
	"""Setup style resources for different hit types"""
	# This function is no longer needed since we duplicate existing UI elements
	# The styles are already defined in the scene file
	pass

func show_hit_counter(hit_type: String, is_secondary: bool):
	"""Show or update a hit counter for the specified type"""
	if hit_type not in hit_counter_styles:
		print("Warning: Unknown hit type: ", hit_type)
		return

	var counter_key = hit_type + ("_sec" if is_secondary else "_main")
	var counter_refs = hit_counter_styles[hit_type]
	# Get the appropriate counter and label
	var counter: Control = counter_refs["sec"] if is_secondary else counter_refs["main"]
	var count_label: Label = counter_refs["sec_label"] if is_secondary else counter_refs["main_label"]
	var container: HBoxContainer = sec_counter_temp if is_secondary else main_counter_temp
	active_hit_timers[container] = hit_counter_display_time  # Reset global timer whenever a hit is registered

	# Check if counter already exists in active tracking
	if counter_key in active_hit_counters:
		# Update existing counter
		var counter_data = active_hit_counters[counter_key]
		counter_data.count += 1
		# counter_data.timer = hit_counter_display_time  # Reset timer
		count_label.text = str(counter_data.count)
	else:
		# Show new counter
		counter.visible = true
		container.visible = true
		count_label.text = "1"

		# Store counter data
		active_hit_counters[counter_key] = {
			"counter": counter,
			"container": container,
			"label": count_label,
			"count": 1,
			# "timer": hit_counter_display_time,
			"is_secondary": is_secondary
		}

func update_hit_counters(delta: float):
	"""Update hit counter timers and hide expired ones"""
	var keys_to_remove = []

	for container in active_hit_timers.keys():
		active_hit_timers[container] -= delta
		if active_hit_timers[container] <= 0.0:
			# Hide all active counters
			for key in active_hit_counters:
				var counter_data = active_hit_counters[key]
				if counter_data.container == container:
					counter_data.counter.visible = false
					keys_to_remove.append(key)

	# for key in active_hit_counters:
	# 	var counter_data = active_hit_counters[key]
	# 	counter_data.timer -= delta

	# 	if counter_data.timer <= 0.0:
	# 		# Hide expired counter
	# 		counter_data.counter.visible = false
	# 		keys_to_remove.append(key)

	# Remove expired counters from tracking
	for key in keys_to_remove:
		active_hit_counters.erase(key)

	# Hide containers if no counters are active
	var main_has_active = false
	var sec_has_active = false

	for key in active_hit_counters:
		if active_hit_counters[key].is_secondary:
			sec_has_active = true
		else:
			main_has_active = true

	main_counter_temp.visible = main_has_active
	sec_counter_temp.visible = sec_has_active

func update_visibility_indicator():
	"""Update the visibility indicator based on ship's visible_to_enemy flag"""
	if not camera_controller or not camera_controller._ship:
		visibility_indicator.visible = false
		return

	# Show the yellow indicator when the ship is visible to enemies
	visibility_indicator.visible = camera_controller._ship.visible_to_enemy

func process_damage_events(damage_events: Array):
	"""Process damage events and show appropriate hit counters"""
	var stats = camera_controller._ship.stats
	for event in damage_events:
		var hit_type = get_hit_type_from_event(event)
		var is_secondary = event.get("sec", false)

		# Update appropriate hit counters based on event type
		var event_type: ArmorInteraction.HitResult = event.get("type", -1)
		match event_type:
			ArmorInteraction.HitResult.PENETRATION:
				if is_secondary:
					update_counter(sec_penetration_count_label, stats.sec_penetration_count)
				else:
					update_counter(penetration_count_label, stats.penetration_count)
			ArmorInteraction.HitResult.OVERPENETRATION:
				if is_secondary:
					update_counter(sec_overpenetration_count_label, stats.sec_overpen_count)
				else:
					update_counter(overpenetration_count_label, stats.overpen_count)
			ArmorInteraction.HitResult.SHATTER:
				if is_secondary:
					update_counter(sec_shatter_count_label, stats.sec_shatter_count)
				else:
					update_counter(shatter_count_label, stats.shatter_count)
			ArmorInteraction.HitResult.RICOCHET:
				if is_secondary:
					update_counter(sec_ricochet_count_label, stats.sec_ricochet_count)
				else:
					update_counter(ricochet_count_label, stats.ricochet_count)
			ArmorInteraction.HitResult.CITADEL:
				if is_secondary:
					update_counter(sec_citadel_count_label, stats.sec_citadel_count)
				else:
					update_counter(citadel_count_label, stats.citadel_count)
			_:
				print("Warning: Unhandled hit type: ", hit_type)
				
	
		if is_secondary:
			update_counter(sec_damage_label, stats.sec_damage)
			update_counter(secondary_count_label, stats.secondary_count)
		else:
			update_counter(main_damage_label, stats.main_damage)
			update_counter(main_count_label, stats.main_hits)

		##########################################################

		if hit_type != "":
			show_hit_counter(hit_type, is_secondary)

		create_floating_damage(event.damage, event.position)

	update_counter(damage_value_label, stats.total_damage)
	# Clear damage events after processing to prevent duplicate processing
	damage_events.clear()

func get_hit_type_from_event(event: Dictionary) -> String:
	"""Convert damage event type to hit counter type"""
	var event_type: ArmorInteraction.HitResult = event.get("type", -1)

	# Map HitResult enum values to strings
	match event_type:
		ArmorInteraction.HitResult.PENETRATION: return "penetration"    # HitResult.PENETRATION
		ArmorInteraction.HitResult.RICOCHET: return "ricochet"       # HitResult.RICOCHET
		ArmorInteraction.HitResult.OVERPENETRATION: return "overpenetration" # HitResult.OVERPENETRATION
		ArmorInteraction.HitResult.SHATTER: return "shatter"        # HitResult.SHATTER
		ArmorInteraction.HitResult.CITADEL: return "citadel"        # HitResult.CITADEL
		_: return ""               # Unknown or no hit

# Manual hover detection in _process
var was_hovering_secondary = false
var was_hovering_main = false

func check_hover_detection():
	if not secondary_counter or not main_counter:
		return

	var mouse_pos = get_viewport().get_mouse_position()

	# Check secondary counter hover
	var sec_rect = Rect2(secondary_counter.global_position, secondary_counter.size)
	var is_hovering_secondary = sec_rect.has_point(mouse_pos)

	if is_hovering_secondary != was_hovering_secondary:
		was_hovering_secondary = is_hovering_secondary
		if is_hovering_secondary:
			_on_secondary_hover_enter()
		else:
			_on_secondary_hover_exit()

	# Check main counter hover
	var main_rect = Rect2(main_counter.global_position, main_counter.size)
	var is_hovering_main = main_rect.has_point(mouse_pos)

	if is_hovering_main != was_hovering_main:
		was_hovering_main = is_hovering_main
		if is_hovering_main:
			_on_main_hover_enter()
		else:
			_on_main_hover_exit()

func _on_secondary_hover_enter():
	print("Secondary hover enter!")
	secondary_hit_counters.visible = true

func _on_secondary_hover_exit():
	print("Secondary hover exit!")
	secondary_hit_counters.visible = false

func _on_main_hover_enter():
	print("Main hover enter!")
	main_hit_counters.visible = true

func _on_main_hover_exit():
	print("Main hover exit!")
	main_hit_counters.visible = false


func _update_ui():
	# Time and distance are updated by setters, so we only need to update ship-specific UI here

	# Update ship status
	speed_label.text = "Speed: %.1f knots" % ship_speed

	if true:
		# Update throttle display
		var throttle_level = camera_controller._ship.movement_controller.throttle_level
		var throttle_display = ""

		match throttle_level:
			-1: throttle_display = "Reverse"
			0: throttle_display = "Stop"
			1: throttle_display = "1/4"
			2: throttle_display = "1/2"
			3: throttle_display = "3/4"
			4: throttle_display = "Full"

		throttle_label.text = "Throttle: " + throttle_display
		throttle_slider.value = throttle_level

		# Update rudder display
		var rudder_value = camera_controller._ship.movement_controller.rudder_input
		var rudder_display = ""

		if abs(rudder_value) < 0.1:
			rudder_display = "Center"
		elif rudder_value > 0:
			if rudder_value > 0.75:
				rudder_display = "Hard Port"
			elif rudder_value > 0.25:
				rudder_display = "Port"
			else:
				rudder_display = "Slight Port"
		else:
			if rudder_value < -0.75:
				rudder_display = "Hard Starboard"
			elif rudder_value < -0.25:
				rudder_display = "Starboard"
			else:
				rudder_display = "Slight Starboard"

		rudder_label.text = "Rudder: " + rudder_display
		rudder_slider.value = rudder_value

		# Color sliders based on values
		if rudder_value > 0: # Port (left)
			rudder_slider.modulate = Color(1, 0.5, 0.5) # Red tint for port
		elif rudder_value < 0: # Starboard (right)
			rudder_slider.modulate = Color(0.5, 1, 0.5) # Green tint for starboard
		else:
			rudder_slider.modulate = Color(1, 1, 1) # White for center

		# Throttle slider color
		if throttle_level > 0: # Forward
			throttle_slider.modulate = Color(0.5, 0.8, 1.0) # Blue for forward
		elif throttle_level < 0: # Reverse
			throttle_slider.modulate = Color(1.0, 0.8, 0.5) # Orange for reverse
		else:
			throttle_slider.modulate = Color(1, 1, 1) # White for stop

	# Update HP display
	if camera_controller._ship.health_controller:
		var current_hp = camera_controller._ship.health_controller.current_hp
		var max_hp = camera_controller._ship.health_controller.max_hp
		var hp_percent = (float(current_hp) / max_hp) * 100.0

		hp_bar.value = hp_percent
		hp_label.text = "%d/%d" % [current_hp, max_hp]

		# Change HP bar color based on health level
		if hp_percent > 75:
			hp_bar.modulate = Color(0.2, 0.9, 0.2) # Green
		elif hp_percent > 50:
			hp_bar.modulate = Color(1.0, 1.0, 0.2) # Yellow
		elif hp_percent > 25:
			hp_bar.modulate = Color(1.0, 0.6, 0.2) # Orange
		else:
			hp_bar.modulate = Color(0.9, 0.2, 0.2) # Red

func _update_fps():
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()

func _update_camera_angle_display():
	if camera_controller and camera_controller._ship:
		# Get camera forward vector on XZ plane (ignore Y component)
		var camera_forward = -camera_controller.global_transform.basis.z
		var camera_forward_xz = Vector2(camera_forward.x, camera_forward.z).normalized()

		# Get ship forward vector on XZ plane
		var ship_forward = -camera_controller._ship.global_transform.basis.z
		var ship_forward_xz = Vector2(ship_forward.x, ship_forward.z).normalized()

		# Calculate angle between the vectors
		var angle_rad = camera_forward_xz.angle_to(ship_forward_xz)
		var angle_deg = abs(rad_to_deg(angle_rad))

		if angle_deg > 90.0:
			angle_deg = 180.0 - angle_deg

		# Format the angle
		camera_angle_label.text = "Camera: %.1f°" % angle_deg

		# Position in top left corner, below FPS
		camera_angle_label.size = Vector2(120, 25)
		camera_angle_label.position = Vector2(10, 40)


func _on_crosshair_container_draw():
	# Draw locked target indicator
	if target_lock_enabled and locked_target and is_instance_valid(locked_target):
		var target_screen_pos = camera_controller.unproject_position(locked_target.global_position)
		var crosshair_pos = crosshair_container.global_position + crosshair_container.size / 2.0

		# Draw line to locked target if it's visible
		if is_position_visible_on_screen(locked_target.global_position):
			var relative_target_pos = target_screen_pos - crosshair_pos
			crosshair_container.draw_line(Vector2.ZERO, relative_target_pos, Color(1, 0, 0, 0.8), 2.0)
			crosshair_container.draw_circle(relative_target_pos, 10, Color(1, 0, 0, 0.6), false, 2.0)

func setup_ship_ui(ship):
	if ship == camera_controller._ship or ship in ship_ui_elements:
		return # Skip own ship or already tracked ships

	# Determine if ship is friendly or enemy
	var is_enemy = true
	var my_team_id = -1
	var ship_team_id = -2

	if camera_controller._ship.team:
		var my_team_entity = camera_controller._ship.team
		if my_team_entity.has_method("get_team_info"):
			my_team_id = my_team_entity.get_team_info()["team_id"]

	if ship.team:
		var ship_team_entity = ship.team
		if ship_team_entity.has_method("get_team_info"):
			ship_team_id = ship_team_entity.get_team_info()["team_id"]

	if my_team_id != -1 and ship_team_id != -2:
		is_enemy = my_team_id != ship_team_id

	# Choose the appropriate template and duplicate it
	var template = enemy_ship_template if is_enemy else friendly_ship_template
	var ship_container = template.duplicate()
	ship_container.visible = false # Start hidden until positioned

	# Add to the main canvas layer instead of crosshair container
	add_child(ship_container)

	# Get references to the duplicated UI elements
	var name_label: Label
	var ship_hp_bar: ProgressBar
	var ship_hp_label: Label
	var target_indicator: ColorRect

	if is_enemy:
		name_label = ship_container.get_node("EnemyNameLabel")
		ship_hp_bar = ship_container.get_node("EnemyHPBar")
		ship_hp_label = ship_hp_bar.get_node("EnemyHPLabel")
		target_indicator = ship_container.get_node("EnemyTargetIndicator")
	else:
		name_label = ship_container.get_node("FriendlyNameLabel")
		ship_hp_bar = ship_container.get_node("FriendlyHPBar")
		ship_hp_label = ship_hp_bar.get_node("FriendlyHPLabel")
		target_indicator = ship_container.get_node("FriendlyTargetIndicator")

	# Set the ship name
	name_label.text = ship.name

	# Store the UI elements for this ship
	ship_ui_elements[ship] = {
		"container": ship_container,
		"name_label": name_label,
		"hp_bar": ship_hp_bar,
		"hp_label": ship_hp_label,
		"target_indicator": target_indicator
	}

func update_ship_ui():
	# Periodically search for new ships
	var current_time = Time.get_ticks_msec() / 1000.0
	var should_search = tracked_ships.is_empty() or (current_time - last_ship_search_time > ship_search_interval)

	if should_search:
		last_ship_search_time = current_time

		# Try to find ships in different possible locations
		var ships = []
		var possible_paths = [
			"/root/Server/GameWorld/Players",
			"/root/GameWorld/Players",
			"/root/Main/Players"
		]

		for path in possible_paths:
			var players_node = get_node_or_null(path)
			if players_node:
				ships = players_node.get_children()
				# print("Found ships at: ", path, " - Count: ", ships.size())
				break

		if ships.is_empty():
			# Fallback: search for all ships in the scene
			ships = get_tree().get_nodes_in_group("ships")
			if ships.is_empty():
				# Last resort: find all Ship nodes in the tree
				ships = []
				var root = get_tree().root
				_find_ships_recursive(root, ships)

		for ship in ships:
			if ship != camera_controller._ship and ship is Ship and not tracked_ships.has(ship):
				tracked_ships[ship] = true
				setup_ship_ui(ship)
				minimap.register_ship(ship)
				print("Registered ship for UI and minimap: ", ship.name, " at position: ", ship.global_position)

	# Update each ship's UI
	for ship in tracked_ships.keys():
		if is_instance_valid(ship) and ship in ship_ui_elements and ship is Ship:
			var ui = ship_ui_elements[ship]

			# Get ship's HP if it has an HP manager
			var ship_hp_manager = ship.health_controller
			if ship_hp_manager:
				var current_hp = ship_hp_manager.current_hp
				var max_hp = ship_hp_manager.max_hp
				var hp_percent = (float(current_hp) / max_hp) * 100.0

				# Update progress bar and label (colors are already set by template)
				ui.hp_bar.value = hp_percent
				ui.hp_label.text = "%d/%d" % [current_hp, max_hp]

			# Update target indicator visibility
			var is_targeted = (ship == current_secondary_target)
			ui.target_indicator.visible = is_targeted

			# # Add pulsing animation to target indicator if targeted
			# if is_targeted:
			# 	var pulse_value = (sin(Time.get_ticks_msec() / 1000.0 * 4.0) + 1.0) / 2.0  # Oscillates between 0 and 1
			# 	var base_color = Color(1, 0.6, 0, 0.9)  # Orange color
			# 	ui.target_indicator.color = base_color.lerp(Color(1, 1, 0, 1), pulse_value * 0.5)  # Pulse to yellow

			# Position UI above ship in the world
			var ship_position = ship.global_position + Vector3(0, 20, 0) # Add height offset
			var screen_pos = get_viewport().get_camera_3d().unproject_position(ship_position)

			# Check if ship is visible on screen
			var ship_visible = is_position_visible_on_screen(ship_position) and ship.visible
			ui.container.visible = ship_visible && (ship as Ship).health_controller.is_alive()

			if ship_visible:
				# Position the container above the ship, centered
				var container_size = Vector2(90, 40) # Use template size
				ui.container.position = screen_pos - Vector2(container_size.x / 2, container_size.y)
		else:
			# Ship no longer valid, remove it
			if ship in ship_ui_elements:
				for element in ship_ui_elements[ship].values():
					if is_instance_valid(element):
						element.queue_free()
				ship_ui_elements.erase(ship)
			tracked_ships.erase(ship)

func _find_ships_recursive(node: Node, ships: Array):
	if node is Ship:
		ships.append(node)
	for child in node.get_children():
		_find_ships_recursive(child, ships)

func is_position_visible_on_screen(world_position):
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return false

	# Check if position is in front of camera
	var camera_direction = -camera.global_transform.basis.z.normalized()
	var to_position = (world_position - camera.global_position).normalized()
	if camera_direction.dot(to_position) <= 0:
		return false

	# Get screen position
	var screen_position = camera.unproject_position(world_position)

	# Check if position is on screen
	var viewport_rect = get_viewport().get_visible_rect()
	return viewport_rect.has_point(screen_position)

func update_team_tracker():
	"""Update the team tracker with current ship status"""
	if not camera_controller or not camera_controller._ship:
		return

	# Set friendly team ID if not already set
	if friendly_team_id == -1 and camera_controller._ship.team:
		friendly_team_id = camera_controller._ship.team.team_id

	# Get server reference
	var server: GameServer = get_tree().root.get_node_or_null("Server")
	if not server:
		return

	# Get all ships from server (including dead ones)
	var friendly_ships = server.get_team_ships(friendly_team_id)
	var enemy_ships = server._get_enemy_ships(friendly_team_id)
	#print("Friendly ships count: ", friendly_ships.size(), " | Enemy ships count: ", enemy_ships.size())

	# Update friendly ships display
	update_team_container(friendly_ships_container, friendly_ships, true)

	# Update enemy ships display
	update_team_container(enemy_ships_container, enemy_ships, false)

	# Resize the team tracker panel to fit content
	resize_team_tracker_panel(friendly_ships.size(), enemy_ships.size())

func update_team_container(container: HBoxContainer, ships: Array, is_friendly: bool):
	"""Update a team container with ship indicators using templates"""
	# Get current indicators in container
	var existing_indicators = []
	for child in container.get_children():
		existing_indicators.append(child)

	# Remove indicators for ships that are no longer in the server's ship list
	for indicator in existing_indicators:
		var associated_ship = null

		# Find which ship this indicator belongs to
		for ship in team_ship_indicators.keys():
			if team_ship_indicators[ship] == indicator:
				associated_ship = ship
				break

		if associated_ship:
			# Check if ship is still in current ships list from server
			var still_in_server_list = false
			for ship in ships:
				if ship == associated_ship:
					still_in_server_list = true
					break

			# Remove if not in server list or if ship object is invalid
			if not still_in_server_list or not is_instance_valid(associated_ship):
				team_ship_indicators.erase(associated_ship)
				indicator.queue_free()

	# Add or update indicators for current ships from server
	for ship in ships:
		if not is_instance_valid(ship):
			continue

		var indicator: Control

		if ship in team_ship_indicators:
			indicator = team_ship_indicators[ship]
			# Make sure it's in the right container
			if indicator.get_parent() != container:
				indicator.reparent(container)
		else:
			# Create new indicator from template
			indicator = team_tracker_template.duplicate()
			indicator.visible = true
			container.add_child(indicator)
			team_ship_indicators[ship] = indicator

		# Update indicator appearance
		update_team_indicator(indicator, ship, is_friendly)

func update_team_indicator(indicator: Control, ship: Ship, is_friendly: bool):
	"""Update the appearance of a team indicator based on ship status"""
	var ship_indicator: ColorRect = indicator.get_node("ShipIndicator")
	var hp_indicator: ProgressBar = indicator.get_node("HPIndicator")

	# Check if ship is alive
	var is_alive = ship.health_controller and ship.health_controller.is_alive()
	var health_percent = 1.0

	if ship.health_controller:
		health_percent = float(ship.health_controller.current_hp) / ship.health_controller.max_hp
		hp_indicator.value = health_percent * 100.0

	if is_alive:
		# Ship is alive - use team colors
		if is_friendly:
			ship_indicator.color = Color(0.2, 0.9, 0.4, 0.8)
			# Create friendly HP bar style
			var friendly_style = StyleBoxFlat.new()
			friendly_style.bg_color = Color(0.2, 0.9, 0.4, 1)
			hp_indicator.add_theme_stylebox_override("fill", friendly_style)
		else:
			ship_indicator.color = Color(0.9, 0.2, 0.2, 0.8)
			# Create enemy HP bar style
			var enemy_style = StyleBoxFlat.new()
			enemy_style.bg_color = Color(0.9, 0.2, 0.2, 1)
			hp_indicator.add_theme_stylebox_override("fill", enemy_style)
	else:
		# Ship is dead - use dark gray
		ship_indicator.color = Color(0.3, 0.3, 0.3, 0.8)
		# Create dead HP bar style
		var dead_style = StyleBoxFlat.new()
		dead_style.bg_color = Color(0.3, 0.3, 0.3, 1)
		hp_indicator.add_theme_stylebox_override("fill", dead_style)
		hp_indicator.value = 0.0

func resize_team_tracker_panel(friendly_count: int, enemy_count: int):
	"""Resize the team tracker panel to fit all ships"""
	if not top_center_panel:
		return

	# Calculate required width:
	# - Each ship indicator: 50px wide
	# - Spacing between indicators: 5px (handled by HBoxContainer)
	# - VSeparator: ~20px
	# - Padding: 20px (10px on each side)
	# - Minimum width: 200px

	var friendly_width = friendly_count * 55  # 50px + 5px spacing per ship
	var enemy_width = enemy_count * 55
	var separator_width = 20
	var padding = 20
	var min_width = 200

	var total_width = max(min_width, friendly_width + enemy_width + separator_width + padding)

	# Update the panel size (height is now 50px to accommodate HP bars)
	var half_width = total_width / 2
	top_center_panel.offset_left = -half_width
	top_center_panel.offset_right = half_width
	top_center_panel.offset_bottom = 60  # Increased height for HP bars

func cleanup_team_indicators():
	"""Clean up team indicators for invalid ships"""
	var ships_to_remove = []

	for ship in team_ship_indicators.keys():
		if not is_instance_valid(ship) or not ship.health_controller.is_alive():
			ships_to_remove.append(ship)

	for ship in ships_to_remove:
		if ship in team_ship_indicators:
			var indicator = team_ship_indicators[ship]
			if is_instance_valid(indicator):
				indicator.queue_free()
			team_ship_indicators.erase(ship)

func _on_weapon_button_pressed(idx: int):
	# Deselect all other weapon buttons
	for i in range(weapon_buttons.size()):
		weapon_buttons[i].button_pressed = (i == idx)

	# Notify camera controller or ship of weapon selection
	if camera_controller:
		# This would typically call a method on the ship or player controller
		print("Selected weapon: %d" % idx)

func set_weapon_button_pressed(idx: int):
	if idx >= 0 and idx < weapon_buttons.size():
		for i in range(weapon_buttons.size()):
			weapon_buttons[i].button_pressed = (i == idx)

# Gun reload bar management
func setup_gun_reload_bars():
	# Clear existing reload bars
	for bar in gun_reload_bars:
		if is_instance_valid(bar):
			bar.queue_free()
	gun_reload_bars.clear()
	gun_reload_timers.clear()
	reload_bar_template.visible = false

	# Get guns from ship artillery controller
	if camera_controller and camera_controller._ship and camera_controller._ship.artillery_controller:
		guns = camera_controller._ship.artillery_controller.guns

		for i in range(guns.size()):
			# Duplicate the template progress bar
			var progress_bar = reload_bar_template.duplicate()
			progress_bar.visible = true
			progress_bar.value = guns[i].reload if guns[i] else 1.0

			gun_reload_container.add_child(progress_bar)
			gun_reload_bars.append(progress_bar)
			gun_reload_timers.append(progress_bar.get_child(0))

func update_gun_reload_bars():
	# Update reload progress for each gun
	for i in range(min(guns.size(), gun_reload_bars.size())):
		if is_instance_valid(guns[i]) and is_instance_valid(gun_reload_bars[i]):
			var gun: Gun = guns[i]
			var bar = gun_reload_bars[i]
			var timer_label = gun_reload_timers[i]
			var gun_params: GunParams = (gun.controller as ArtilleryController).params.params() as GunParams

			# Update reload progress
			bar.value = gun.reload
			if gun.reload >= 1.0:
				timer_label.text = "%.1f" % (gun.reload * gun_params.reload_time)
			else:
				timer_label.text = "%.1f s" % ((1.0 - gun.reload) * gun_params.reload_time)

			# dull if no valid target
			# bright if valid target
			# teal if reloaded
			# yellow if reloading
			# brighter teal if reloaded and can fire and valid target
			if gun._valid_target and gun.reload >= 1.0 and gun.can_fire:
				bar.self_modulate = Color(0.4, 0.95, 0.9)  # Brighter teal - ready to fire at valid target
			elif gun._valid_target and gun.reload >= 1.0:
				bar.self_modulate = Color(0.2, 0.7, 0.6)  # Bright teal - ready to fire
			elif gun._valid_target:
				bar.self_modulate = Color(1.0, 1.0, 0.2)  # Bright yellow - reloading but can fire
			elif gun.reload >= 1.0:
				bar.self_modulate = Color(0.1, 0.45, 0.4)  # Dull teal - reloaded but can't fire
			else:
				bar.self_modulate = Color(0.5, 0.5, 0.1)  # Dull Yellow - still reloading

# Property setters to automatically update UI when values change
func set_time_to_target(value: float):
	time_to_target = value
	if time_label:
		time_label.text = "%.1f s" % (value)

func set_distance_to_target(value: float):
	distance_to_target = value
	if distance_label:
		distance_label.text = "%.2f m" % value

func set_aim_position(value: Vector3):
	aim_position = value
	if minimap:
		minimap.aim_point = value

func set_ship_speed(value: float):
	ship_speed = value
	# Ship speed will be updated in _update_ui() along with other ship status

func set_locked_target(value):
	locked_target = value
	# Trigger redraw of crosshair for target indicators
	if crosshair_container:
		crosshair_container.queue_redraw()

func set_target_lock_enabled(value: bool):
	target_lock_enabled = value
	# Update crosshair drawing to show lock indicator

func update_counter(label: Label, count):
	if label:
		label.text = str(int(count))

# Function to create floating damage at a world position
func create_floating_damage(damage: int, world_position: Vector3):
	"""
	Creates a floating damage label that appears above the hit point.

	Args:
		damage: The damage amount to display
		world_position: World position where the damage occurred
	"""
	if damage <= 0:
		return
	# Instantiate the floating damage scene
	var floating_damage = FloatingDamageScene.instantiate()

	# Configure the floating damage
	floating_damage.damage_amount = damage
	floating_damage.world_position = world_position

	# Add to the scene
	add_child(floating_damage)

func setup_consumable_ui():
	if not camera_controller or not camera_controller._ship:
		return
	consumable_template.visible = false

	var consumable_manager = camera_controller._ship.consumable_manager

	# Create buttons for each consumable slot
	for i in consumable_manager.equipped_consumables.size():
		var button: TextureButton = consumable_template.duplicate()
		button.visible = true
		button.disabled = false
		button.connect("pressed", _on_consumable_pressed.bind(i))

		# Set up initial icon and state
		var item = consumable_manager.equipped_consumables[i]
		button.texture_normal = item.icon
		button.texture_disabled = item.disabled_icon


		# Set keyboard shortcut text
		var shortcut_label: Label = button.get_node("KeyboardShortcutLabel") as Label
		if i < consumable_actions.size():
			shortcut_label.text = get_keyboard_shortcut_for_action(consumable_actions[i])
		else:
			shortcut_label.text = ""

		consumable_container.add_child(button)

		consumable_buttons.append(button)
		consumable_cooldown_bars.append(button.get_node("ProgressBar") as ProgressBar)
		consumable_shortcut_labels.append(shortcut_label)
		var count_label: Label = button.get_node("CountLabel") as Label
		count_label.text = ""
		consumable_count_labels.append(count_label)

func _on_consumable_pressed(slot: int):
	if camera_controller and camera_controller._ship:
		camera_controller._ship.consumable_manager.use_consumable_rpc.rpc_id(1, slot)

func update_consumable_ui():
	if not camera_controller or not camera_controller._ship:
		return

	var consumable_manager = camera_controller._ship.consumable_manager

	for i in range(consumable_buttons.size()):
		var button = consumable_buttons[i]
		var cooldown_bar = consumable_cooldown_bars[i]

		if i < consumable_manager.equipped_consumables.size():
			var item: ConsumableItem = consumable_manager.equipped_consumables[i]
			if item:
				# Only update dynamic properties
				# button.disabled = not consumable_manager.can_use_item(item)
				if item.max_stack != -1:
					consumable_count_labels[i].text = str(item.current_stack)

				var cooldown_remaining = consumable_manager.cooldowns.get(item.id, 0.0)
				var effect_remaining = consumable_manager.active_effects.get(item.id, 0.0)
				# Disable button if no stacks left and no active effect
				button.disabled = item.current_stack <= 0 and effect_remaining <= 0
				# Update cooldown display
				if cooldown_remaining > 0:
					cooldown_bar.value = (cooldown_remaining / item.cooldown_time) * 100
					cooldown_bar.modulate = Color(1.0, 1.0, 0.0) # Yellow tint during cooldown
					cooldown_bar.visible = true
				elif effect_remaining > 0:
					cooldown_bar.value = 100 - (effect_remaining / item.duration) * 100
					cooldown_bar.modulate = Color(0.2, 0.8, 1.0) # Blue tint during effect
					cooldown_bar.visible = true
				else:
					cooldown_bar.visible = false
			else:
				button.disabled = true

# Function to set the current secondary target
func set_secondary_target(target_ship: Ship) -> void:
	current_secondary_target = target_ship
	# Target indicators will be updated in the next frame during update_ship_ui()

# Function to clear the current secondary target
func clear_secondary_target() -> void:
	current_secondary_target = null
	# Target indicators will be updated in the next frame during update_ship_ui()
