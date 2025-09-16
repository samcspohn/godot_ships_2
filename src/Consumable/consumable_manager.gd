# src/ship/consumable_manager.gd
extends Node
class_name ConsumableManager

var ship: Ship
@export var equipped_consumables: Array[ConsumableItem] = [] # not null, dynamic sized
var cooldowns: Dictionary = {}  # item_id -> remaining_time
var active_effects: Dictionary = {}  # item_id -> remaining_duration

signal consumable_used(item: ConsumableItem)
signal consumable_ready(item: ConsumableItem)

func _ready():
	# ship = get_parent().get_parent()
	var i = 0
	for item in equipped_consumables:
		item.id = i
		item.current_stack = item.max_stack
		if item.max_stack == -1:
			item.current_stack = 1  # Infinite uses, but show as 1
		i += 1


func _process(delta):
	if !multiplayer.is_server():
		return
	update_cooldowns(delta)
	update_active_effects(delta)
	if ship and ship.team and !ship.team.is_bot:
		var _equipped = []
		for item in equipped_consumables:
			if item:
				_equipped.append(item.to_dict())
		_sync.rpc_id(int(ship.name), {
			"cooldowns": cooldowns,
			"active_effects": active_effects,
			"equipped_consumables": _equipped
		})

func equip_consumable(item: ConsumableItem, slot: int):
	if slot < equipped_consumables.size():
		equipped_consumables[slot] = item

func use_consumable(slot: int) -> bool:
	if slot >= equipped_consumables.size():
		return false
	
	var item = equipped_consumables[slot]
	if not item or not can_use_item(item):
		return false
	
	# Apply effect
	item.apply_effect(ship)
	if item.max_stack != -1:
		item.current_stack -= 1

	# Track duration if applicable
	if item.duration > 0:
		active_effects[item.id] = item.duration
	
	consumable_used.emit(item)
	return true

func can_use_item(item: ConsumableItem) -> bool:
	return (item.current_stack > 0 or item.max_stack == -1) and cooldowns.get(item.id, 0.0) <= 0.0 and active_effects.get(item.id, 0.0) <= 0.0 and item.can_use(ship)

func update_cooldowns(delta: float):
	for item_id in cooldowns:
		cooldowns[item_id] -= delta
		if cooldowns[item_id] <= 0:
			cooldowns.erase(item_id)
			# Find item and emit ready signal
			for item in equipped_consumables:
				if item and item.id == item_id:
					consumable_ready.emit(item)

func update_active_effects(delta: float):
	for item_id in active_effects:
		active_effects[item_id] -= delta
		if active_effects[item_id] <= 0:
			active_effects.erase(item_id)
			equipped_consumables[item_id].remove_effect(ship)
			if equipped_consumables[item_id].current_stack > 0 or equipped_consumables[item_id].max_stack == -1:
				# Only reset cooldown if there are remaining uses
				cooldowns[item_id] = equipped_consumables[item_id].cooldown_time
			# Remove effect (implement in specific consumables)

@rpc("any_peer", "call_local", "reliable")
func use_consumable_rpc(slot: int):
	if multiplayer.is_server():
		use_consumable(slot)
	
@rpc("authority", "call_remote", "unreliable_ordered")
func _sync(data: Dictionary):
	cooldowns = data.get("cooldowns", cooldowns)
	active_effects = data.get("active_effects", active_effects)
	var _equipped = data.get("equipped_consumables", [])

	for i in range(_equipped.size()):
		equipped_consumables[i].from_dict(_equipped[i])
