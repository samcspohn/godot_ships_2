extends CanvasLayer

class_name CameraUIScene

# Preload the floating damage scene
const FloatingDamageScene = preload("res://scenes/floating_damage.tscn")
const GunIndicatorScene = preload("res://src/ui/gun_indicator.tscn")
const HitStatCountersScene = preload("res://src/ui/hit_stat_counters.tscn")
const KillFeedScene = preload("res://src/ui/kill_feed.tscn")
const HoverTooltipScript = preload("res://src/ui/hover_tooltip.gd")
const TorpedoOverlayScene = preload("res://src/ui/torpedo_overlay.tscn")

# Camera controller reference
var camera_controller: BattleCamera
var player_controller: PlayerController

@export var reloading_gun_color: Color = Color(1, 0, 0)
@export var ready_gun_color: Color = Color(0, 1, 0)
@export var disabled_gun_color: Color = Color(0.5, 0.5, 0.5)
@export var valid_can_fire_color_mod: float = 1.0
@export var valid_cannot_fire_color_mod: float = 0.7
@export var invalid_cannot_fire_color_mod: float = 0.4
@export var fire_buildup_color: Color = Color(0.65, 0.32, 0.08)
@export var fire_burning_color: Color = Color(1.0, 0.55, 0.05)
@export var flood_buildup_color: Color = Color(0.08, 0.22, 0.5)
@export var flood_active_color: Color = Color(0.1, 0.55, 1.0)

# Properties that BattleCamera sets directly - these need to match the interface
var time_to_target: float = 0.0 : set = set_time_to_target
var distance_to_target: float = 0.0 : set = set_distance_to_target
var terrain_hit: bool = false : set = update_terrain_hit_indicator
var penetration_power: float = 0.0 : set = set_penetration_power
var aim_position: Vector3 = Vector3.ZERO : set = set_aim_position
var max_range_reached: bool = false
var ship_speed: float = 0.0 : set = set_ship_speed
var locked_target = null : set = set_locked_target
var target_lock_enabled: bool = false : set = set_target_lock_enabled

# UI node references - these will be populated from the scene
@onready var crosshair_container: Control = $MainContainer/CrosshairContainer
var _box_select_overlay: Control
var _box_select_rect: Rect2 = Rect2()
var _box_select_visible: bool = false
@onready var crosshair_center: Control = $MainContainer/CrosshairContainer/CrosshairCenter
@onready var time_label: Label = $MainContainer/CrosshairContainer/TargetInfoContainer/TargetInfo/TimeLabel
@onready var distance_label: Label = $MainContainer/CrosshairContainer/TargetInfoContainer/TargetInfo/DistanceLabel
@onready var penetration_label: Label = $MainContainer/CrosshairContainer/TargetInfoContainer/TargetInfo2/PenetrationLabel

@onready var gun_indicator: Control = $MainContainer/CrosshairContainer/GunIndicator
var torpedo_overlay: TorpedoOverlay = null

# Sniper reticle control (created programmatically)
var sniper_reticle: Control = null
var target_speed_label: Label = null  # Label to show locked target's speed

@onready var fps_label: Label = $MainContainer/TopLeftPanel/FPSLabel
@onready var camera_angle_label: Label = $MainContainer/TopLeftPanel/CameraAngleLabel

# Hit/Stat counters component (self-contained)
var hit_stat_counters: HitStatCounters = null

# Kill feed component
var kill_feed: KillFeed = null

# Visibility indicators (one per detection type)
@onready var det_los_indicator: ColorRect = $MainContainer/VisibilityContainer/LOSIndicator
@onready var det_los_counter: Label = $MainContainer/VisibilityContainer/LOSIndicator/Counter
@onready var det_hydro_indicator: ColorRect = $MainContainer/VisibilityContainer/HydroIndicator
@onready var det_radar_indicator: ColorRect = $MainContainer/VisibilityContainer/RadarIndicator
@onready var det_air_indicator: ColorRect = $MainContainer/VisibilityContainer/AirIndicator
@onready var det_incoming_fire_indicator: ColorRect = $MainContainer/VisibilityContainer/IncomingFireIndicator

# Terrain hit indicator
@onready var terrain_hit_indicator: ColorRect = $MainContainer/CrosshairContainer/TerrainIndicator

# Team tracker references
@onready var top_center_panel: Control = $MainContainer/TopCenterPanel
@onready var team_tracker_container: Control = $MainContainer/TopCenterPanel/TeamTrackerContainer
@onready var match_timer_label: Label = $MainContainer/TopCenterPanel/MatchTimerLabel
@onready var friendly_ships_container: HBoxContainer = $MainContainer/TopCenterPanel/TeamTrackerContainer/FriendlyShipsContainer
@onready var enemy_ships_container: HBoxContainer = $MainContainer/TopCenterPanel/TeamTrackerContainer/EnemyShipsContainer

@onready var speed_label: Label = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/SpeedLabel
@onready var throttle_label: Label = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/ThrottleLabel
@onready var rudder_label: Label = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/RudderLabel
@onready var rudder_slider: HSlider = $MainContainer/BottomLeftPanel/HBoxContainer/ShipStatusContainer/RudderSlider
@onready var throttle_slider: VSlider = $MainContainer/BottomLeftPanel/HBoxContainer/ThrottleSlider

@onready var hp_bar: ProgressBar = $MainContainer/BottomCenterPanel/Content/HPContainer/HPBarContainer/HPBar
@onready var healable_hp_bar: ProgressBar = $MainContainer/BottomCenterPanel/Content/HPContainer/HPBarContainer/HealableHPBar
@onready var hp_label: Label = $MainContainer/BottomCenterPanel/Content/HPContainer/HPBarContainer/HPLabel

@onready var gun_reload_container: HBoxContainer = $MainContainer/BottomCenterPanel/Content/WeaponsContainer/ReloadContainer
@onready var reload_bar_template: ProgressBar = $MainContainer/BottomCenterPanel/Content/WeaponsContainer/ReloadContainer/ReloadBarTemplate

@onready var fire_bar_container: HBoxContainer = $MainContainer/BottomCenterPanel/Content/FireContainer
@onready var fire_bar_template: ProgressBar = $MainContainer/BottomCenterPanel/Content/FireContainer/FireBarTemplate
var fire_bars: Array[ProgressBar] = []

@onready var flood_bar_container: HBoxContainer = $MainContainer/BottomCenterPanel/Content/FloodContainer
@onready var flood_bar_template: ProgressBar = $MainContainer/BottomCenterPanel/Content/FloodContainer/FloodBarTemplate
var flood_bars: Array[ProgressBar] = []

@onready var status_indicators_container: HBoxContainer = $MainContainer/BottomCenterPanel/Content/StatusIndicators

@onready var bottom_right_panel: Control = $MainContainer/BottomRightPanel

@onready var ship_ui_templates: Control = $MainContainer/ShipUITemplates
@onready var enemy_ship_template: Control = $MainContainer/ShipUITemplates/EnemyShipTemplate
@onready var friendly_ship_template: Control = $MainContainer/ShipUITemplates/FriendlyShipTemplate
@onready var team_tracker_template: Control = $MainContainer/ShipUITemplates/TeamTrackerTemplate

# @onready var weapon_buttons: Array[Button] = [
# 	$MainContainer/BottomCenterPanel/Content/UsableContainer/WeaponPanel/Shell1Button,
# 	$MainContainer/BottomCenterPanel/Content/UsableContainer/WeaponPanel/Shell2Button,
# 	$MainContainer/BottomCenterPanel/Content/UsableContainer/WeaponPanel/TorpedoButton
# ]
var weapon_buttons: Array[Button] # todo: TextureButton
var weapon_button_group: ButtonGroup

@onready var consumable_container: HBoxContainer = $MainContainer/BottomCenterPanel/Content/UsableContainer/ConsumableContainer
@onready var consumable_template: TextureButton = $MainContainer/BottomCenterPanel/Content/UsableContainer/ConsumableContainer/ConsumableTemplate
@onready var friendly_consumable_status_texturerect: TextureRect = $MainContainer/ShipUITemplates/FriendlyShipTemplate/FriendlyStatus/FriendlyConsumable
var consumable_buttons: Array[TextureButton] = []
var consumable_cooldown_bars: Array[ProgressBar] = []
var consumable_overlay_labels: Array[Label] = []
var consumable_shortcut_labels: Array[Label] = []
var consumable_count_labels: Array[Label] = []
# Consumable action names for getting shortcuts from InputMap
var consumable_actions = ["consumable_1", "consumable_2", "consumable_3", "consumable_4", "consumable_5"]

@onready var secondaries_disabled = $MainContainer/BottomCenterPanel/Content/StatusIndicators/SecondariesDisabled

# Custom hover-tooltip overlay. Created in _ready(). Used in place of the
# engine's built-in Control.tooltip_text for any HUD element that needs to be
# inspected while the player is holding Ctrl (which suppresses native tooltips).
var hover_tooltip

var current_hp: float = 0.0

# Healable HP bar pulse animation
var healable_pulse_active: bool = false

var teams_hp = {}
var num_players = -1
var players_node: Node = null
var server: GameServer = null

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


class Weapon:
	var weapon: Turret
	var reload_bar: ProgressBar
	var indicator: Control
	var reload_timer: Label

# # Gun reload tracking
# var gun_reload_bars: Array[ProgressBar] = []
# var gun_indicators: Array[Control] = []
# var gun_reload_timers: Array[Label] = []
# var guns: Array[Gun] = []

var weapons: Dictionary[Node, Array] = {} # Maps Controller to its Weapon data

# Minimap
var minimap: Minimap

# Ship tracking
var tracked_ships = {}
var ship_ui_elements = {}

# Aircraft world-space markers
var aircraft_ui_elements: Dictionary = {}  # plane Node3D -> {container, label, owner_label}
var last_ship_search_time: float = 0.0
var ship_search_interval: float = 2.0  # Search for new ships every 2 seconds
var _status_refresh_timer: float = 0.0
const STATUS_REFRESH_INTERVAL: float = 0.1  # Refresh consumable status widgets at 10 hz

# Floating ship HP bars: "recently lost HP" damage bar. The damage bar holds the
# pre-damage HP level and only collapses to the current HP after this many
# seconds without further damage.
const DAMAGE_BAR_CLEAR_DELAY: float = 1.0
# How fast the damage bar drains down to its target when stepping to the next
# (lower) segment: 10% of max HP every 0.05 s, in ProgressBar value units (0-100).
const DAMAGE_BAR_DROP_RATE: float = 10.0 / 0.05  # = 200 value-units / second

