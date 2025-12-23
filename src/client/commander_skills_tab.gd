# src/client/commander_skills_tab.gd
extends Control

var selected_ship: Ship = null
@onready var skill_grid = $VBoxContainer/ScrollContainer/GridContainer

signal skill_toggled(skill_path: String, enabled: bool)


func set_ship(ship: Ship):
	selected_ship = ship
	_update_skill_buttons()

func _update_skill_buttons():
	for button in skill_grid.get_children():
		if button is SkillButton:
			button.button_pressed = false
			var button_uid = ResourceUID.text_to_id(button.skill)
			for skill: Skill in selected_ship.get_skills().skills:
				# Get the script path from the skill instance
				var skill_script_path = skill.get_script().resource_path if skill.get_script() else ""
				var skill_uid = ResourceLoader.get_resource_uid(skill_script_path)
				# var uid = ResourceUID.text_to_id(skill_uid)

				# print("Comparing skill script path '", skill_script_path, "' to button script path '", button_script_path, "'")
				if skill_uid == button_uid and button.skill != "":
					# print("Skill matched: ", skill_script_path)
					button.button_pressed = true
					break


func _ready():
	# Update button states based on ship's current skills
	for button in skill_grid.get_children():
		if button is SkillButton:
			button.toggled.connect(func (toggled):
				_on_skill_toggled(toggled, button)
			)

# Separate function to handle skill toggling
func _on_skill_toggled(toggled: bool, button: SkillButton):
	if selected_ship == null or button.skill == "":
		return

	var skill_resource = load(button.skill)
	if skill_resource == null:
		print("Failed to load skill resource: ", button.skill)
		return
	
	var skill_instance = skill_resource.new()
	if skill_instance is Skill:
		if toggled:
			selected_ship.get_skills().add_skill(skill_instance)
		else:
			selected_ship.get_skills().remove_skill(skill_instance)
		# Emit signal to inform other parts of the UI
		skill_toggled.emit(button.skill, toggled)
