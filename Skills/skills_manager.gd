extends Node
class_name SkillsManager

@export var skills: Dictionary[String, Skill] = {}
var _ship: Ship = null

func add_skill(skill: Skill) -> void:
	# print("SkillsManager.add_skill: skill_id='", skill.skill_id, "' _ship=", _ship, " already_exists=", skill.skill_id in skills)
	if skill.skill_id in skills:
		# print("SkillsManager.add_skill: SKIPPED duplicate skill_id='", skill.skill_id, "'")
		return
	skills[skill.skill_id] = skill
	skill.apply(_ship)
	# print("SkillsManager.add_skill: ADDED skill_id='", skill.skill_id, "' skills now=", skills.keys())

func remove_skill(skill: Skill) -> void:
	remove_skill_by_id(skill.skill_id)

func remove_skill_by_id(id: String) -> void:
	if id not in skills:
		return
	var skill = skills[id]
	skills.erase(id)
	skill.remove(_ship)

func has_skill(skill: Skill) -> bool:
	return skill.skill_id in skills

func has_skill_id(id: String) -> bool:
	return id in skills

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_8(skills.size())
	for id in skills:
		writer.put_var(id)
		writer.put_var(skills[id].to_bytes())

	return writer.get_data_array()

func from_bytes(data: PackedByteArray):
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	var num_skills = reader.get_8()
	for i in range(num_skills):
		var skill_id = reader.get_var()
		var skill_data: PackedByteArray = reader.get_var()
		if not skill_id in skills:
			skills[skill_id] = SkillsRegistry.create_skill(skill_id)
		skills[skill_id].from_bytes(skill_data)