# Target tracking for secondaries
var current_secondary_target: Ship = null

# Team tracker
var team_ship_indicators = {}  # Maps ship to its indicator ColorRect
var friendly_team_id: int = -1  # Will be set when camera_controller is available

# Battle end screen
var match_ended: bool = false
var _options_menu: Control = null

# Match timer (local countdown, corrected by server sync)
var _local_time_remaining: float = -1.0  # -1 = not yet initialized
var _last_seen_match_elapsed: float = -1.0  # last server elapsed we acted on
const MATCH_TIMER_SYNC_THRESHOLD: float = 1.5  # seconds of drift before snapping

# Floating damage accumulator (damage dealt, anchored to hit world position)
const DAMAGE_ACCUM_WINDOW: float = 0.25
var _damage_accum_active: bool = false
var _damage_accum_amount: float = 0.0
var _damage_accum_position: Vector3 = Vector3.ZERO
var _damage_accum_timer: float = 0.0

# Floating damage accumulator (damage received, position resolved at flush time)
var _recv_damage_accum_active: bool = false
var _recv_damage_accum_amount: float = 0.0
var _recv_damage_accum_timer: float = 0.0



func recurs_set_vis(n: Node):
	if n is CanvasItem:
		n.visibility_layer = 1 << 1
	for child in n.get_children():
		recurs_set_vis(child)

func _configure_weapon_button(button: Button, index: int) -> void:
	var shortcut = Shortcut.new()
	var key_event = InputEventKey.new()
	key_event.keycode = KEY_1 + index
	shortcut.events = [key_event]
	# button.shortcut = shortcut
	button.custom_minimum_size = Vector2(56, 56)
	button.toggle_mode = true
	# button.button_group = weapon_button_group
	# Weapon controllers now store a "tooltip_provider" Callable as meta so the
	# tooltip text is re-evaluated every physics frame (dynamic mod values, etc.).
	# Assert here so a missing meta is an obvious crash instead of a silent gap.
	assert(button.has_meta("tooltip_provider"), \
		"weapon button '%s' is missing tooltip_provider meta — set_meta must be called in get_weapon_ui()" % button.text)
	hover_tooltip.attach(button, button.get_meta("tooltip_provider") as Callable)

func _get_all_weapon_buttons() -> Array[Button]:
	var buttons: Array[Button] = []
	var ship = camera_controller._ship
	# var offset = 0
	buttons.append_array(ship.artillery_controller.get_weapon_ui(buttons.size()))
	# offset = buttons.size()

	if ship.torpedo_controller:
		buttons.append_array(ship.torpedo_controller.get_weapon_ui(buttons.size()))
		# offset = buttons.size()

	if ship.secondary_controller:
		buttons.append_array(ship.secondary_controller.get_weapon_ui(buttons.size()))
		# offset = buttons.size()

	if ship.aviation_controller:
		buttons.append_array(ship.aviation_controller.get_weapon_ui(buttons.size()))
		# offset = buttons.size()
	return buttons

func setup_weapon_buttons():
	var weapon_panel = $MainContainer/BottomCenterPanel/Content/UsableContainer/WeaponPanel
	for i in range(3):
		var button = weapon_panel.get_child(i)
		button.queue_free()

	# Create a ButtonGroup for mutual exclusion - only one weapon can be selected at a time
	weapon_button_group = ButtonGroup.new()
	weapon_buttons = _get_all_weapon_buttons()

	# Configure and add each button
	for i in weapon_buttons.size():
		var button = weapon_buttons[i]
		_configure_weapon_button(button, i)
		weapon_panel.add_child(button)

	# Select the first weapon button by default
	if weapon_buttons.size() > 0:
		weapon_buttons[0].button_pressed = true

var skills_status: Dictionary = {}

# func _set_up_skill_indicators():
# 	var ship = camera_controller._ship
# 	for skill_id in ship.skills.skills:
# 		var slot = Control.new()
# 		var skill = ship.skills.skills[skill_id]
# 		skills_status[skill] = slot
# 		status_indicators_container.add_child(slot)
# 		skill.init_ui(slot)

func _update_skill_indicators():
	var ship = camera_controller._ship
	for skill_id in ship.skills.skills:
		var skill = ship.skills.skills[skill_id]
		if skill not in skills_status:
			var _slot: Control
			if skill.skill_id == "ifa":
				_slot = det_incoming_fire_indicator
			elif skill.skill_id == "6_s":
				_slot = det_los_counter
			else:
				_slot = Control.new()
				_slot.custom_minimum_size = Vector2(30, 30)
				status_indicators_container.add_child(_slot)
			skills_status[skill] = _slot
			skill.init_ui(_slot)
			skill.init_hover(_slot, hover_tooltip)
		var slot = skills_status[skill]
		skill.update_ui(slot)

func _ready():
	# Add to camera_ui group for easy access
	add_to_group("camera_ui")

	# Custom hover-tooltip overlay (replaces native tooltips, which Godot
	# suppresses while Ctrl is held). Must exist before any setup_* call that
	# attaches hints to widgets.
	hover_tooltip = HoverTooltipScript.new()
	add_child(hover_tooltip)

	# # Connect weapon button signals
	# for i in range(weapon_buttons.size()):
	# 	weapon_buttons[i].connect("pressed", _on_weapon_button_pressed.bind(i))

	# Connect crosshair drawing
	crosshair_container.connect("draw", _on_crosshair_container_draw)

	# Full-viewport overlay for the aviation squadron box-select rectangle.
	# Built in code (not the .tscn) so its rect always matches the viewport
	# exactly - as a direct child of this CanvasLayer, PRESET_FULL_RECT sizes
	# it against the viewport rather than a parent Control.
	_box_select_overlay = Control.new()
	_box_select_overlay.name = "BoxSelectOverlay"
	_box_select_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_box_select_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box_select_overlay.z_index = 5
	_box_select_overlay.draw.connect(_on_box_select_overlay_draw)
	add_child(_box_select_overlay)

	# Setup hit/stat counters component
	_setup_hit_stat_counters()

	# Setup weapon UI
	setup_weapon_buttons()

	# Setup consumable buttons
	setup_consumable_ui()

	# Setup minimap in the bottom right panel with automatic anchoring
	minimap = Minimap.new()
	minimap.set_anchors_preset(Control.PRESET_TOP_LEFT)
	minimap.position = Vector2(0, 0)  # Position at top-left of the panel
	bottom_right_panel.add_child(minimap)

	# Setup sniper reticle
	_setup_sniper_reticle()

	# Hide ship UI templates (they're visible in editor for design purposes)
	ship_ui_templates.visible = false

	# Setup gun reload bars (will be called again when camera_controller is set)
	if camera_controller:
		setup_weapons.call_deferred()
		# get_tree().create_timer(1.0).timeout.connect(_set_up_skill_indicators)
		# _set_up_skill_indicators.call_deferred()

	setup_team_tracker()

	# Setup kill feed
	_setup_kill_feed()

	server = get_tree().root.get_node_or_null("Server")
	players_node = server.get_node_or_null("GameWorld/Players") if server else null

	# Connect to match end signal
	_Utils.match_ended.connect(_on_match_ended)

	# Setup options menu
	_options_menu = $OptionsMenu
	_options_menu.get_node("Panel/VBox/ResumeButton").pressed.connect(_hide_options_menu)
	_options_menu.get_node("Panel/VBox/QuitMatchButton").pressed.connect(_on_quit_match_pressed)
	var _bw_check: CheckBox = _options_menu.get_node("Panel/VBox/BorderlessWindowCheck")
	_bw_check.button_pressed = GameSettings.borderless_window
	_bw_check.toggled.connect(_on_borderless_window_toggled)

func _unhandled_input(event: InputEvent) -> void:
	if match_ended:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _options_menu and _options_menu.visible:
				_hide_options_menu()
			else:
				_show_options_menu()
			get_viewport().set_input_as_handled()

func _update_match_timer(delta: float) -> void:
	if not server:
		return

	var server_remaining: float = server.get_match_time_remaining()

	# Initialize local timer from server on first valid read
	if _local_time_remaining < 0.0:
		_local_time_remaining = server_remaining
		_last_seen_match_elapsed = server.match_elapsed
		return

	# Tick the local timer down smoothly each frame
	_local_time_remaining = maxf(_local_time_remaining - delta, 0.0)

	# Only correct drift when a new server sync RPC has arrived (match_elapsed changed).
	# Comparing every frame against a frozen server value would cause constant snapping.
	if server.match_elapsed != _last_seen_match_elapsed:
		_last_seen_match_elapsed = server.match_elapsed
		if absf(server_remaining - _local_time_remaining) > MATCH_TIMER_SYNC_THRESHOLD:
			_local_time_remaining = server_remaining

	var total_secs: int = int(_local_time_remaining)
	var mins: int = total_secs / 60
	var secs: int = total_secs % 60
	match_timer_label.text = "%02d:%02d" % [mins, secs]

	# Flash red when under 2 minutes
	if _local_time_remaining <= 120.0:
		var blink := fmod(Time.get_ticks_msec() / 500.0, 2.0) < 1.0
		match_timer_label.modulate = Color(1.0, 0.3, 0.3, 1.0) if blink else Color(1.0, 1.0, 1.0, 1.0)
	else:
		match_timer_label.modulate = Color(1.0, 1.0, 1.0, 1.0)

func _process(delta: float) -> void:
	if match_ended:
		return
	if not is_instance_valid(camera_controller):
		return
	_update_match_timer(delta)
	update_ship_ui(delta)
	update_aircraft_ui(delta)
	# _update_reticle_visibility()
	sniper_reticle.queue_redraw()

func _show_options_menu() -> void:
	if not _options_menu:
		return
	$MainContainer.visible = false
	_options_menu.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# Disable PlayerController._input so gun-firing clicks can't slip through
	# while the menu is open. GUI Button input is a separate pathway and still works.
	if player_controller:
		player_controller.set_process_input(false)

