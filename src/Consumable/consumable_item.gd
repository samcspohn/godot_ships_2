# src/consumables/consumable_item.gd
extends Moddable
class_name ConsumableItem

var id: int = -1
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
	SMOKE_SCREEN
}

@export var type: ConsumableType

# Override in specific consumable types
func apply_effect(ship: Ship) -> void:
	pass
func remove_effect(ship: Ship) -> void:
	pass

func can_use(ship: Ship) -> bool:
	return true

func to_dict() -> Dictionary:
	return {
		"id": id,
		"cooldown_time": cooldown_time,
		"duration": duration,
		"max_stack": max_stack,
		"current_stack": current_stack,
		"type": type
	}
func from_dict(data: Dictionary) -> void:
	id = data.get("id", id)
	cooldown_time = data.get("cooldown_time", cooldown_time)
	duration = data.get("duration", duration)
	max_stack = data.get("max_stack", max_stack)
	current_stack = data.get("current_stack", current_stack)
