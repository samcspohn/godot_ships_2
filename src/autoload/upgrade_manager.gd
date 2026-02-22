extends Node

@export var _upgrade_scripts: Dictionary[String, Resource] = {}

## Creates and returns a new instance of the upgrade with the given ID.
## Returns null if the ID is not found.
func create_upgrade(id: String) -> Upgrade:
	if not _upgrade_scripts.has(id):
		push_error("UpgradeRegistry: Unknown upgrade id: " + id)
		return null
	var script: GDScript = _upgrade_scripts[id] as GDScript
	if script == null:
		push_error("UpgradeRegistry: Resource for id '" + id + "' is not a GDScript")
		return null
	var instance: Upgrade = script.new()
	if instance == null:
		push_error("UpgradeRegistry: Failed to instantiate upgrade for id: " + id)
		return null
	instance.upgrade_id = id
	return instance

## Returns all registered upgrade IDs.
func get_all_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.assign(_upgrade_scripts.keys())
	return ids

## Returns true if an upgrade with the given ID exists in the registry.
func has_upgrade(id: String) -> bool:
	return _upgrade_scripts.has(id)

## Creates a temporary instance to read metadata. Useful for UI display.
func get_upgrade_info(id: String) -> Dictionary:
	var upgrade := create_upgrade(id)
	if upgrade == null:
		return {}
	return {
		"upgrade_id": upgrade.upgrade_id,
		"name": upgrade.name,
		"description": upgrade.description,
		"icon": upgrade.icon,
	}

## Returns metadata for all registered upgrades. Useful for populating UI lists.
func get_all_upgrade_info() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id in _upgrade_scripts:
		var info = get_upgrade_info(id)
		if not info.is_empty():
			result.append(info)
	return result
