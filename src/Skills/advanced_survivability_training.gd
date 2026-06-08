extends Skill

## Advanced Survivability Training — all classes, Tier 3.
## For every 100% of max HP accumulated in potential damage received, gain 1
## tier of DC/RP improvements. Caps at 20 tiers.

const COOLDOWN_PER_TIER: float = 0.01   # -1% cooldown per tier
# const DURATION_PER_TIER: float = 0.005   # +0.5% duration per tier
# const MAX_TIERS: int = 20

var _applied_tiers: int = 0

func _init() -> void:
	skill_id = "advst"
	name = "Advanced Survivability Training"
	tier = 3
	cost = 3
	flavor_text = "Battle experience improves damage control readiness."
	tooltip_stats = [
		{"stat": "Per 100% max HP Potential Damage",  "value": ""},
		{"stat": "  DC/RP Cooldown",          "value": "-%.1f%% (stacking)" % (COOLDOWN_PER_TIER * 100), "positive": true},
		# {"stat": "  DC/RP Duration",          "value": "+0.5% (stacking)", "positive": true},
		# {"stat": "Max Tiers",                 "value": "20 (-10% cooldown, +10% duration)"},
	]

func _a(ship: Ship) -> void:
	if _applied_tiers == 0:
		return
	# var cool_factor := 1.0 - _applied_tiers * COOLDOWN_PER_TIER
	# var dur_factor  := 1.0 + _applied_tiers * DURATION_PER_TIER
	for consumable: ConsumableItem in ship.consumable_manager.equipped_consumables:
		if consumable.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL or \
				consumable.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
			var dm := consumable.dynamic_mod as ConsumableItem
			dm.cooldown_time *= pow(1 - COOLDOWN_PER_TIER, _applied_tiers)
			# if dm.duration > 0.0:
			# 	dm.duration *= pow(1 + DURATION_PER_TIER, _applied_tiers)

func apply(ship: Ship) -> void:
	_applied_tiers = 0
	_ship = ship
	ship.add_dynamic_mod(_a)

func _proc(_delta: float) -> void:
	var new_tiers := int(_ship.stats.potential_damage / _ship.health_controller.max_hp)
	if new_tiers != _applied_tiers:
		_applied_tiers = new_tiers
		# _ship.update_dynamic_mods = true
		_ship.remove_dynamic_mod(_a)
		_ship.add_dynamic_mod(_a)

func init_ui(container: Control) -> void:
	var desired_size := 30.0
	container.custom_minimum_size = Vector2(desired_size, desired_size)
	container.size = Vector2(desired_size, desired_size)

	# Background circle icon
	var tex: Texture2D = load("res://circle.png")
	var bar := TextureProgressBar.new()
	bar.max_value = 1.0
	bar.value = 1.0
	bar.fill_mode = 4  # clockwise
	bar.texture_under = tex
	bar.texture_progress = tex
	bar.tint_under    = Color(0.02, 0.15, 0.35, 0.30)
	bar.tint_progress = Color(0.20, 0.60, 1.00, 0.85)
	var texture_size := 256.0
	var s := desired_size / texture_size
	bar.scale = Vector2(s, s)
	container.add_child(bar)

	# Stack-count label centered over the circle
	var lbl := Label.new()
	lbl.name = "StackLabel"
	lbl.layout_mode = 1
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.8))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	container.add_child(lbl)

func update_ui(container: Control) -> void:
	if _applied_tiers == 0:
		container.visible = false
		return
	container.visible = true
	var lbl := container.get_node_or_null("StackLabel") as Label
	if lbl:
		lbl.text = str(_applied_tiers)

func init_hover(container: Control, ht) -> void:
	ht.attach(container, func() -> String:
		var cool_pct := (1.0 - pow(1.0 - COOLDOWN_PER_TIER, _applied_tiers)) * 100.0
		# var dur_pct  := (pow(1.0 + DURATION_PER_TIER, _applied_tiers) - 1.0) * 100.0
		return "Advanced Survivability Training\nStacks: %d\nDC/RP Cooldown: -%.1f%%" \
			% [_applied_tiers, cool_pct]
	)

func to_bytes() -> PackedByteArray:
	var writer := StreamPeerBuffer.new()
	writer.put_32(_applied_tiers)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray) -> void:
	var reader := StreamPeerBuffer.new()
	reader.data_array = data
	_applied_tiers = reader.get_32()
