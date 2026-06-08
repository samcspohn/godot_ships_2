extends Node

@export var _skill_scripts: Dictionary[String, Resource] = {}

## Creates and returns a new instance of the skill with the given ID.
## Returns null if the ID is not found.
func create_skill(id: String) -> Skill:
	if not _skill_scripts.has(id):
		# push_error("SkillsRegistry: Unknown skill id: " + id)
		return null
	var script: GDScript = _skill_scripts[id] as GDScript
	if script == null:
		push_error("SkillsRegistry: Resource for id '" + id + "' is not a GDScript")
		return null
	var instance: Skill = script.new()
	if instance == null:
		push_error("SkillsRegistry: Failed to instantiate skill for id: " + id)
		return null
	instance.skill_id = id
	# print("SkillsRegistry: Created skill '", id, "' -> ", instance, " skill_id=", instance.skill_id)
	return instance

## Returns all registered skill IDs.
func get_all_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.assign(_skill_scripts.keys())
	return ids

## Returns true if a skill with the given ID exists in the registry.
func has_skill(id: String) -> bool:
	return _skill_scripts.has(id)

## Creates a temporary instance of the skill to read its metadata (name, description, etc).
## Useful for UI display without needing to apply the skill to a ship.
func get_skill_info(id: String) -> Dictionary:
	var skill := create_skill(id)
	if skill == null:
		return {}
	return {
		"skill_id": skill.skill_id,
		"name": skill.name,
		"description": skill.description,
	}
