extends Node
class_name Upgrades
@export var upgrades: Array[Upgrade] = []

func add_upgrade(slot_index: int, upgrade: Upgrade) -> void:
	if upgrade == null:
		push_error("Trying to add null upgrade")
		return
		
	print("Upgrades: Adding upgrade: ", upgrade.name)
	print("Upgrades: Before adding, array has ", upgrades.size(), " upgrades")
	
	# Check if the upgrade is already in the array
	# var existing_index = -1
	# for i in range(upgrades.size()):
	# 	if upgrades[i] == upgrade:
	# 		existing_index = i
	# 		break
			
	# # If it's not already in the array, add it to the first empty slot or append
	# if existing_index == -1:
	# 	var empty_slot = -1
	# 	for i in range(upgrades.size()):
	# 		if upgrades[i] == null:
	# 			empty_slot = i
	# 			break
				
	# 	if empty_slot != -1:
	# 		# Add to first empty slot
	# 		print("Upgrades: Adding to empty slot ", empty_slot)
	# 		upgrades[empty_slot] = upgrade
	# 	else:
	# 		# Append to the end
	# 		print("Upgrades: Appending to end")
	# 		upgrades.append(upgrade)
	upgrades[slot_index] = upgrade
	# else:
	# 	print("Upgrades: Upgrade already exists at index ", existing_index)
		
	# print("Upgrades: After adding, array has ", upgrades.size(), " upgrades")

func remove_upgrade(slot_index: int) -> void:
	# if upgrade and upgrades.has(upgrade):
	# 	upgrades.erase(upgrade)
	upgrades[slot_index] = null

func get_upgrade(slot_index: int) -> Upgrade:
	if slot_index >= 0 and slot_index < upgrades.size():
		return upgrades[slot_index]
	return null
