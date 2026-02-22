extends Node
class_name Upgrades

@export var upgrades: Array[Upgrade] = []
var _ship: Ship = null

func add_upgrade(slot_index: int, upgrade: Upgrade) -> void:
	if upgrade == null:
		push_error("Upgrades: Trying to add null upgrade")
		return

	# Ensure array is large enough
	while slot_index >= upgrades.size():
		upgrades.append(null)

	# Remove existing upgrade in slot
	if upgrades[slot_index] != null:
		remove_upgrade(slot_index)

	upgrades[slot_index] = upgrade
	upgrade.apply(_ship)
	print("Upgrades: Added '", upgrade.name, "' (id=", upgrade.upgrade_id, ") to slot ", slot_index)

func remove_upgrade(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= upgrades.size():
		return
	var upgrade = upgrades[slot_index]
	if upgrade:
		upgrade.remove(_ship)
		upgrades[slot_index] = null
		print("Upgrades: Removed '", upgrade.name, "' from slot ", slot_index)

func get_upgrade(slot_index: int) -> Upgrade:
	if slot_index >= 0 and slot_index < upgrades.size():
		return upgrades[slot_index]
	return null

func get_upgrade_id(slot_index: int) -> String:
	var upgrade = get_upgrade(slot_index)
	if upgrade:
		return upgrade.upgrade_id
	return ""

func has_upgrade_id(id: String) -> bool:
	for upgrade in upgrades:
		if upgrade and upgrade.upgrade_id == id:
			return true
	return false

func find_slot_by_id(id: String) -> int:
	for i in range(upgrades.size()):
		if upgrades[i] and upgrades[i].upgrade_id == id:
			return i
	return -1
