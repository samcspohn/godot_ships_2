# src/client/commander_skills_tab.gd
extends Control

var selected_ship = null
@onready var skill_grid = $VBoxContainer/ScrollContainer/GridContainer

signal skill_toggled(skill_id: String, enabled: bool)


func set_ship(ship: Ship):
	selected_ship = ship
	_update_skill_buttons()

func _update_skill_buttons():
	for button in skill_grid.get_children():
		if button is SkillButton:
			button.set_pressed_no_signal(false)
			if button.skill_id == "":
				continue
			if selected_ship.skills.has_skill_id(button.skill_id):
				button.set_pressed_no_signal(true)


func _ready():
	# Update button states based on ship's current skills
	for button in skill_grid.get_children():
		if button is SkillButton:
			button.toggled.connect(func (toggled):
				_on_skill_toggled(toggled, button)
			)

# Separate function to handle skill toggling
func _on_skill_toggled(toggled: bool, button: SkillButton):
	if selected_ship == null or button.skill_id == "":
		return

	if not SkillsRegistry.has_skill(button.skill_id):
		print("Unknown skill id: ", button.skill_id)
		return

	if toggled:
		var skill_instance = SkillsRegistry.create_skill(button.skill_id)
		if skill_instance is Skill:
			selected_ship.skills.add_skill(skill_instance)
	else:
		selected_ship.skills.remove_skill_by_id(button.skill_id)

	# Emit signal to inform other parts of the UI
	skill_toggled.emit(button.skill_id, toggled)