func _hide_options_menu() -> void:
	if not _options_menu:
		return
	_options_menu.visible = false
	$MainContainer.visible = true
	# Re-enable player input and restore the mouse mode PlayerController expects.
	if not player_controller:
		return
	player_controller.set_process_input(true)
	if player_controller.mouse_captured:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _on_quit_match_pressed() -> void:
	match_ended = true  # Prevent _on_match_ended from redirecting to battle_end_screen
	if server:
		server.player_quit_match.rpc_id(1)
	_disable_battle_processing()
	if camera_controller:
		if camera_controller.third_person_view:
			camera_controller.third_person_view.queue_free()
		if camera_controller.free_look_view:
			camera_controller.free_look_view.queue_free()
		if camera_controller.sniper_view:
			camera_controller.sniper_view.queue_free()
		if camera_controller.aerial_view:
			camera_controller.aerial_view.queue_free()
		camera_controller.queue_free()
	ProjectileManager.clear_all()
	(TorpedoManager as _TorpedoManager).clear_all()
	get_tree().change_scene_to_file.call_deferred("res://src/port/main_menu/main_menu.tscn")

func _on_borderless_window_toggled(pressed: bool) -> void:
	GameSettings.borderless_window = pressed
	GameSettings.apply_display_settings()
	GameSettings.save_settings()

func _setup_kill_feed():
	"""Setup the kill feed component positioned directly above the minimap."""
	kill_feed = KillFeedScene.instantiate()
	$MainContainer.add_child(kill_feed)
	# Position will be updated each frame to sit above the minimap
	_Utils.kill_feed_event.connect(_on_kill_feed_event)

func _update_kill_feed_position():
	"""Keep the kill feed anchored directly above the minimap."""
	if kill_feed == null or minimap == null:
		return
	var minimap_size: float = minimap.minimap_sizes[minimap.mm_idx]
	var margin := 10.0
	# kill_feed right edge flush with minimap right edge (screen right - margin)
	# kill_feed bottom edge flush with minimap top edge (screen bottom - margin - minimap_size - small gap)
	var vp_size := get_viewport().get_visible_rect().size
	var feed_width := minimap_size  # match minimap width
	var feed_height := 200.0  # enough room for MAX_ENTRIES
	var gap := 4.0
	kill_feed.position = Vector2(
		vp_size.x - margin - feed_width,
		vp_size.y - margin - minimap_size - gap - feed_height
	)
	kill_feed.size = Vector2(feed_width, feed_height)

func _on_kill_feed_event(sinker_name: String, sinker_player_name: String, sinker_team: int, damage_type: int, sunk_name: String, sunk_player_name: String, sunk_team: int):
	"""Handle kill feed events from the global signal"""
	if kill_feed:
		kill_feed.add_kill(sinker_name, sinker_player_name, sinker_team, damage_type, sunk_name, sunk_player_name, sunk_team, friendly_team_id)

func _on_match_ended(winning_team: int):
	"""Handle match end - snapshot the scene, stash results, change to end screen scene."""
	if match_ended:
		return
	match_ended = true

	# Disable processing on all nodes that could reference freed objects.
	# This stops the battle camera, its views, minimap, player controller,
	# and the entire game world from running _process / _physics_process
	# while the deferred scene change is pending.
	_disable_battle_processing()

	# Gather stats before the scene change frees everything
	var stats_dict := {}
	var ship_name := ""
	if camera_controller and camera_controller._ship:
		var stats: Stats = camera_controller._ship.stats
		ship_name = camera_controller._ship.ship_name if camera_controller._ship.ship_name else camera_controller._ship.name
		if stats:
			stats_dict = {
				"total_damage": stats.total_damage,
				"frags": stats.frags,
				"main_hits": stats.main_hits,
				"main_damage": stats.main_damage,
				"citadel_count": stats.citadel_count,
				"secondary_count": stats.secondary_count,
				"sec_damage": stats.sec_damage,
				"torpedo_count": stats.torpedo_count,
				"torpedo_damage": stats.torpedo_damage,
				"fire_count": stats.fire_count,
				"fire_damage": stats.fire_damage,
				"flood_count": stats.flood_count,
				"flood_damage": stats.flood_damage,
				"spotting_damage": stats.spotting_damage,
				"potential_damage": stats.potential_damage,
				"ships_damaged": stats.ships_damaged.duplicate(),
			}

	# Hide the UI before taking the snapshot so we get a clean 3D scene
	visible = false

	# Wait one frame for the rendering to update without the UI
	await RenderingServer.frame_post_draw

	# Take a snapshot of the current viewport (the 3D scene as the player sees it)
	var screenshot: Image = get_viewport().get_texture().get_image()

	# Stash everything on the autoload so it survives the scene change.
	# Preserve any data already set by the RPC (e.g. leaderboard).
	_Utils.match_result["winning_team"] = winning_team
	_Utils.match_result["friendly_team_id"] = friendly_team_id
	_Utils.match_result["ship_name"] = ship_name
	_Utils.match_result["stats"] = stats_dict
	_Utils.match_result["screenshot"] = screenshot
	# Clear projectile and torpedo managers so in-flight shells/torps don't
	# hit freed ships during the scene transition
	ProjectileManager.clear_all()
	(TorpedoManager as _TorpedoManager).clear_all()

	# Free the battle camera and its views — they live directly under root,
	# not under the current scene, so change_scene_to_file won't touch them.
	if camera_controller:
		if camera_controller.third_person_view:
			camera_controller.third_person_view.queue_free()
		if camera_controller.free_look_view:
			camera_controller.free_look_view.queue_free()
		if camera_controller.sniper_view:
			camera_controller.sniper_view.queue_free()
		if camera_controller.aerial_view:
			camera_controller.aerial_view.queue_free()
		camera_controller.queue_free()

	# Defer the scene change so it executes after the current frame completes.
	# All battle nodes have had their processing disabled above, so nothing
	# will touch freed objects between now and the scene swap.
	get_tree().change_scene_to_file.call_deferred("res://src/ui/battle_end_screen.tscn")

func _setup_hit_stat_counters():
	"""Setup the hit/stat counters component"""
	hit_stat_counters = HitStatCountersScene.instantiate()
	# Inject the shared HoverTooltip overlay BEFORE adding to the tree so the
	# counters' _ready() can wire its drill-down panels through it. Skips the
	# old per-physics-tick hover polling that broke while Ctrl was held.
	hit_stat_counters.hover_tooltip = hover_tooltip
	$MainContainer.add_child(hit_stat_counters)
	hit_stat_counters.floating_damage_requested.connect(_on_floating_damage_requested)

func _on_floating_damage_requested(damage: float, position: Vector3):
	"""Handle floating damage requests from hit stat counters"""
	create_floating_damage(damage, position)


func _disable_battle_processing():
	"""Disable _process and _physics_process on all battle-related nodes
	so nothing references freed objects during the deferred scene change."""
	# Battle camera and its views (added as siblings under root)
	if camera_controller:
		_disable_node(camera_controller)
		if camera_controller.third_person_view:
			_disable_node(camera_controller.third_person_view)
		if camera_controller.free_look_view:
			_disable_node(camera_controller.free_look_view)
		if camera_controller.sniper_view:
			_disable_node(camera_controller.sniper_view)
		if camera_controller.aerial_view:
			_disable_node(camera_controller.aerial_view)

	# Player controller
	if player_controller:
		_disable_node(player_controller)

	# Minimap
	if minimap:
		_disable_node(minimap)

	# Game world (contains all ships, their physics, bot controllers, etc.)
	var game_world = server.get_node_or_null("GameWorld") if server else null
	if game_world:
		_disable_node(game_world)

	# This node itself
	set_process(false)
	set_physics_process(false)

func _disable_node(node: Node) -> void:
	"""Recursively disable processing on a node and all its children."""
	node.set_process(false)
	node.set_physics_process(false)
	for child in node.get_children():
		_disable_node(child)

func _physics_process(_delta):
	if match_ended:
		return

	# Flush accumulated floating damage when window expires
	if _damage_accum_active:
		_damage_accum_timer -= _delta
		if _damage_accum_timer <= 0.0:
			_flush_damage_accumulator()

	# Flush accumulated damage-received when window expires
	if _recv_damage_accum_active:
		_recv_damage_accum_timer -= _delta
		if _recv_damage_accum_timer <= 0.0:
			_flush_recv_damage_accumulator()

	var t = Time.get_ticks_usec() / 1000000.0
	if not camera_controller:
		return

	_update_ui()
	_update_fps()
	_update_camera_angle_display()
	_update_kill_feed_position()
	update_team_tracker()  # Update team tracker
	# cleanup_team_indicators()  # Clean up invalid indicators
	update_gun_reload_bars()
	update_fire_bars()
	update_flood_bars()
	update_visibility_indicator()  # Update visibility indicator
	update_secondaries_disabled_indicator()  # Update secondaries disabled indicator
	update_consumable_ui()
	_update_skill_indicators()
	# update_ship_ui()
	# _update_reticle_visibility()


	# Automatically detect current secondary target from ship's secondary controllers
	if camera_controller._ship and camera_controller._ship.secondary_controller:
		var detected_target = camera_controller._ship.secondary_controller.target

		# Update the target if it has changed
		if detected_target != current_secondary_target:
			current_secondary_target = detected_target

	# Update hit stat counters with ship stats
	if camera_controller and camera_controller._ship and camera_controller._ship.stats:
		var stats = camera_controller._ship.stats
		if hit_stat_counters:
			hit_stat_counters.set_stats(stats)

	if camera_controller._ship:
		var hp_cont = camera_controller._ship.health_controller
		var hp = hp_cont.current_hp
		if hp != current_hp:
			var damage_taken = (current_hp - hp)
			if damage_taken > 0.0:
				# Accumulate damage-received floating indicator
				if not _recv_damage_accum_active:
					_recv_damage_accum_active = true
					_recv_damage_accum_amount = damage_taken
					_recv_damage_accum_timer = DAMAGE_ACCUM_WINDOW
				else:
					_recv_damage_accum_amount += damage_taken
			current_hp = hp

	crosshair_container.queue_redraw()
	t = Time.get_ticks_usec() / 1000000.0 - t
	# print("Camera UI _physics_process time: %.3f ms" % [t * 1000.0])

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

		# Initialize hit stat counters with ship stats
		if hit_stat_counters and camera_controller._ship.stats:
			hit_stat_counters.set_stats(camera_controller._ship.stats)

func update_visibility_indicator():
	if not camera_controller or not camera_controller._ship:
		det_los_indicator.visible = false
		det_hydro_indicator.visible = false
		det_radar_indicator.visible = false
		det_air_indicator.visible = false
		return

	var ship := camera_controller._ship
	det_los_indicator.visible   = ship.det_los
	det_hydro_indicator.visible = ship.det_hydro
	det_radar_indicator.visible = ship.det_radar
	det_air_indicator.visible   = ship.det_air

