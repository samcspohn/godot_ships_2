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
	ship = get_parent().get_parent()

	var i = 0
	for item in equipped_consumables:
		# if item:
		item.init(ship)
		item.id = i
		i += 1
		if (item.base as ConsumableItem).max_stack == -1:
			item.current_stack = 1  # Infinite uses, but show as 1
		else:
			item.current_stack = item.max_stack
	if _Utils.authority():
		set_physics_process(true)
	else:
		set_physics_process(false)


func to_dict() -> Dictionary:
	var equipped_list = []
	for item in equipped_consumables:
		if item:
			equipped_list.append(item.to_dict())
		else:
			equipped_list.append(null)
	return {
		"equipped_consumables": equipped_list,
		"cooldowns": cooldowns,
		"active_effects": active_effects
	}

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()

	# Equipped consumables
	writer.put_32(equipped_consumables.size())
	for item in equipped_consumables:
		if item:
			var item_bytes = item.to_bytes()
			writer.put_var(item_bytes)
		else:
			writer.put_var(null)

	# Cooldowns
	writer.put_32(cooldowns.size())
	for item_id in cooldowns.keys():
		writer.put_32(item_id)
		writer.put_double(cooldowns[item_id])

	# Active effects
	writer.put_32(active_effects.size())
	for item_id in active_effects.keys():
		writer.put_32(item_id)
		writer.put_double(active_effects[item_id])


	return writer.data_array

func from_dict(data: Dictionary) -> void:
	var equipped_list = data.get("equipped_consumables", [])
	for i in range(equipped_list.size()):
		if i < equipped_consumables.size() and equipped_list[i]:
			equipped_consumables[i].from_dict(equipped_list[i])
	cooldowns = data.get("cooldowns", {})
	active_effects = data.get("active_effects", {})

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	# Equipped consumables
	var equipped_size = reader.get_32()
	for i in range(equipped_size):
		var item_bytes = reader.get_var()
		if i < equipped_consumables.size() and item_bytes:
			equipped_consumables[i].from_bytes(item_bytes)

	# Cooldowns
	var cooldowns_size = reader.get_32()
	cooldowns = {}
	for i in range(cooldowns_size):
		var item_id = reader.get_32()
		var remaining_time = reader.get_double()
		cooldowns[item_id] = remaining_time

	# Active effects
	var active_effects_size = reader.get_32()
	active_effects = {}
	for i in range(active_effects_size):
		var item_id = reader.get_32()
		var remaining_duration = reader.get_double()
		active_effects[item_id] = remaining_duration

func _physics_process(delta):
	if !(_Utils.authority()):
		return
	update_cooldowns(delta)
	update_active_effects(delta)

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
	if _Utils.authority():
		use_consumable(slot)

func get_active_icons() -> Array:
	var ret = []
	for id in active_effects:
		if id < equipped_consumables.size() and equipped_consumables[id]:
			ret.append(equipped_consumables[id].icon)
	return ret
