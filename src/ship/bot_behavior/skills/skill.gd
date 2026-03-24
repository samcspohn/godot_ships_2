class_name BotSkill
extends RefCounted

## Execute the skill and return a NavIntent, or null if not applicable.
func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	return null

## Optional: return true if the skill has "arrived" or completed its objective.
func is_complete(ctx: SkillContext) -> bool:
	return false

## Optional: reset internal state when the skill is selected fresh.
func reset() -> void:
	pass