func update_terrain_hit_indicator(is_hitting_terrain: bool):
	"""Show or hide the terrain hit indicator"""
	terrain_hit_indicator.visible = is_hitting_terrain

func update_secondaries_disabled_indicator():
	"""Show or hide the secondaries disabled indicator"""
	if not camera_controller or not camera_controller._ship:
		secondaries_disabled.visible = false
		return

	var secondaries_disabled_flag = not camera_controller._ship.secondary_controller.enabled
	secondaries_disabled.visible = secondaries_disabled_flag




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
		# var current_hp = camera_controller._ship.health_controller.current_hp
		var max_hp = camera_controller._ship.health_controller.max_hp
		var hp_percent = (float(current_hp) / max_hp) * 100.0

		hp_bar.value = hp_percent
		hp_label.text = "%d / %d" % [current_hp, max_hp]
		var heal_in_progress = camera_controller._ship.consumable_manager.is_using(ConsumableItem.ConsumableType.REPAIR_PARTY)

		if not heal_in_progress and camera_controller._ship.consumable_manager.get_item_count(ConsumableItem.ConsumableType.REPAIR_PARTY) == 0 or camera_controller._ship.health_controller.is_dead():
			# No repair parties available - show healable damage as white extension of current HP bar
			healable_hp_bar.value = hp_percent
			healable_pulse_active = false
		else:
			# Update healable HP bar (shows current HP + healable damage as white region)
			var healable_damage = camera_controller._ship.health_controller.healable_damage
			if healable_damage == null:
				healable_damage = 0.0

			# Get repair party heal amount to cap the healable bar
			var repair_party_heal_amount = _get_repair_party_heal_amount()
			var capped_healable = min(healable_damage, repair_party_heal_amount) if repair_party_heal_amount > 0 else healable_damage
			if heal_in_progress:
				capped_healable = min(capped_healable, (1.0 - camera_controller._ship.consumable_manager.get_active_consumable_progress(ConsumableItem.ConsumableType.REPAIR_PARTY)) * repair_party_heal_amount)
			if capped_healable > 0:
				var healable_percent = (float(current_hp + capped_healable) / max_hp) * 100.0
				healable_hp_bar.value = min(healable_percent, 100.0)

				# Check if healable damage meets or exceeds repair party amount - activate pulse
				if repair_party_heal_amount > 0 and healable_damage >= repair_party_heal_amount and not heal_in_progress:
					healable_pulse_active = true
				else:
					healable_pulse_active = false
			else:
				healable_hp_bar.value = hp_percent
				healable_pulse_active = false

			# Apply pulse animation to healable bar
			if healable_pulse_active:
				var pulse_value = (sin(Time.get_ticks_msec() / 1000.0 * 8.0) + 1.0) / 2.0  # 0 to 1
				# Pulse between white and light green
				var pulse_color = Color(0.9, 0.9, 0.9, 0.8).lerp(Color(0.6, 1.0, 0.6, 0.9), pulse_value)
				healable_hp_bar.modulate = pulse_color
			else:
				if heal_in_progress:
					healable_hp_bar.modulate = Color(0.5, 1.0, 0.5, 0.9)  # Light green while healing
				else:
					healable_hp_bar.modulate = Color(1.0, 1.0, 1.0, 1.0)

		# Change HP bar color based on health level
		if hp_percent > 75:
			hp_bar.modulate = Color(0.2, 0.9, 0.2) # Green
		elif hp_percent > 50:
			hp_bar.modulate = Color(1.0, 1.0, 0.2) # Yellow
		elif hp_percent > 25:
			hp_bar.modulate = Color(1.0, 0.6, 0.2) # Orange
		else:
			hp_bar.modulate = Color(0.9, 0.2, 0.2) # Red

func _get_repair_party_heal_amount() -> float:
	if not camera_controller or not camera_controller._ship:
		return 0.0

	var consumable_manager = camera_controller._ship.consumable_manager
	if not consumable_manager:
		return 0.0

	# Find the repair party consumable
	for item in consumable_manager.equipped_consumables:
		if item is RepairParty:
			var max_hp = camera_controller._ship.health_controller.max_hp
			return max_hp * item.p().heal_per_sec * item.p().duration

	return 0.0

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
	pass  # lock-on indicator is now shown as a world-space icon above the ship UI

func update_box_select(rect: Rect2) -> void:
	_box_select_rect = rect
	_box_select_visible = true
	_box_select_overlay.queue_redraw()

func hide_box_select() -> void:
	if _box_select_visible:
		_box_select_visible = false
		_box_select_overlay.queue_redraw()

func _on_box_select_overlay_draw() -> void:
	if not _box_select_visible:
		return
	_box_select_overlay.draw_rect(_box_select_rect, Color(0.4, 0.9, 1.0, 0.15), true)
	_box_select_overlay.draw_rect(_box_select_rect, Color(0.4, 0.9, 1.0, 0.9), false, 1.5)

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
	var ship_damage_bar: ProgressBar
	var ship_hp_label: Label
	var target_indicator: ColorRect
	var status_indicator: HBoxContainer

	if is_enemy:
		name_label = ship_container.get_node("EnemyNameLabel")
		ship_hp_bar = ship_container.get_node("EnemyHPBar")
		ship_damage_bar = ship_container.get_node("EnemyDamageBar")
		ship_hp_label = ship_hp_bar.get_node("EnemyHPLabel")
		target_indicator = ship_container.get_node("EnemyTargetIndicator")

	else:
		name_label = ship_container.get_node("FriendlyNameLabel")
		ship_hp_bar = ship_container.get_node("FriendlyHPBar")
		ship_damage_bar = ship_container.get_node("FriendlyDamageBar")
		ship_hp_label = ship_hp_bar.get_node("FriendlyHPLabel")
		target_indicator = ship_container.get_node("FriendlyTargetIndicator")
		status_indicator = ship_container.get_node("FriendlyStatus")
		status_indicator.get_child(0).queue_free()

	# Pre-build consumable status widgets once at registration so update_ship_ui
	# only needs to toggle .visible and write label text — never add/remove nodes.
	var normal_icons: Array = []
	var alt_widgets: Array = []
	var alt_refs: Array = []
	if not is_enemy and ship.consumable_manager:
		for item in ship.consumable_manager.equipped_consumables:
			# Normal mode: one icon per consumable inside a dark background panel,
			# shown only while the effect is active
			var icon_panel := PanelContainer.new()
			var panel_style := StyleBoxFlat.new()
			panel_style.bg_color = Color(0.05, 0.05, 0.05, 0.62)
			panel_style.corner_radius_top_left = 3
			panel_style.corner_radius_top_right = 3
			panel_style.corner_radius_bottom_left = 3
			panel_style.corner_radius_bottom_right = 3
			panel_style.content_margin_left = 3.0
			panel_style.content_margin_right = 3.0
			panel_style.content_margin_top = 2.0
			panel_style.content_margin_bottom = 2.0
			icon_panel.add_theme_stylebox_override("panel", panel_style)
			var icon_rect := TextureRect.new()
			icon_rect.texture = item.icon
			icon_rect.custom_minimum_size = Vector2(18, 18)
			icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon_panel.add_child(icon_rect)
			icon_panel.visible = false
			status_indicator.add_child(icon_panel)
			normal_icons.append(icon_panel)

			# Alt mode: full count+timer widget, shown when ALT is held
			var widget := _create_alt_consumable_widget(item, ship.consumable_manager)
			widget.visible = false
			status_indicator.add_child(widget)
			alt_widgets.append(widget)

			# Cache the three inner nodes so updates never call get_node()
			alt_refs.append({
				"icon":  widget.get_node("Box/Icon")        as TextureRect,
				"count": widget.get_node("Box/CountLabel") as Label,
				"timer": widget.get_node("Box/TimerLabel") as Label,
			})
		status_indicator.set_meta("consumable_mode", "normal")

	# Set the ship name
	name_label.text = ship.name
	ship_hp_label.text = "%d/%d" % [ship.health_controller.current_hp, ship.health_controller.max_hp]

	# Lock-on icon — shown above the ship container when this ship is the locked target
	var lock_icon := Label.new()
	lock_icon.text = "◎"
	lock_icon.add_theme_color_override("font_color", Color.WHITE)
	lock_icon.add_theme_font_size_override("font_size", 42)
	lock_icon.position = Vector2(22, -50)  # centered above the 90px-wide container
	lock_icon.visible = false
	ship_container.add_child(lock_icon)

	# Store the UI elements for this ship
	var start_hp: float = ship.health_controller.current_hp
	ship_ui_elements[ship] = {
		"container": ship_container,
		"name_label": name_label,
		"hp_bar": ship_hp_bar,
		"damage_bar": ship_damage_bar,
		"hp_label": ship_hp_label,
		"target_indicator": target_indicator,
		"status": status_indicator,
		"normal_icons": normal_icons,
		"alt_widgets": alt_widgets,
		"alt_refs": alt_refs,
		"lock_icon": lock_icon,
		# Damage-bar tracking. dmg_prev_hp = HP seen last frame. dmg_segments is a
		# queue of {hp, expire} entries keyed on the pre-damage HP. The first hit
		# opens a segment with a fixed 1s window; further damage inside that window
		# folds in (keeping the original, highest pre-damage HP). When the window
		# ends the segment is popped and the bar lerps down to the next segment
		# (or current HP). Sustained DOT therefore becomes a staircase of 1s
		# segments rather than one segment that never expires.
		"dmg_prev_hp": start_hp,
		"dmg_segments": [],
	}

