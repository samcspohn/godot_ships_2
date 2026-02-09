extends VBoxContainer

class_name HitStatCounters

# Signal emitted when floating damage should be created
signal floating_damage_requested(damage: float, position: Vector3)

# Unified configuration for all stat counter types
# Categories: "sub" (sub-counter types), "summary" (main/sec/sunk/fire)
static var STAT_CONFIG = {
	# Sub-counter types (used in hover panels)
	"penetration": {
		"category": "sub",
		"display_name": "P",
		"hit_result": ArmorInteraction.HitResult.PENETRATION,
		"stat_main": "penetration_count",
		"stat_sec": "sec_penetration_count",
		"bg_color": Color(0.4, 0.4, 0.4, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"overpenetration": {
		"category": "sub",
		"display_name": "Op",
		"hit_result": ArmorInteraction.HitResult.OVERPENETRATION,
		"stat_main": "overpen_count",
		"stat_sec": "sec_overpen_count",
		"bg_color": Color(0.4, 0.32, 0.08, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"shatter": {
		"category": "sub",
		"display_name": "S",
		"hit_result": ArmorInteraction.HitResult.SHATTER,
		"stat_main": "shatter_count",
		"stat_sec": "sec_shatter_count",
		"bg_color": Color(0.32, 0.08, 0.08, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"ricochet": {
		"category": "sub",
		"display_name": "R",
		"hit_result": ArmorInteraction.HitResult.RICOCHET,
		"stat_main": "ricochet_count",
		"stat_sec": "sec_ricochet_count",
		"bg_color": Color(0.24, 0.24, 0.4, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"citadel": {
		"category": "sub",
		"display_name": "C",
		"hit_result": ArmorInteraction.HitResult.CITADEL,
		"stat_main": "citadel_count",
		"stat_sec": "sec_citadel_count",
		"bg_color": Color(0.142, 0.142, 0.142, 0.9),
		"label_color": Color(1, 0.8, 0.2, 1)
	},
	"citadel_overpen": {
		"category": "sub",
		"display_name": "Co",
		"hit_result": ArmorInteraction.HitResult.CITADEL_OVERPEN,
		"stat_main": "citadel_overpen_count",
		"stat_sec": "sec_citadel_overpen_count",
		"bg_color": Color(0.5, 0.25, 0.1, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"partial_pen": {
		"category": "sub",
		"display_name": "Pp",
		"hit_result": ArmorInteraction.HitResult.PARTIAL_PEN,
		"stat_main": "partial_pen_count",
		"stat_sec": "sec_partial_pen_count",
		"bg_color": Color(0.3, 0.3, 0.5, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"torpedo_belt": {
		"category": "sub",
		"display_name": "Tb",
		"hit_result": 1000,
		"stat_main": "torpedo_belt_count",
		"stat_sec": "sec_torpedo_belt_count",
		"bg_color": Color(0.3, 0.3, 0.5, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	"torpedo_hit": {
		"category": "sub",
		"display_name": "Th",
		"hit_result": 1001,
		"stat_main": "torpedo_hit_count",
		"stat_sec": "sec_torpedo_hit_count",
		"bg_color": Color(0.3, 0.3, 0.5, 0.9),
		"label_color": Color(0.8, 0.8, 0.8, 1)
	},
	# Summary counter types
	"main": {
		"category": "summary",
		"display_name": "MAIN",
		"stat_count": "main_hits",
		"stat_damage": "main_damage",
		"has_damage_display": true,
		"temp_priority": 1,
		"bg_color": Color(0.24, 0.32, 0.24, 0.9),
		"label_color": Color(0.6, 0.8, 0.6, 1),
		"sub_counters": ["penetration", "overpenetration", "shatter", "ricochet", "citadel", "citadel_overpen", "partial_pen"],
		"min_size": Vector2(80, 40),
		"font_size": 24
	},
	"sec": {
		"category": "summary",
		"display_name": "SEC",
		"stat_count": "secondary_count",
		"stat_damage": "sec_damage",
		"has_damage_display": true,
		"temp_priority": 2,
		"bg_color": Color(0.134, 0.212, 0.178, 0.9),
		"label_color": Color(0.33523, 0.530682, 0.445213, 1),
		"sub_counters": ["penetration", "overpenetration", "shatter", "ricochet", "citadel", "citadel_overpen", "partial_pen"],
		"min_size": Vector2(80, 40),
		"font_size": 24
	},
	"torp": {
		"category": "summary",
		"display_name": "TORP",
		"stat_count": "torpedo_count",
		"stat_damage": "torpedo_damage",
		"has_damage_display": true,
		"temp_priority": 3,
		"bg_color": Color(0.104, 0.205, 0.51, 0.9),
		"label_color": Color(0.479, 0.64, 0.882, 1.0),
		"sub_counters": [],
		"min_size": Vector2(80, 40),
		"font_size": 24
	},
	"sunk": {
		"category": "summary",
		"display_name": "SUNK",
		"stat_count": "frags",
		"has_damage_display": false,
		"temp_priority": 4,
		"bg_color": Color(0.32, 0.08, 0.08, 0.9),
		"label_color": Color(1, 0.284297, 0.346101, 1),
		"sub_counters": [],
		"min_size": Vector2(80, 40),
		"font_size": 24
	},
	"fire": {
		"category": "summary",
		"display_name": "FIRE",
		"stat_count": "fire_count",
		"stat_damage": "fire_damage",
		"has_damage_display": true,
		"temp_priority": 5,
		"bg_color": Color(0.6, 0.3, 0.05, 0.9),
		"label_color": Color(1, 0.6, 0.2, 1),
		"sub_counters": [],
		"min_size": Vector2(80, 40),
		"font_size": 24
	},
	"flood": {
		"category": "summary",
		"display_name": "FLOOD",
		"stat_count": "flood_count",
		"stat_damage": "flood_damage",
		"has_damage_display": true,
		"temp_priority": 6,
		"bg_color": Color(0.479, 0.64, 0.882, 1.0),
		"label_color": Color(0.104, 0.205, 0.51, 0.9),
		"sub_counters": [],
		"min_size": Vector2(80, 40),
		"font_size": 24
	},
	"spot": {
		"category": "summary",
		"display_name": "SPOT",
		"stat_count": "spotting_count",
		"stat_damage": "spotting_damage",
		"has_damage_display": true,
		"temp_priority": 7,
		"bg_color": Color(0.593, 0.593, 0.593, 1.0),
		"label_color": Color(0.191, 0.191, 0.191, 0.902),
		"sub_counters": [],
		"min_size": Vector2(80, 40),
		"font_size": 24
	}
}

# Preloaded counter scene
const STAT_COUNTER_SCENE = preload("res://src/ui/stat_counter.tscn")

# Ship stats reference
var stats = null

# Counter display settings
var counter_display_time: float = 5.0

# Summary counter types in display order
var summary_types: Array = ["spot", "flood", "fire", "torp", "sec", "main", "sunk"]

# Dynamic counter storage
var summary_counters: Dictionary = {}       # Permanent summary counters (top row)
var hover_panels: Dictionary = {}           # Hover panel VBoxContainers for each summary type
var hover_sub_counters: Dictionary = {}     # Sub-counters within hover panels
var hover_damage_labels: Dictionary = {}    # Damage labels within hover panels
var temp_containers: Dictionary = {}        # Temporary flash containers
var temp_counters: Dictionary = {}          # Temporary flash counters

# Active temporary counter tracking
var active_temp_counters: Dictionary = {}   # Tracks active temp counters
var temp_timers: Dictionary = {}            # Timers for temp containers

# Reverse lookup: HitResult enum -> hit_type string
var hit_result_to_type: Dictionary = {}

# Hover state tracking
var hover_states: Dictionary = {}

# UI references
@onready var summary_container: HBoxContainer = $HBoxContainer
@onready var damage_value_label: Label = $HBoxContainer/DamageCounter/DamageValue


func _ready():
	_build_hit_result_lookup()
	_create_summary_counters()
	_create_hover_panels()
	_create_temp_containers()
	update_counters()


func _physics_process(delta):
	check_hover_detection()
	update_temp_timers(delta)

	if stats and stats.damage_events.size() > 0:
		process_damage_events(stats.damage_events)
		update_counters()


func _build_hit_result_lookup():
	"""Build reverse lookup from HitResult enum to hit_type string"""
	for stat_type in STAT_CONFIG:
		var config = STAT_CONFIG[stat_type]
		if config.category == "sub" and config.has("hit_result"):
			hit_result_to_type[config.hit_result] = stat_type


func _create_summary_counters():
	"""Create the permanent summary counters in the top row"""
	# Clear existing counters (except DamageCounter which is last)
	var children_to_remove = []
	for child in summary_container.get_children():
		if child.name != "DamageCounter":
			children_to_remove.append(child)
	for child in children_to_remove:
		child.queue_free()

	# Create summary counters in order
	for summary_type in summary_types:
		var config = STAT_CONFIG[summary_type].duplicate()
		config["type"] = summary_type

		var counter = _create_counter(config)
		summary_container.add_child(counter)
		summary_container.move_child(counter, summary_container.get_child_count() - 2)  # Before DamageCounter
		summary_counters[summary_type] = counter

		# Setup hover detection
		counter.mouse_filter = Control.MOUSE_FILTER_PASS
		hover_states[summary_type] = false


func _create_hover_panels():
	"""Create hover panels with sub-counters and/or damage display for summary types"""
	for summary_type in summary_types:
		var config = STAT_CONFIG[summary_type]
		var sub_counter_list = config.get("sub_counters", [])
		var has_damage_display = config.get("has_damage_display", false)

		# Skip if no sub-counters and no damage display
		if sub_counter_list.is_empty() and not has_damage_display:
			continue

		# Create VBox for hover panel
		var vbox = VBoxContainer.new()
		vbox.name = summary_type.capitalize() + "VBox"
		vbox.visible = false
		add_child(vbox)
		hover_panels[summary_type] = vbox

		# Create HBox for sub-counters (if any)
		if not sub_counter_list.is_empty():
			var hbox = HBoxContainer.new()
			hbox.name = summary_type.capitalize() + "SubCounters"
			vbox.add_child(hbox)

			# Create sub-counters from the list
			hover_sub_counters[summary_type] = {}
			for sub_type in sub_counter_list:
				if sub_type not in STAT_CONFIG:
					continue
				var sub_config = STAT_CONFIG[sub_type].duplicate()
				sub_config["type"] = sub_type

				var sub_counter = _create_counter(sub_config)
				hbox.add_child(sub_counter)
				hover_sub_counters[summary_type][sub_type] = sub_counter

		# Create damage display (if enabled)
		if has_damage_display:
			var damage_hbox = HBoxContainer.new()
			damage_hbox.name = "DamageCounter"
			vbox.add_child(damage_hbox)

			var damage_label_text = Label.new()
			damage_label_text.add_theme_font_size_override("font_size", 16)
			damage_label_text.text = config.display_name + " Damage:"
			damage_label_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			damage_hbox.add_child(damage_label_text)

			var damage_value = Label.new()
			damage_value.custom_minimum_size = Vector2(80, 0)
			damage_value.add_theme_font_size_override("font_size", 16)
			damage_value.text = "0"
			damage_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			damage_hbox.add_child(damage_value)
			hover_damage_labels[summary_type] = damage_value


func _create_temp_containers():
	"""Create temporary flash counter containers for all summary types in priority order"""
	# Sort summary types by temp_priority
	var sorted_types = summary_types.duplicate()
	sorted_types.sort_custom(func(a, b):
		var priority_a = STAT_CONFIG[a].get("temp_priority", 999)
		var priority_b = STAT_CONFIG[b].get("temp_priority", 999)
		return priority_a < priority_b
	)

	for summary_type in sorted_types:
		# Create temp container HBox
		var temp_hbox = HBoxContainer.new()
		temp_hbox.name = summary_type.capitalize() + "CounterTemp"
		temp_hbox.visible = false
		temp_hbox.alignment = BoxContainer.ALIGNMENT_END
		add_child(temp_hbox)
		temp_containers[summary_type] = temp_hbox

		var config = STAT_CONFIG[summary_type]
		var sub_counter_list = config.get("sub_counters", [])

		# Always create a summary counter for temp display
		var summary_config = config.duplicate()
		summary_config["type"] = summary_type
		var summary_temp_counter = _create_counter(summary_config)
		temp_hbox.add_child(summary_temp_counter)

		# Initialize temp_counters structure
		temp_counters[summary_type] = {
			"summary": summary_temp_counter,
			"subs": {}
		}

		# Create individual sub-type counters if available
		if not sub_counter_list.is_empty():
			for sub_type in sub_counter_list:
				if sub_type not in STAT_CONFIG:
					continue
				var sub_config = STAT_CONFIG[sub_type].duplicate()
				sub_config["type"] = sub_type

				var temp_counter = _create_counter(sub_config)
				temp_counter.visible = false
				temp_hbox.add_child(temp_counter)
				temp_counters[summary_type]["subs"][sub_type] = temp_counter


func _create_counter(config: Dictionary) -> StatCounter:
	"""Create and configure a single counter instance"""
	var counter: StatCounter = STAT_COUNTER_SCENE.instantiate() as StatCounter
	counter.ready.connect(func(): counter.setup(config))
	return counter


func set_stats(new_stats) -> void:
	"""Set the ship stats reference for this counter display"""
	stats = new_stats
	update_counters()


func update_counters() -> void:
	"""Update all counter displays with current stats"""
	if not stats:
		return

	# Update total damage
	_update_label(damage_value_label, stats.total_damage)

	# Update summary counters
	for summary_type in summary_types:
		var config = STAT_CONFIG[summary_type]

		# Update main count
		if summary_type in summary_counters:
			var count_value = stats.get(config.stat_count)
			summary_counters[summary_type].update_count(count_value)
			# Hide summary counters with 0 value
			summary_counters[summary_type].visible = count_value > 0

		# Update hover panel damage
		if summary_type in hover_damage_labels:
			var damage_stat = config.get("stat_damage", "")
			if damage_stat != "" and stats.get(damage_stat) != null:
				_update_label(hover_damage_labels[summary_type], stats.get(damage_stat))

		# Update sub-counters
		if summary_type in hover_sub_counters:
			for sub_type in hover_sub_counters[summary_type]:
				var sub_config = STAT_CONFIG[sub_type]
				# Determine which stat field to use based on summary type
				var stat_name = ""
				match summary_type:
					"main":
						stat_name = sub_config.get("stat_main", "")
					"sec":
						stat_name = sub_config.get("stat_sec", "")
					_:
						# For other summaries, try stat_<summary_type> pattern
						stat_name = sub_config.get("stat_" + summary_type, "")

				if stat_name != "":
					var value = stats.get(stat_name)
					if value != null:
						var sub_counter = hover_sub_counters[summary_type][sub_type]
						sub_counter.update_count(value)
						# Hide counters with 0 value
						sub_counter.visible = value > 0


func _update_label(label: Label, value) -> void:
	"""Update a single label with formatted value"""
	if label:
		label.text = str(int(value))


func process_damage_events(damage_events: Array):
	"""Process damage events and show appropriate counters"""
	for event in damage_events:
		var type = event.get("type", "")
		match type:
			"hit":
				var event_type: ArmorInteraction.HitResult = event.get("hit_type", -1)
				var is_secondary: bool = event.get("sec", false)
				var summary_type = "sec" if is_secondary else "main"

				# Get hit type from event
				var hit_type = hit_result_to_type.get(event_type, "")

				if hit_type != "":
					# Show temporary flash counter
					show_temp_hit_counter(hit_type, summary_type)

				# Emit signal for floating damage
				floating_damage_requested.emit(event.damage, event.position)
			"torp":
				show_temp_summary_counter("torp")
				floating_damage_requested.emit(event.damage, event.position)
			"sunk":
				show_temp_summary_counter("sunk")
			"fire":
				show_temp_summary_counter("fire")
			"flood":
				show_temp_summary_counter("flood")
			"spot":
				show_temp_summary_counter("spot")

	_update_label(damage_value_label, stats.total_damage)
	damage_events.clear()


func show_temp_hit_counter(hit_type: String, summary_type: String):
	"""Show or update a temporary hit counter for hit-based summaries (main/sec)"""
	if hit_type not in STAT_CONFIG:
		return
	if summary_type not in temp_counters:
		return

	var container = temp_containers[summary_type]
	var counters_data = temp_counters[summary_type]
	var summary_counter = counters_data["summary"]
	var sub_counter = counters_data["subs"].get(hit_type)

	# Reset timer for this container
	temp_timers[summary_type] = counter_display_time

	# Show and update summary counter
	var summary_key = summary_type + "_summary"
	container.visible = true
	if summary_key in active_temp_counters:
		summary_counter.increment()
	else:
		summary_counter.update_count(1)
		active_temp_counters[summary_key] = {
			"counter": summary_counter,
			"summary_type": summary_type,
			"is_summary": true
		}

	# Show and update sub-counter if available
	if sub_counter:
		var counter_key = hit_type + "_" + summary_type
		if counter_key in active_temp_counters:
			sub_counter.increment()
		else:
			sub_counter.visible = true
			sub_counter.update_count(1)
			active_temp_counters[counter_key] = {
				"counter": sub_counter,
				"summary_type": summary_type,
				"hit_type": hit_type,
				"is_summary": false
			}


func show_temp_summary_counter(summary_type: String, count: int = 1):
	"""Show or update a temporary counter for simple summaries (sunk/fire)"""
	if summary_type not in temp_containers:
		return
	if summary_type not in temp_counters:
		return

	var container = temp_containers[summary_type]
	var counters_data = temp_counters[summary_type]
	var summary_counter = counters_data["summary"]

	# Reset timer
	temp_timers[summary_type] = counter_display_time

	var summary_key = summary_type + "_summary"
	container.visible = true
	if summary_key in active_temp_counters:
		summary_counter.increment(count)
	else:
		summary_counter.update_count(count)
		active_temp_counters[summary_key] = {
			"counter": summary_counter,
			"summary_type": summary_type,
			"is_summary": true
		}


func update_temp_timers(delta: float):
	"""Update temporary counter timers and hide expired ones"""
	var expired_types = []

	for summary_type in temp_timers:
		temp_timers[summary_type] -= delta
		if temp_timers[summary_type] <= 0.0:
			expired_types.append(summary_type)

	# Process expired timers
	for summary_type in expired_types:
		temp_timers.erase(summary_type)

		# Hide the container
		if summary_type in temp_containers:
			temp_containers[summary_type].visible = false

		# Reset counters and remove from active tracking
		var keys_to_remove = []
		for key in active_temp_counters:
			var data = active_temp_counters[key]
			if data.summary_type == summary_type:
				if data.counter:
					# Only hide sub-counters, summary counter stays visible but resets
					if not data.get("is_summary", false):
						data.counter.visible = false
					data.counter.reset()
				keys_to_remove.append(key)

		for key in keys_to_remove:
			active_temp_counters.erase(key)


func check_hover_detection():
	"""Manual hover detection for summary counter controls"""
	var mouse_pos = get_viewport().get_mouse_position()

	for summary_type in summary_types:
		if summary_type not in summary_counters:
			continue
		if summary_type not in hover_panels:
			continue

		var counter = summary_counters[summary_type]

		# Skip hover detection for hidden counters (0 count)
		if not counter.visible:
			# Ensure hover panel is hidden if counter is not visible
			if hover_states[summary_type]:
				hover_states[summary_type] = false
				hover_panels[summary_type].visible = false
			continue

		var rect = Rect2(counter.global_position, counter.size)
		var is_hovering = rect.has_point(mouse_pos)

		if is_hovering != hover_states[summary_type]:
			hover_states[summary_type] = is_hovering
			hover_panels[summary_type].visible = is_hovering


func update_frag_count(frags: int) -> void:
	"""Update the sunk counter independently"""
	if "sunk" in summary_counters:
		summary_counters["sunk"].update_count(frags)


func update_total_damage(damage: float) -> void:
	"""Update the total damage counter independently"""
	_update_label(damage_value_label, damage)


# Helper to add a new stat type at runtime (for modding/extensions)
static func register_stat_type(stat_type: String, config: Dictionary) -> void:
	"""Register a new stat type dynamically"""
	STAT_CONFIG[stat_type] = config
