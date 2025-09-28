extends Node
class_name SkillsManager

@export var skills: Array[Skill] = []
var _ship: Ship = null

func add_skill(skill: Skill) -> void:
	if skill in skills:
		return
	skills.append(skill)
	skill.apply(_ship)

func remove_skill(skill: Skill) -> void:
	if skill not in skills:
		return
	skills.erase(skill)
	skill.remove(_ship)

func has_skill(skill: Skill) -> bool:
	return skill in skills