func update_ship_ui(delta: float = 0.0):
	# Tick status-refresh throttle (shared across all ships per frame)
	_status_refresh_timer -= delta
	var should_refresh_status: bool = _status_refresh_timer <= 0.0
	if should_refresh_status:
		_status_refresh_timer = STATUS_REFRESH_INTERVAL

	# Periodically search for new ships
	# var current_time = Time.get_ticks_msec() / 1000.0
	# var should_search = tracked_ships.is_empty() or (current_time - last_ship_search_time > ship_search_interval)
	if num_players != players_node.get_child_count() or tracked_ships.size() < players_node.get_child_count():
		for ship in players_node.get_children():
			if ship != camera_controller._ship and ship is Ship and not tracked_ships.has(ship):
				tracked_ships[ship] = true
				setup_ship_ui(ship)
				minimap.register_ship(ship)
				print("Registered ship for UI and minimap: ", ship.name, " at position: ", ship.global_position)

	# Update each ship's UI
	var secondary_offset = camera_controller._ship.secondary_controller.target_offset if camera_controller._ship and camera_controller._ship.secondary_controller else Vector3.ZERO
	for ship: Ship in tracked_ships.keys():
		if is_instance_valid(ship) and ship in ship_ui_elements:
			var ui = ship_ui_elements[ship]

			# Get ship's HP if it has an HP manager
			var ship_hp_manager = ship.health_controller
			if ship_hp_manager:
				var ship_current_hp = ship_hp_manager.current_hp
				var max_hp = ship_hp_manager.max_hp
				# if teams_hp.has(ship) and (teams_hp[ship][0] != ship_current_hp or teams_hp[ship][1] != max_hp):
				var hp_percent = (float(ship_current_hp) / max_hp) * 100.0

				# Update progress bar and label (colors are already set by template)
				ui.hp_bar.value = hp_percent
				ui.hp_label.text = "%d/%d" % [ship_current_hp, max_hp]

				# --- "recently lost HP" damage bar -----------------------------------
				# Sits behind the HP fill, showing the gap between the current HP and
				# the HP from up to DAMAGE_BAR_CLEAR_DELAY ago. Each damage tick is its
				# own expiring segment, so the strip trails down as old damage ages out.
				var now: float = Time.get_ticks_msec() / 1000.0
				var prev_hp: float = ui["dmg_prev_hp"]
				var segments: Array = ui["dmg_segments"]

				# On HP loss, fold into the active segment while it is still inside its
				# fixed 1s window (keeping its original, highest pre-damage HP and its
				# expiry); once that window has closed, open a new segment. Because the
				# window is anchored to the first hit (not extended per hit), continuous
				# DOT no longer keeps a single segment alive forever.
				if ship_current_hp < prev_hp:
					if segments.is_empty() or now >= segments[-1]["expire"]:
						segments.append({"hp": prev_hp, "expire": now + DAMAGE_BAR_CLEAR_DELAY})
					# else: within the active window — fold (no new segment)
				ui["dmg_prev_hp"] = ship_current_hp

				# Drop expired segments from the front; the bar steps down to the next.
				while not segments.is_empty() and segments[0]["expire"] <= now:
					segments.pop_front()

				# Healed at/above the displayed damage level: the recent-damage region
				# no longer applies, so clear everything.
				if not segments.is_empty() and ship_current_hp >= segments[0]["hp"]:
					segments.clear()

				if ui.has("damage_bar") and is_instance_valid(ui["damage_bar"]):
					var bar: ProgressBar = ui["damage_bar"]
					var dmg_level: float = segments[0]["hp"] if not segments.is_empty() else ship_current_hp
					var target: float = (dmg_level / max_hp) * 100.0
					if target >= bar.value:
						# Damage region grew (or first hit): snap up instantly.
						bar.value = target
					else:
						# Stepping down to the next level: drain smoothly in _process.
						bar.value = max(target, bar.value - DAMAGE_BAR_DROP_RATE * delta)

			if ship.team.team_id == camera_controller._ship.team.team_id: # friendly
				var alt_held: bool = Input.is_key_pressed(KEY_ALT)
				var desired_mode: String = "alt" if alt_held else "normal"
				var current_mode: String = ui.status.get_meta("consumable_mode", "")
				var normal_icons: Array = ui["normal_icons"]
				var alt_widgets: Array = ui["alt_widgets"]
				var alt_refs: Array  = ui["alt_refs"]
				var consumables      = ship.consumable_manager.equipped_consumables

				# --- Mode switch: flip which widget set is visible, update container height ---
				if current_mode != desired_mode:
					ui.status.set_meta("consumable_mode", desired_mode)
					if desired_mode == "alt":
						ui.status.offset_top    = -52.0
						ui.status.offset_bottom = -2.0
						for icon in normal_icons:
							icon.visible = false
						for widget in alt_widgets:
							widget.visible = true
					else:
						ui.status.offset_top    = -22.0
						ui.status.offset_bottom = -2.0
						for widget in alt_widgets:
							widget.visible = false

				# --- Normal mode: sync icon visibility every frame (trivially cheap) ---
				if desired_mode == "normal":
					for i in range(normal_icons.size()):
						var item: ConsumableItem = consumables[i] if i < consumables.size() else null
						normal_icons[i].visible = item != null and ship.consumable_manager.active_effects.has(item.id)

				# --- Alt mode: update labels at STATUS_REFRESH_INTERVAL to avoid per-frame theme override spam ---
				elif should_refresh_status:
					for i in range(alt_refs.size()):
						if i < consumables.size():
							_update_alt_consumable_widget_refs(alt_refs[i], consumables[i], ship.consumable_manager)



			if ship.team.team_id != camera_controller._ship.team.team_id:
				# Update target indicator visibility
				var is_targeted = (ship == current_secondary_target)
				if ui.target_indicator.visible != is_targeted:
					ui.target_indicator.visible = is_targeted
				ui.target_indicator.get_child(0).text = "◉" if secondary_offset == Vector3.ZERO else "◎+"

			# # Add pulsing animation to target indicator if targeted
			# if is_targeted:
			# 	var pulse_value = (sin(Time.get_ticks_msec() / 1000.0 * 4.0) + 1.0) / 2.0  # Oscillates between 0 and 1
			# 	var base_color = Color(1, 0.6, 0, 0.9)  # Orange color
			# 	ui.target_indicator.color = base_color.lerp(Color(1, 1, 0, 1), pulse_value * 0.5)  # Pulse to yellow

			# Position UI above ship in the world
			var ship_position = ship.global_position + Vector3(0, 20, 0) # Add height offset
			var screen_pos = Vector2.ZERO
			if not camera_controller.is_position_behind(ship_position):
				screen_pos = get_viewport().get_camera_3d().unproject_position(ship_position)

			# Check if ship is visible on screen
			var ship_visible = is_position_visible_on_screen(ship_position) and ship.visible
			ui.container.visible = ship_visible && (ship as Ship).health_controller.is_alive()
			if not ship_visible:
				ui.lock_icon.visible = false

			if ship_visible:
				# Position the container above the ship, centered
				var container_size = Vector2(90, 40) # Use template size
				ui.container.position = screen_pos - Vector2(container_size.x / 2, container_size.y)
				# Show lock-on icon when this ship is the active locked target
				ui.lock_icon.visible = target_lock_enabled and locked_target == ship
		else:
			# Ship no longer valid, remove it
			if ship in ship_ui_elements:
				for element in ship_ui_elements[ship].values():
					if is_instance_valid(element):
						element.queue_free()
				ship_ui_elements.erase(ship)
			tracked_ships.erase(ship)

func setup_aircraft_ui(plane: Node3D, owner_ship: Ship, params: AircraftParams) -> void:
	var color: Color
	if owner_ship == camera_controller._ship:
		color = Color(1.0, 1.0, 1.0)
	elif camera_controller._ship.team and owner_ship.team \
			and camera_controller._ship.team.team_id == owner_ship.team.team_id:
		color = Color(0.0, 1.0, 0.0)
	else:
		color = Color(1.0, 0.0, 0.0)

	var container := VBoxContainer.new()
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.visible = false

	var icon_label := Label.new()
	icon_label.text = "\u2708 %s" % params.type
	icon_label.add_theme_font_size_override("font_size", 12)
	icon_label.add_theme_color_override("font_color", color)
	icon_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	icon_label.add_theme_constant_override("shadow_offset_x", 1)
	icon_label.add_theme_constant_override("shadow_offset_y", 1)
	container.add_child(icon_label)

	var owner_label := Label.new()
	owner_label.text = owner_ship.name
	owner_label.add_theme_font_size_override("font_size", 10)
	owner_label.add_theme_color_override("font_color", Color(color.r, color.g, color.b, 0.7))
	owner_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	owner_label.add_theme_constant_override("shadow_offset_x", 1)
	owner_label.add_theme_constant_override("shadow_offset_y", 1)
	container.add_child(owner_label)

	add_child(container)

	aircraft_ui_elements[plane] = {
		"container": container,
		"icon_label": icon_label,
		"owner_label": owner_label,
	}


func update_aircraft_ui(_delta: float) -> void:
	if not camera_controller or not camera_controller._ship:
		return
	if not players_node:
		return

	# Collect all currently active planes across every ship
	var active_planes: Dictionary = {}  # plane Node3D -> {owner_ship, params}
	for ship in players_node.get_children():
		if not (ship is Ship) or not ship.aviation_controller:
			continue
		var av: AviationController = ship.aviation_controller
		for squadron_idx in av.active_squadrons.keys():
			if squadron_idx < av.squadrons.size() and squadron_idx < av.params.size():
				for plane in av.squadrons[squadron_idx].aircraft:
					if is_instance_valid(plane) and plane.visible:
						active_planes[plane] = {"owner_ship": ship, "params": av.params[squadron_idx]}

	# Remove markers for planes that are no longer active
	var to_remove: Array = []
	for plane in aircraft_ui_elements.keys():
		if not active_planes.has(plane):
			to_remove.append(plane)
	for plane in to_remove:
		aircraft_ui_elements[plane]["container"].queue_free()
		aircraft_ui_elements.erase(plane)

	# Create markers for new planes; position all active markers
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return
	for plane in active_planes.keys():
		if not aircraft_ui_elements.has(plane):
			var info = active_planes[plane]
			setup_aircraft_ui(plane, info["owner_ship"], info["params"])

		var ui = aircraft_ui_elements[plane]
		var world_pos: Vector3 = plane.global_position + Vector3(0, 8, 0)
		var on_screen: bool = is_position_visible_on_screen(world_pos)
		var container: Control = ui["container"]
		container.visible = on_screen
		if on_screen:
			var screen_pos: Vector2 = camera.unproject_position(world_pos)
			container.position = screen_pos - Vector2(container.size.x * 0.5, container.size.y)


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

func setup_team_tracker():
	"""Initial setup for the team tracker UI"""

	if not camera_controller or not camera_controller._ship:
		setup_team_tracker.call_deferred()
		return

	# var server: GameServer = get_tree().root.get_node_or_null("Server")
	if not server:
		setup_team_tracker.call_deferred()
		return

	var friendly_ships = server._get_team_ships(camera_controller._ship.team.team_id)
	var enemy_ships = server._get_enemy_ships(camera_controller._ship.team.team_id)

	update_team_container(friendly_ships_container, friendly_ships, true)
	update_team_container(enemy_ships_container, enemy_ships, false)
	# Resize the team tracker panel to fit content
	resize_team_tracker_panel(friendly_ships.size(), enemy_ships.size())

	num_players = friendly_ships.size() + enemy_ships.size()


