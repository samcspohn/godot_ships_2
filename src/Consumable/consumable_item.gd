# src/consumables/consumable_item.gd
extends Moddable
class_name ConsumableItem

@export_storage var id: int = -1
@export var name: String
@export var description: String
@export var icon: Texture2D
@export var disabled_icon: Texture2D
@export var cooldown_time: float = 30.0
@export var duration: float = 0.0  # 0 for instant effects
@export var max_stack: int = 3
var current_stack: int = 1

enum ConsumableType {
	HEAL,
	DAMAGE_CONTROL,
	RADAR_BOOST,
	REPAIR_PARTY,
	SMOKE_SCREEN,
	HYDROACOUSTIC_SEARCH,
	RADAR,
}

@export var type: ConsumableType

# Override in specific consumable types
func apply_effect(ship: Ship) -> void:
	pass
func remove_effect(ship: Ship) -> void:
	pass

func can_use(ship: Ship) -> bool:
	return true

func _proc(_delta: float, ship :Ship):
	pass

# Tooltip / popup-hint text shown when hovering this consumable's UI button.
# Subclasses can override _get_stat_lines() to append type-specific stats
# without rewriting the common header (name/description/cooldown/...).
# Pass a ConsumableManager to include live status (active/cooldown remaining
# and current charges) — used when the tooltip is rebuilt every physics frame.
func get_tooltip_text(manager: ConsumableManager = null) -> String:
	var lines := [name]
	if description != "":
		lines.append("")
		lines.append(description)
	lines.append("")
	var _p := self.p() as ConsumableItem
	lines.append("Cooldown: %.0f s" % _p.cooldown_time)
	if _p.duration > 0.0:
		lines.append("Duration: %.0f s" % _p.duration)
	else:
		lines.append("Duration: instant")
	if max_stack == -1:
		lines.append("Charges: ∞")
	else:
		lines.append("Charges: %d / %d" % [current_stack, max_stack])
	var stat_lines := _get_stat_lines(manager.ship if manager != null else null)
	if stat_lines.size() > 0:
		lines.append("")
		lines.append_array(stat_lines)
	if manager != null:
		var remaining_cooldown: float = manager.cooldowns.get(id, 0.0)
		var active_remaining: float = manager.active_effects.get(id, 0.0)
		if active_remaining > 0.0:
			lines.append("")
			lines.append("Active: %.0f s remaining" % active_remaining)
		elif remaining_cooldown > 0.0:
			lines.append("")
			lines.append("Reloading: %.0f s remaining" % remaining_cooldown)
	return "\n".join(PackedStringArray(lines))

# Override in subclasses to add type-specific stat lines (without header).
# `ship` is provided when the tooltip is rebuilt live (every physics frame),
# allowing subclasses to show values that depend on the ship's current stats.
func _get_stat_lines(_ship: Ship = null) -> Array[String]:
	return []


func to_dict() -> Dictionary:
	return {
		"id": id,
		"cooldown_time": cooldown_time,
		"duration": duration,
		"max_stack": max_stack,
		"current_stack": current_stack,
		"type": type
	}

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()

	writer.put_32(id)
	writer.put_double(cooldown_time)
	writer.put_double(duration)
	writer.put_32(max_stack)
	writer.put_32(current_stack)
	writer.put_32(type)

	return writer.data_array

func from_dict(data: Dictionary) -> void:
	id = data.get("id", id)
	cooldown_time = data.get("cooldown_time", cooldown_time)
	duration = data.get("duration", duration)
	max_stack = data.get("max_stack", max_stack)
	current_stack = data.get("current_stack", current_stack)

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	id = reader.get_32()
	cooldown_time = reader.get_double()
	duration = reader.get_double()
	max_stack = reader.get_32()
	current_stack = reader.get_32()
	type = reader.get_32() as ConsumableType
