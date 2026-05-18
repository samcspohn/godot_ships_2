extends Button
class_name SkillButton

@export var skill_id: String

var _skill_instance: Skill = null

func _ready() -> void:
	if skill_id == "":
		return
	_skill_instance = SkillsRegistry.create_skill(skill_id)
	if _skill_instance == null:
		return
	# Non-empty tooltip_text is required to trigger _make_custom_tooltip.
	tooltip_text = " "

func _make_custom_tooltip(_for_text: String) -> Object:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.custom_minimum_size = Vector2(280, 0)
	rtl.text = _skill_instance.get_tooltip_bbcode()
	return rtl