func update_team_tracker():
	"""Update the team tracker with current ship status"""
	if not camera_controller or not camera_controller._ship:
		return

	# Set friendly team ID if not already set
	if friendly_team_id == -1 and camera_controller._ship.team:
		friendly_team_id = camera_controller._ship.team.team_id

	# Get server reference
	# var server: GameServer = get_tree().root.get_node_or_null("Server")
	if not server:
		return

	# Get all ships from server (including dead ones)
	var friendly_ships = server._get_team_ships(friendly_team_id)
	var enemy_ships = server._get_enemy_ships(friendly_team_id)
	#print("Friendly ships count: ", friendly_ships.size(), " | Enemy ships count: ", enemy_ships.size())

	if num_players != friendly_ships.size() + enemy_ships.size():
		num_players = friendly_ships.size() + enemy_ships.size()
		# print("Total players updated: ", num_players)
		# Update friendly ships display
		update_team_container(friendly_ships_container, friendly_ships, true)

		# Update enemy ships display
		update_team_container(enemy_ships_container, enemy_ships, false)

		# Resize the team tracker panel to fit content
		resize_team_tracker_panel(friendly_ships.size(), enemy_ships.size())
		return
	update_team_container2(friendly_ships_container, friendly_ships, true)
	update_team_container2(enemy_ships_container, enemy_ships, false)

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

func update_team_container2(container: HBoxContainer, ships: Array, is_friendly: bool):
	"""Update a team container with ship indicators using templates"""

	for ship in ships:
		if not is_instance_valid(ship):
			continue

		if teams_hp.has(ship):
			if ship.health_controller.current_hp != teams_hp[ship][0] or ship.health_controller.max_hp != teams_hp[ship][1]:
				var prev_hp	= teams_hp[ship][0]
				teams_hp[ship] = [ship.health_controller.current_hp, ship.health_controller.max_hp]
				update_team_indicator(team_ship_indicators[ship], ship, is_friendly, prev_hp > 0 and ship.health_controller.current_hp <= 0)
		else:
			teams_hp[ship] = [ship.health_controller.current_hp, ship.health_controller.max_hp]
			update_team_indicator(team_ship_indicators[ship], ship, is_friendly, true)


func update_team_indicator(indicator: Control, ship: Ship, is_friendly: bool, update_color: bool=false):
	"""Update the appearance of a team indicator based on ship status (replay HUD style:
	colour-coded name label above a thin HP bar tinted via modulate)."""
	var hp_indicator: ProgressBar = indicator.get_node("HPIndicator")
	var ship_name: Label = indicator.get_node("ShipName")

	if ship.short_name != "":
		ship_name.text = ship.short_name
	else:
		ship_name.text = ship.ship_name
	# Check if ship is alive
	var is_alive = ship.health_controller and ship.health_controller.is_alive()
	var health_percent = 1.0

	if ship.health_controller:
		health_percent = float(ship.health_controller.current_hp) / ship.health_controller.max_hp
		hp_indicator.value = health_percent * 100.0

	if update_color:
		if is_alive:
			if is_friendly:
				ship_name.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
				hp_indicator.modulate = Color(0.4, 1.0, 0.4)
			else:
				ship_name.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
				hp_indicator.modulate = Color(1.0, 0.4, 0.4)
		else:
			# Ship is dead - dim everything to gray
			ship_name.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			hp_indicator.modulate = Color(0.3, 0.3, 0.3)
			hp_indicator.value = 0.0

func resize_team_tracker_panel(friendly_count: int, enemy_count: int):
	"""Resize the team tracker panel to fit all ships"""
	if not top_center_panel:
		return

	# Calculate required width:
	# - Each ship indicator: 60px wide (matches the TeamTrackerTemplate / HP bar)
	# - Spacing between indicators: 5px (handled by HBoxContainer)
	# - VSeparator: ~20px
	# - Padding: 20px container insets + 12px panel content margins
	# - Minimum width: 200px

	var friendly_width = friendly_count * (60 + 5)  # 60px + 5px spacing per ship
	var enemy_width = enemy_count * (60 + 5)
	var separator_width = 20
	var padding = 32
	var min_width = 200

	var total_width = max(min_width, friendly_width + enemy_width + separator_width + padding)

	# Update the panel size (height is now 50px to accommodate HP bars)
	var half_width = total_width / 2
	top_center_panel.offset_left = -half_width
	top_center_panel.offset_right = half_width
	# top_center_panel.offset_bottom = 60  # Increased height for HP bars
	# top_center_panel.size.x = friendly_ships_container.size.x + enemy_ships_container.size.x + 20

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

func setup_weapon_controller(controller: Node):
	if weapons.has(controller):
		for weapon: Weapon in weapons[controller]:
			if is_instance_valid(weapon):
				weapon.indicator.queue_free()
				weapon.reload_bar.queue_free()
		weapons.erase(controller)

	if not weapons.has(controller):
		weapons[controller] = []
	var weapons_container = gun_reload_container.get_parent() as Control
	var gun_container = gun_reload_container.duplicate()
	gun_container.visible = true
	var weaps = controller.weapons
	var size = weaps.size()
	for i in range(size):
		var turret: Turret = weaps[i]
		var weapon_data = Weapon.new()
		weapon_data.weapon = turret
		weapon_data.indicator = GunIndicatorScene.instantiate()
		weapon_data.reload_bar = reload_bar_template.duplicate()
		weapon_data.indicator.visible = true
		weapon_data.reload_bar.visible = true
		var width = min(380 / size, 100)
		if width < 30:
			weapon_data.reload_bar.get_child(0).visible = false
		(weapon_data.reload_bar as Control).custom_minimum_size.x = width
		(weapon_data.reload_bar as Control).size.x = width

		weapons[controller].append(weapon_data)
		crosshair_container.add_child(weapon_data.indicator)
		gun_container.add_child(weapon_data.reload_bar)
	weapons_container.add_child(gun_container)
	weapons_container.move_child(gun_container, 0)

# Gun reload bar management
func setup_weapons():
	reload_bar_template.visible = false
	gun_indicator.visible = false
	gun_reload_container.visible = false

	setup_weapon_controller(camera_controller._ship.artillery_controller)
	if camera_controller._ship.secondary_controller.weapons.size() > 0:
		setup_weapon_controller(camera_controller._ship.secondary_controller)
	if camera_controller._ship.torpedo_controller:
		setup_weapon_controller(camera_controller._ship.torpedo_controller)

	if camera_controller._ship.torpedo_controller != null:
		# Setup torpedo overlay
		torpedo_overlay = TorpedoOverlayScene.instantiate()
		torpedo_overlay.torpedo_controller = camera_controller._ship.torpedo_controller
		torpedo_overlay.player_controller = player_controller
		add_child(torpedo_overlay)

	setup_fire_bars()
	setup_flood_bars()

func _make_fire_spacer() -> Control:
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spacer

func setup_fire_bars():
	await get_tree().process_frame
	fire_bar_template.visible = false
	for c in fire_bar_container.get_children():
		if c != fire_bar_template:
			c.queue_free()
	fire_bars.clear()

	var fires = camera_controller._ship.fire_manager.fires
	# Even spread with gaps on both ends: spacer, bar, spacer, bar, ..., spacer
	fire_bar_container.add_child(_make_fire_spacer())
	for i in fires.size():
		var bar: ProgressBar = fire_bar_template.duplicate()
		bar.visible = true
		bar.modulate.a = 0.0
		bar.value = 0.0
		bar.add_theme_stylebox_override("fill", fire_bar_template.get_theme_stylebox("fill").duplicate())
		fire_bar_container.add_child(bar)
		fire_bars.append(bar)
		fire_bar_container.add_child(_make_fire_spacer())

func update_fire_bars():
	if fire_bars.is_empty():
		return
	var fires = camera_controller._ship.fire_manager.fires
	for i in fire_bars.size():
		if i >= fires.size():
			break
		var fire: Fire = fires[i]
		var bar: ProgressBar = fire_bars[i]
		var label: Label = bar.get_child(0) as Label
		var fill := bar.get_theme_stylebox("fill") as StyleBoxFlat
		if fire.lifetime > 0.0:
			bar.modulate.a = 1.0
			bar.value = fire.lifetime
			fill.bg_color = fire_burning_color
			label.text = "%.0f" % (fire.lifetime * fire._params.dur)
			label.visible = true
		elif fire.curr_buildup > 0.0:
			bar.modulate.a = 1.0
			var max_buildup: float = fire._rparams.max_buildup
			var buildup_frac: float = clamp(fire.curr_buildup / max_buildup, 0.0, 1.0)
			bar.value = buildup_frac
			fill.bg_color = fire_buildup_color
			if Input.is_key_pressed(KEY_ALT):
				label.text = "%.0f%%" % (buildup_frac * 100.0)
				label.visible = true
			else:
				label.visible = false
		else:
			bar.modulate.a = 0.0

func setup_flood_bars():
	await get_tree().process_frame
	flood_bar_template.visible = false
	for c in flood_bar_container.get_children():
		if c != flood_bar_template:
			c.queue_free()
	flood_bars.clear()

	var floods = camera_controller._ship.flood_manager.floods
	flood_bar_container.add_child(_make_fire_spacer())
	for i in floods.size():
		var bar: ProgressBar = flood_bar_template.duplicate()
		bar.visible = true
		bar.modulate.a = 0.0
		bar.value = 0.0
		bar.add_theme_stylebox_override("fill", flood_bar_template.get_theme_stylebox("fill").duplicate())
		flood_bar_container.add_child(bar)
		flood_bars.append(bar)
		flood_bar_container.add_child(_make_fire_spacer())

func update_flood_bars():
	if flood_bars.is_empty():
		return
	var floods = camera_controller._ship.flood_manager.floods
	for i in flood_bars.size():
		if i >= floods.size():
			break
		var flood: Flood = floods[i]
		var bar: ProgressBar = flood_bars[i]
		var label: Label = bar.get_child(0) as Label
		var fill := bar.get_theme_stylebox("fill") as StyleBoxFlat
		if flood.lifetime > 0.0:
			bar.modulate.a = 1.0
			bar.value = flood.lifetime
			fill.bg_color = flood_active_color
			label.text = "%.0f" % (flood.lifetime * flood._params.dur)
			label.visible = true
		elif flood.curr_buildup > 0.0:
			bar.modulate.a = 1.0
			var max_buildup: float = flood._rparams.max_buildup
			var buildup_frac: float = clamp(flood.curr_buildup / max_buildup, 0.0, 1.0)
			bar.value = buildup_frac
			fill.bg_color = flood_buildup_color
			if Input.is_key_pressed(KEY_ALT):
				label.text = "%.0f%%" % (buildup_frac * 100.0)
				label.visible = true
			else:
				label.visible = false
		else:
			bar.modulate.a = 0.0

