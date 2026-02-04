extends VBoxContainer

class_name HitStatCounters

# Signal emitted when floating damage should be created
signal floating_damage_requested(damage: float, position: Vector3)

# Hit type configuration - single source of truth for all counter types
static var HIT_TYPE_CONFIG = {
	"penetration": {
		"display_name": "P",
		"hit_result": ArmorInteraction.HitResult.PENETRATION,
		"stat_main": "penetration_count",
		"stat_sec": "sec_penetration_count",
		"bg_color": Color(0.4, 0.4, 0.4, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"overpenetration": {
		"display_name": "Op",
		"hit_result": ArmorInteraction.HitResult.OVERPENETRATION,
		"stat_main": "overpen_count",
		"stat_sec": "sec_overpen_count",
		"bg_color": Color(0.4, 0.32, 0.08, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"shatter": {
		"display_name": "S",
		"hit_result": ArmorInteraction.HitResult.SHATTER,
		"stat_main": "shatter_count",
		"stat_sec": "sec_shatter_count",
		"bg_color": Color(0.32, 0.08, 0.08, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"ricochet": {
		"display_name": "R",
		"hit_result": ArmorInteraction.HitResult.RICOCHET,
		"stat_main": "ricochet_count",
		"stat_sec": "sec_ricochet_count",
		"bg_color": Color(0.24, 0.24, 0.4, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"citadel": {
		"display_name": "C",
		"hit_result": ArmorInteraction.HitResult.CITADEL,
		"stat_main": "citadel_count",
		"stat_sec": "sec_citadel_count",
		"bg_color": Color(0.142, 0.142, 0.142, 0.9),
		"label_color": Color(1, 0.8, 0.2, 1)
	},
	"citadel_overpen": {
		"display_name": "Co",
		"hit_result": ArmorInteraction.HitResult.CITADEL_OVERPEN,
		"stat_main": "citadel_overpen_count",
		"stat_sec": "sec_citadel_overpen_count",
		"bg_color": Color(0.5, 0.25, 0.1, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"partial_pen": {
		"display_name": "Pp",
		"hit_result": ArmorInteraction.HitResult.PARTIAL_PEN,
		"stat_main": "partial_pen_count",
		"stat_sec": "sec_partial_pen_count",
		"bg_color": Color(0.3, 0.3, 0.5, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	}
}

# Preloaded counter scene
const HIT_COUNTER_SCENE = preload("res://src/camera/hit_counter.tscn")

# Ship stats reference
var stats = null

# Hit counter display settings
var hit_counter_display_time: float = 5.0

# Dynamic counter storage - keyed by hit_type
var main_counters: Dictionary = {}      # Permanent main counters (hover panel)
var sec_counters: Dictionary = {}       # Permanent secondary counters (hover panel)
var temp_main_counters: Dictionary = {} # Temporary main counters (flash display)
var temp_sec_counters: Dictionary = {}  # Temporary secondary counters (flash display)

# Active hit counter tracking for temp displays
var active_hit_counters: Dictionary = {}
var active_hit_timers: Dictionary = {}

# Reverse lookup: HitResult enum -> hit_type string
var hit_result_to_type: Dictionary = {}

# Hover state tracking
var was_hovering_secondary: bool = false
var was_hovering_main: bool = false

# UI references (these remain manual as they're structural)
@onready var summary_container: HBoxContainer = $HBoxContainer
@onready var secondary_counter: Control = $HBoxContainer/SecondaryCounter
@onready var main_counter: Control = $HBoxContainer/MainCounter
@onready var frag_count_label: Label = $HBoxContainer/FragCounter/FragContainer/FragCount
@onready var damage_value_label: Label = $HBoxContainer/DamageCounter/DamageValue
@onready var secondary_count_label: Label = $HBoxContainer/SecondaryCounter/SecondaryContainer/SecondaryCount
@onready var main_count_label: Label = $HBoxContainer/MainCounter/MainContainer/MainCount

# Hover panel containers
@onready var main_hit_counters: VBoxContainer = $MainVBox
@onready var secondary_hit_counters: VBoxContainer = $SecondaryVBox
@onready var main_hover_row: HBoxContainer = $MainVBox/MainHitCounters
@onready var sec_hover_row: HBoxContainer = $SecondaryVBox/SecondaryHitCounters
@onready var main_damage_label: Label = $MainVBox/DamageCounter/DamageValue
@onready var sec_damage_label: Label = $SecondaryVBox/DamageCounter/DamageValue

# Temporary flash counter containers
@onready var main_counter_temp: HBoxContainer = $MainCounterTemp
@onready var sec_counter_temp: HBoxContainer = $SecCounterTemp


func _ready():
	_build_hit_result_lookup()
	_create_dynamic_counters()
	setup_counter_hover_functionality()
	update_counters()


func _physics_process(delta):
	check_hover_detection()
	update_hit_counter_timers(delta)

	if stats and stats.damage_events.size() > 0:
		process_damage_events(stats.damage_events)
		update_counters()


func _build_hit_result_lookup():
	"""Build reverse lookup from HitResult enum to hit_type string"""
	for hit_type in HIT_TYPE_CONFIG:
		var config = HIT_TYPE_CONFIG[hit_type]
		hit_result_to_type[config.hit_result] = hit_type


func _create_dynamic_counters():
	"""Create all counter instances from the configuration"""
	# Clear existing children from the dynamic containers
	_clear_container(main_hover_row)
	_clear_container(sec_hover_row)
	_clear_container(main_counter_temp)
	_clear_container(sec_counter_temp)

	# Hide temp containers initially
	main_counter_temp.visible = false
	sec_counter_temp.visible = false

	# Create counters for each hit type
	for hit_type in HIT_TYPE_CONFIG:
		var config = HIT_TYPE_CONFIG[hit_type].duplicate()
		config["type"] = hit_type

		# Main hover panel counter
		var main_hover_counter = _create_counter(config)
		main_hover_row.add_child(main_hover_counter)
		main_counters[hit_type] = main_hover_counter

		# Secondary hover panel counter
		var sec_hover_counter = _create_counter(config)
		sec_hover_row.add_child(sec_hover_counter)
		sec_counters[hit_type] = sec_hover_counter

		# Temporary main flash counter
		var temp_main = _create_counter(config)
		temp_main.visible = false
		main_counter_temp.add_child(temp_main)
		temp_main_counters[hit_type] = temp_main

		# Temporary secondary flash counter
		var temp_sec = _create_counter(config)
		temp_sec.visible = false
		sec_counter_temp.add_child(temp_sec)
		temp_sec_counters[hit_type] = temp_sec


func _create_counter(config: Dictionary) -> HitCounter:
	"""Create and configure a single counter instance"""
	var counter: HitCounter = HIT_COUNTER_SCENE.instantiate() as HitCounter
	# Need to call setup after it's in the tree, so we defer it
	counter.ready.connect(func(): counter.setup(config))
	return counter


func _clear_container(container: Control):
	"""Remove all children from a container"""
	for child in container.get_children():
		child.queue_free()


func set_stats(new_stats) -> void:
	"""Set the ship stats reference for this counter display"""
	stats = new_stats
	update_counters()


func setup_counter_hover_functionality():
	"""Setup hover detection for the counter controls"""
	secondary_counter.mouse_filter = Control.MOUSE_FILTER_PASS
	main_counter.mouse_filter = Control.MOUSE_FILTER_PASS


func update_counters() -> void:
	"""Update all counter displays with current stats"""
	if not stats:
		return

	# Update summary counters
	_update_label(damage_value_label, stats.total_damage)
	_update_label(main_count_label, stats.main_hits)
	_update_label(frag_count_label, stats.frags)
	_update_label(secondary_count_label, stats.secondary_count)
	_update_label(main_damage_label, stats.main_damage)
	_update_label(sec_damage_label, stats.sec_damage)

	# Update all hit type counters from config
	for hit_type in HIT_TYPE_CONFIG:
		var config = HIT_TYPE_CONFIG[hit_type]

		# Get stat values using property names from config
		var main_value = stats.get(config.stat_main)
		var sec_value = stats.get(config.stat_sec)

		# Update hover panel counters
		if hit_type in main_counters:
			main_counters[hit_type].update_count(main_value)
		if hit_type in sec_counters:
			sec_counters[hit_type].update_count(sec_value)


func _update_label(label: Label, value) -> void:
	"""Update a single label with formatted value"""
	if label:
		label.text = str(int(value))


func process_damage_events(damage_events: Array):
	"""Process damage events and show appropriate hit counters"""
	for event in damage_events:
		var event_type: ArmorInteraction.HitResult = event.get("type", -1)
		var is_secondary: bool = event.get("sec", false)

		# Get hit type from event
		var hit_type = hit_result_to_type.get(event_type, "")

		if hit_type != "":
			var config = HIT_TYPE_CONFIG[hit_type]

			# Update the appropriate permanent counter
			if is_secondary:
				var stat_value = stats.get(config.stat_sec)
				if hit_type in sec_counters:
					sec_counters[hit_type].update_count(stat_value)
			else:
				var stat_value = stats.get(config.stat_main)
				if hit_type in main_counters:
					main_counters[hit_type].update_count(stat_value)

			# Show temporary flash counter
			show_hit_counter(hit_type, is_secondary)

		# Update hit counts and damage
		if is_secondary:
			_update_label(sec_damage_label, stats.sec_damage)
			_update_label(secondary_count_label, stats.secondary_count)
		else:
			_update_label(main_damage_label, stats.main_damage)
			_update_label(main_count_label, stats.main_hits)

		# Emit signal for floating damage
		floating_damage_requested.emit(event.damage, event.position)

	_update_label(damage_value_label, stats.total_damage)
	damage_events.clear()


func show_hit_counter(hit_type: String, is_secondary: bool):
	"""Show or update a temporary hit counter for the specified type"""
	if hit_type not in HIT_TYPE_CONFIG:
		return

	var counter_key = hit_type + ("_sec" if is_secondary else "_main")
	var counter: HitCounter = temp_sec_counters[hit_type] if is_secondary else temp_main_counters[hit_type]
	var container: HBoxContainer = sec_counter_temp if is_secondary else main_counter_temp

	# Reset timer for this container
	active_hit_timers[container] = hit_counter_display_time

	if counter_key in active_hit_counters:
		# Increment existing counter
		counter.increment()
	else:
		# Show new counter
		counter.visible = true
		container.visible = true
		counter.update_count(1)

		active_hit_counters[counter_key] = {
			"counter": counter,
			"container": container,
			"is_secondary": is_secondary,
			"hit_type": hit_type
		}


func update_hit_counter_timers(delta: float):
	"""Update hit counter timers and hide expired ones"""
	var keys_to_remove = []

	for container in active_hit_timers.keys():
		active_hit_timers[container] -= delta
		if active_hit_timers[container] <= 0.0:
			# Find and hide all counters for this container
			for key in active_hit_counters:
				var counter_data = active_hit_counters[key]
				if counter_data.container == container:
					counter_data.counter.visible = false
					keys_to_remove.append(key)

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


func check_hover_detection():
	"""Manual hover detection for counter controls"""
	if not secondary_counter or not main_counter:
		return

	var mouse_pos = get_viewport().get_mouse_position()

	# Check secondary counter hover
	var sec_rect = Rect2(secondary_counter.global_position, secondary_counter.size)
	var is_hovering_secondary = sec_rect.has_point(mouse_pos)

	if is_hovering_secondary != was_hovering_secondary:
		was_hovering_secondary = is_hovering_secondary
		secondary_hit_counters.visible = is_hovering_secondary

	# Check main counter hover
	var main_rect = Rect2(main_counter.global_position, main_counter.size)
	var is_hovering_main = main_rect.has_point(mouse_pos)

	if is_hovering_main != was_hovering_main:
		was_hovering_main = is_hovering_main
		main_hit_counters.visible = is_hovering_main


func update_frag_count(frags: int) -> void:
	"""Update the frag counter independently"""
	_update_label(frag_count_label, frags)


func update_total_damage(damage: float) -> void:
	"""Update the total damage counter independently"""
	_update_label(damage_value_label, damage)


# Helper to add a new hit type at runtime (for modding/extensions)
static func register_hit_type(hit_type: String, config: Dictionary) -> void:
	"""Register a new hit type dynamically"""
	HIT_TYPE_CONFIG[hit_type] = config