func update_gun_reload_bars():
	# Update reload progress for each weapon
	var already_drawn_indicators = []
	var overlapping_indicators = {}

	for controller in weapons.keys():
		var turret_list = weapons[controller]
		for t in turret_list:
			var gun: Turret = t.weapon
			var params = gun.controller.get_params()
			var bar = t.reload_bar
			var indicator = t.indicator
			var timer_label = bar.get_child(0) as Label


			# Update reload progress
			bar.value = gun.reload
			var under_tex = indicator.get_node("UnderTexture") as TextureProgressBar
			var progress_tex = indicator.get_node("ProgressTexture") as TextureProgressBar
			progress_tex.value = gun.reload
			if gun.reload >= 1.0:
				timer_label.text = "%.1f" % (gun.reload * params.reload_time)
			else:
				timer_label.text = "%.1f" % ((1.0 - gun.reload) * params.reload_time)

			var gun_pos = gun.global_position
			gun_pos.y = 0.0
			var aim_point = camera_controller.aim_position
			aim_point.y = 0.0
			var aim_dir = gun_pos.direction_to(aim_point).normalized()

			var gun_forw = -gun.global_transform.basis.z
			gun_forw.y = 0.0
			gun_forw = gun_forw.normalized()
			# Calculate angle between gun forward and aim direction
			var angle_rad = aim_dir.signed_angle_to(gun_forw, Vector3.UP)
			var angle = rad_to_deg(angle_rad)

			indicator.visible = true
			if abs(angle) > 0.9:
				indicator.get_node("AngleLabel").text = "%.0f°" % abs(angle)
			else:
				indicator.get_node("AngleLabel").text = ""

			indicator.global_position = gun_indicator.global_position - Vector2(angle * 4.0, 0)

			var color_mod: float
			var color: Color
			if gun._valid_target:
				if gun.can_fire:
					color_mod = valid_can_fire_color_mod
				else:
					color_mod = valid_cannot_fire_color_mod
			else:
				color_mod = invalid_cannot_fire_color_mod
			if gun.reload >= 1.0:
				color = ready_gun_color * color_mod
			else:
				color = reloading_gun_color * color_mod
			bar.self_modulate = color
			progress_tex.tint_progress = color


			if controller != player_controller.current_weapon_controller:
				indicator.visible = false
				continue


			var closest_indicator: Control = null
			# Avoid overlapping indicators
			for other_indicator in already_drawn_indicators:
				var dist = indicator.global_position.distance_to(other_indicator.global_position)
				if dist < 6.0:
					closest_indicator = other_indicator
					break
			if closest_indicator:
				indicator.get_node("AngleLabel").visible = false
				indicator.global_position = closest_indicator.global_position
				if overlapping_indicators.has(closest_indicator):
					overlapping_indicators[closest_indicator].append(indicator)
				else:
					overlapping_indicators[closest_indicator] = [closest_indicator, indicator]
				var gap = 15
				var num_indicators = overlapping_indicators[closest_indicator].size()
				var step = (360.0 - (gap * num_indicators)) / num_indicators
				var angle_idx = 0
				var start = gap / 2.0
				for k: Control in overlapping_indicators[closest_indicator]:
					var k_under_tex = k.get_node("UnderTexture") as TextureProgressBar
					var k_progress_tex = k.get_node("ProgressTexture") as TextureProgressBar
					k_under_tex.radial_fill_degrees = step
					k_under_tex.radial_initial_angle = start + angle_idx * (step + gap)
					k_progress_tex.radial_fill_degrees = step
					k_progress_tex.radial_initial_angle = start + angle_idx * (step + gap)
					angle_idx += 1
			else:
				indicator.get_node("AngleLabel").visible = true
				under_tex.radial_fill_degrees = 360
				under_tex.radial_initial_angle = 0
				progress_tex.radial_fill_degrees = 360
				progress_tex.radial_initial_angle = 0
			already_drawn_indicators.append(indicator)

# Property setters to automatically update UI when values change
func set_time_to_target(value: float):
	time_to_target = value
	if time_label:
		if value < 0.0:
			time_label.text = "-- s"
		else:
			time_label.text = "%.1f s" % (value)

func set_distance_to_target(value: float):
	distance_to_target = value
	if distance_label:
		if value < 0.0:
			distance_label.text = "-- m"
		else:
			distance_label.text = "%.2f km" % (value / 1000.0)

func set_penetration_power(value: float):
	penetration_power = value
	if penetration_label:
		if value > 0.0:
			penetration_label.text = "%.1f mm" % value
		else:
			penetration_label.text = "-- mm"

func set_aim_position(value: Vector3):
	aim_position = value
	if minimap:
		minimap.aim_point = value

func set_ship_speed(value: float):
	ship_speed = value
	# Ship speed will be updated in _update_ui() along with other ship status

func set_locked_target(value):
	locked_target = value
	# Pass locked target to torpedo overlay for lead calculation
	if torpedo_overlay:
		if value is Ship:
			torpedo_overlay.target = value
		else:
			torpedo_overlay.target = null
	# Trigger redraw of crosshair for target indicators
	if crosshair_container:
		crosshair_container.queue_redraw()

func set_target_lock_enabled(value: bool):
	target_lock_enabled = value
	# Update crosshair drawing to show lock indicator

# Function to create floating damage at a world position
func create_floating_damage(damage: float, world_position: Vector3):
	"""
	Accumulates damage over DAMAGE_ACCUM_WINDOW seconds, then spawns a single
	floating damage label showing the summed total.

	Args:
		damage: The damage amount to accumulate
		world_position: World position of the hit (first hit anchors the label)
	"""
	if damage <= 0:
		return
	if not _damage_accum_active:
		_damage_accum_active = true
		_damage_accum_amount = damage
		_damage_accum_position = world_position
		_damage_accum_timer = DAMAGE_ACCUM_WINDOW
	else:
		_damage_accum_amount += damage

func _flush_damage_accumulator():
	"""Spawns the accumulated floating damage label and resets the accumulator."""
	_damage_accum_active = false
	var total := _damage_accum_amount
	var pos := _damage_accum_position
	_damage_accum_amount = 0.0
	_damage_accum_position = Vector3.ZERO
	_spawn_floating_damage(roundi(total), pos)

func _flush_recv_damage_accumulator():
	"""Spawns the accumulated damage-received label at the player ship's current position."""
	_recv_damage_accum_active = false
	var total := _recv_damage_accum_amount
	_recv_damage_accum_amount = 0.0
	if camera_controller and camera_controller._ship:
		_spawn_floating_damage(roundi(total), camera_controller._ship.global_position)

func _spawn_floating_damage(damage: int, world_position: Vector3):
	"""Instantiates and configures a FloatingDamage label at the given world position."""
	if damage <= 0:
		return
	var floating_damage = FloatingDamageScene.instantiate()
	floating_damage.damage_amount = damage
	floating_damage.world_position = world_position
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
		# Route the consumable's stat hint through HoverTooltip so it shows up
		# while the player is holding Ctrl (Godot's native tooltips don't).
		# The Callable is re-evaluated every physics frame so live values
		# (current charges, remaining cooldown, active duration) stay current.
		hover_tooltip.attach(button, func() -> String: return item.get_tooltip_text(consumable_manager))


		# Set keyboard shortcut text
		var shortcut_label: Label = button.get_node("KeyboardShortcutLabel") as Label
		if i < consumable_actions.size():
			shortcut_label.text = get_keyboard_shortcut_for_action(consumable_actions[i])
		else:
			shortcut_label.text = ""

		consumable_container.add_child(button)

		consumable_buttons.append(button)
		consumable_cooldown_bars.append(button.get_node("ProgressBar") as ProgressBar)

		# Seconds-remaining label — sibling of the ProgressBar so it is not
		# colour-tinted by the bar's modulate (yellow/blue). Anchored to the
		# full button rect so it sits centred over the overlay.
		var overlay_label := Label.new()
		overlay_label.name = "OverlaySecondsLabel"
		overlay_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		overlay_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		overlay_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay_label.add_theme_color_override("font_color", Color.WHITE)
		overlay_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
		overlay_label.add_theme_constant_override("shadow_offset_x", 1)
		overlay_label.add_theme_constant_override("shadow_offset_y", 1)
		overlay_label.add_theme_font_size_override("font_size", 12)
		overlay_label.visible = false
		button.add_child(overlay_label)
		consumable_overlay_labels.append(overlay_label)

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
		var overlay_label: Label = consumable_overlay_labels[i]

		if i < consumable_manager.equipped_consumables.size():
			var item: ConsumableItem = consumable_manager.equipped_consumables[i]
			if item:
				# Only update dynamic properties
				# button.disabled = not consumable_manager.can_use_item(item)
				var _eff_max := (item.p() as ConsumableItem).max_stack
				if _eff_max != -1:
					consumable_count_labels[i].text = str(_eff_max - item.used)

				var cooldown_remaining = consumable_manager.cooldowns.get(item.id, 0.0)
				var effect_remaining = consumable_manager.active_effects.get(item.id, 0.0)
				# Disable button if no stacks left and no active effect
				button.disabled = (_eff_max != -1 and _eff_max - item.used <= 0) and effect_remaining <= 0
				# Update cooldown display.
				# Active:   bar starts full (100%) and drains to 0 over the duration.
				# Cooldown: bar starts empty (0%) and fills to 100 as it approaches ready.
				if cooldown_remaining > 0:
					cooldown_bar.value = (cooldown_remaining) * 100.0
					cooldown_bar.modulate = Color(1.0, 1.0, 0.0) # Yellow tint during cooldown
					cooldown_bar.visible = true
					overlay_label.text = "%d" % ceili(cooldown_remaining * (item.p() as ConsumableItem).cooldown_time)
					overlay_label.visible = true
				elif effect_remaining > 0:
					cooldown_bar.value = (effect_remaining) * 100.0
					cooldown_bar.modulate = Color(0.2, 0.8, 1.0) # Blue tint during effect
					cooldown_bar.visible = true
					overlay_label.text = "%d" % ceili(effect_remaining * (item.p() as ConsumableItem).duration)
					overlay_label.visible = true
				else:
					cooldown_bar.visible = false
					overlay_label.visible = false
			else:
				button.disabled = true

# ============================================================
# region Friendly alt-consumable widget helpers
# ============================================================

## Build a VBoxContainer widget that shows one consumable's icon, stack count, and timer.
func _create_alt_consumable_widget(item: ConsumableItem, manager: ConsumableManager) -> Control:
	# Outer panel with a dark semi-transparent rounded background
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.05, 0.62)
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	style.content_margin_left = 3.0
	style.content_margin_right = 3.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 1)
	panel.add_child(box)

	# Icon
	var icon_rect := TextureRect.new()
	icon_rect.name = "Icon"
	icon_rect.texture = item.icon
	icon_rect.custom_minimum_size = Vector2(18, 18)
	icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(icon_rect)

	# Count label  (e.g. "2/3" or "∞")
	var count_lbl := Label.new()
	count_lbl.name = "CountLabel"
	count_lbl.add_theme_font_size_override("font_size", 9)
	count_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(count_lbl)

	# Timer label  (e.g. "CD 12s", "→ 5s", or "")
	var timer_lbl := Label.new()
	timer_lbl.name = "TimerLabel"
	timer_lbl.add_theme_font_size_override("font_size", 9)
	timer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(timer_lbl)

	_update_alt_consumable_widget(panel, item, manager)
	return panel

## Refresh alt-mode labels using pre-cached node refs (zero get_node calls).
func _update_alt_consumable_widget_refs(
		refs: Dictionary, item: ConsumableItem, manager: ConsumableManager) -> void:
	var icon_rect: TextureRect = refs["icon"]
	var count_lbl: Label       = refs["count"]
	var timer_lbl: Label       = refs["timer"]

	var _refs_eff_max := (item.p() as ConsumableItem).max_stack
	var exhausted := _refs_eff_max != -1 and _refs_eff_max - item.used <= 0
	icon_rect.modulate = Color(0.4, 0.4, 0.4, 0.8) if exhausted else Color.WHITE

	if _refs_eff_max == -1:
		count_lbl.text = "∞"
		count_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6, 0.9))
	else:
		var _refs_remaining := _refs_eff_max - item.used
		count_lbl.text = "%d/%d" % [_refs_remaining, _refs_eff_max]
		var frac: float = float(_refs_remaining) / max(_refs_eff_max, 1)
		count_lbl.add_theme_color_override("font_color", Color(1.0, frac, frac * 0.4, 0.9))

	var cooldown_left: float = manager.cooldowns.get(item.id, 0.0)
	var active_left:   float = manager.active_effects.get(item.id, 0.0)
	if active_left > 0.0:
		timer_lbl.text = "→%.0fs" % (active_left * (item.p() as ConsumableItem).duration)
		timer_lbl.add_theme_color_override("font_color", Color(0.2, 0.9, 1.0, 0.95))
	elif cooldown_left > 0.0:
		timer_lbl.text = "%.0fs" % (cooldown_left * (item.p() as ConsumableItem).cooldown_time)
		timer_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2, 0.9))
	else:
		timer_lbl.text = ""

## Refresh the labels inside a widget built by _create_alt_consumable_widget.
func _update_alt_consumable_widget(
		widget: Control, item: ConsumableItem, manager: ConsumableManager) -> void:
	var count_lbl  := widget.get_node("Box/CountLabel")  as Label
	var timer_lbl  := widget.get_node("Box/TimerLabel")  as Label
	var icon_rect  := widget.get_node("Box/Icon")        as TextureRect

	# Dim the icon when the consumable is exhausted
	var _widget_eff_max := (item.p() as ConsumableItem).max_stack
	var exhausted := _widget_eff_max != -1 and _widget_eff_max - item.used <= 0
	icon_rect.modulate = Color(0.4, 0.4, 0.4, 0.8) if exhausted else Color.WHITE

	# Count
	if _widget_eff_max == -1:
		count_lbl.text = "∞"
		count_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6, 0.9))
	else:
		var _widget_remaining := _widget_eff_max - item.used
		count_lbl.text = "%d/%d" % [_widget_remaining, _widget_eff_max]
		var frac: float = float(_widget_remaining) / max(_widget_eff_max, 1)
		count_lbl.add_theme_color_override("font_color", Color(1.0, frac, frac * 0.4, 0.9))

	# Timer
	var cooldown_left: float = manager.cooldowns.get(item.id, 0.0)
	var active_left:   float = manager.active_effects.get(item.id, 0.0)
	if active_left > 0.0:
		# Consumable is actively running - show remaining duration in cyan
		timer_lbl.text = "→%.0fs" % (active_left * (item.p() as ConsumableItem).duration)
		timer_lbl.add_theme_color_override("font_color", Color(0.2, 0.9, 1.0, 0.95))
	elif cooldown_left > 0.0:
		# On cooldown - show remaining cooldown in yellow
		timer_lbl.text = "%.0fs" % (cooldown_left * (item.p() as ConsumableItem).cooldown_time)
		timer_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2, 0.9))
	else:
		timer_lbl.text = ""

# endregion

# Function to set the current secondary target
func set_secondary_target(target_ship: Ship) -> void:
	current_secondary_target = target_ship
	# Target indicators will be updated in the next frame during update_ship_ui()

# Function to clear the current secondary target
func clear_secondary_target() -> void:
	current_secondary_target = null
	# Target indicators will be updated in the next frame during update_ship_ui()

# ============================================
# region Sniper Reticle Functions
# ============================================

func _setup_sniper_reticle() -> void:
	# Create a Control node for the sniper reticle
	sniper_reticle = Control.new()
	sniper_reticle.name = "SniperReticle"
	sniper_reticle.set_anchors_preset(Control.PRESET_FULL_RECT)
	sniper_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sniper_reticle.visible = true

	# Add to the main container alongside the crosshair
	$MainContainer.add_child(sniper_reticle)

	# Connect the draw signal
	sniper_reticle.connect("draw", _on_sniper_reticle_draw)

func _update_reticle_visibility() -> void:
	if not camera_controller:
		return

	var is_sniper_mode = camera_controller.current_mode == BattleCamera.CameraMode.SNIPER

	# Hide the standard crosshair in sniper mode, show in third person and free look
	if crosshair_center:
		crosshair_center.visible = not is_sniper_mode

	# Show the sniper reticle only in sniper mode
	if sniper_reticle:
		sniper_reticle.visible = is_sniper_mode
		if is_sniper_mode:
			sniper_reticle.queue_redraw()

func _on_sniper_reticle_draw() -> void:
	if not sniper_reticle or not camera_controller:
		return

	var is_sniper_mode = camera_controller.current_mode == BattleCamera.CameraMode.SNIPER
	var viewport_size = get_viewport().get_visible_rect().size
	var center = viewport_size / 2.0

	var fovy_rad = deg_to_rad(camera_controller.fov)
	var fov_rad = fovy_rad * (viewport_size.x / viewport_size.y)  # Adjust for aspect ratio

	# Sniper reticle colors
	var reticle_color = Color(1, 1, 1, 0.6)
	var line_width = 1.5

	if not is_sniper_mode:
		sniper_reticle.draw_circle(center, 2.0, reticle_color)
		return  # Only draw in sniper mode

	# Calculate distance traveled by a target moving at 10 knots during shell flight time
	var knot_10 = 10.0 * 0.514444 * ShipMovementV2.SHIP_SPEED_MODIFIER  # 10 knots in m/s (scaled)
	var _distance_traveled = knot_10 * time_to_target  # Used for reference/debugging
	var distance_to_target_m = distance_to_target


	# Long horizontal line (extending across a significant portion of the screen)
	var horizontal_length = viewport_size.x * 0.9  # 80% of screen width
	var h_start = Vector2(center.x - horizontal_length / 2.0, center.y)
	var h_end = Vector2(center.x + horizontal_length / 2.0, center.y)
	sniper_reticle.draw_line(h_start, Vector2(center.x - 20, center.y), reticle_color, line_width)
	sniper_reticle.draw_line(Vector2(center.x + 20, center.y), h_end, reticle_color, line_width)

	# # Short vertical line at center
	# var vertical_length = 30.0
	# var v_start = Vector2(center.x, center.y - vertical_length / 2.0)
	# var v_end = Vector2(center.x, center.y + vertical_length / 2.0)
	# sniper_reticle.draw_line(v_start, v_end, reticle_color, line_width)

	sniper_reticle.draw_circle(center, 2.0, reticle_color)

	# Draw tick marks for speeds - as many as will fit on the line
	if distance_to_target_m > 0 and time_to_target > 0:
		var tick_color = Color(1, 1, 1, 0.8)

		# Calculate pixels per radian for FOV conversion
		var pixels_per_radian = (viewport_size.x / 2.0) / tan(fov_rad / 2.0)

		# Calculate the maximum horizontal distance from center to line end
		var max_pixel_offset = horizontal_length / 2.0

		# Draw ticks for every 10 knots, as many as fit
		var speed = 10
		while true:
			# Calculate distance traveled at this speed during shell flight time
			var speed_ms = speed * 0.514444 * ShipMovementV2.SHIP_SPEED_MODIFIER  # knots to m/s with empirical correction
			var lead_distance = speed_ms * time_to_target

			# Convert world distance to screen pixels using FOV and distance
			var angular_offset = atan(lead_distance / distance_to_target_m)
			var pixel_offset = angular_offset * pixels_per_radian

			# Stop if tick would be beyond the line
			if pixel_offset > max_pixel_offset:
				break

			# Determine tick height based on speed (larger ticks for multiples of 30)
			var tick_height = 6.0
			if speed % 30 == 0:
				tick_height = 10.0
			elif speed % 10 == 0 and (speed == 10 or speed == 50 or speed % 50 == 0):
				tick_height = 8.0

			# Draw tick on the right side (for targets moving left)
			var tick_x_right = center.x + pixel_offset
			sniper_reticle.draw_line(
				Vector2(tick_x_right, center.y - tick_height),
				Vector2(tick_x_right, center.y + tick_height),
				tick_color, line_width
			)

			# Draw tick on the left side (for targets moving right)
			var tick_x_left = center.x - pixel_offset
			sniper_reticle.draw_line(
				Vector2(tick_x_left, center.y - tick_height),
				Vector2(tick_x_left, center.y + tick_height),
				tick_color, line_width
			)

			speed += 10

# endregion
