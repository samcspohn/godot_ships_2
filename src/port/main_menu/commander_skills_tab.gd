# src/client/commander_skills_tab.gd
extends Control

var selected_ship = null
@onready var skill_grid: GridContainer = $VBoxContainer/HBoxContainer/ScrollContainer/GridContainer
@onready var tooltip_label: RichTextLabel = $VBoxContainer/HBoxContainer/InfoPanel/MarginContainer/InfoContent/TooltipLabel
@onready var variable_section: VBoxContainer = $VBoxContainer/HBoxContainer/InfoPanel/MarginContainer/InfoContent/VariableSection

signal skill_toggled(skill_id: String, enabled: bool)
## Emitted when a variable-skill control changes value.
## main_menu_ui.gd connects this to stats_panel.refresh().
signal preview_state_changed

func set_ship(ship: Ship):
	selected_ship = ship
	_update_skill_buttons()
	_rebuild_variable_section()

func _update_skill_buttons():
	for button in skill_grid.get_children():
		if button is SkillButton:
			button.set_pressed_no_signal(false)
			if button.skill_id == "":
				continue
			if selected_ship.skills.has_skill_id(button.skill_id):
				button.set_pressed_no_signal(true)

func _ready():
	for button in skill_grid.get_children():
		if button is SkillButton:
			button.toggled.connect(_on_skill_toggled.bind(button))
			button.mouse_entered.connect(_on_skill_button_hovered.bind(button))
			button.mouse_exited.connect(_on_skill_button_unhovered.bind(button))

func _on_skill_toggled(toggled: bool, button: SkillButton) -> void:
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
	skill_toggled.emit(button.skill_id, toggled)
	_rebuild_variable_section()

# ── Hover tooltip ─────────────────────────────────────────────────────────────

func _on_skill_button_hovered(button: SkillButton) -> void:
	if button.skill_id == "":
		tooltip_label.text = ""
		return
	var applied: Skill = null
	if selected_ship != null:
		applied = selected_ship.skills.skills.get(button.skill_id)
	var skill: Skill = applied if applied != null else SkillsRegistry.create_skill(button.skill_id)
	tooltip_label.text = skill.get_tooltip_bbcode() if skill != null else ""

func _on_skill_button_unhovered(_button: SkillButton) -> void:
	tooltip_label.text = ""

# ── Persistent variable controls ─────────────────────────────────────────────

## Rebuilds the always-visible variable-controls section from the ship's
## currently equipped skills. Called on ship change and skill toggle.
func _rebuild_variable_section() -> void:
	for child in variable_section.get_children():
		child.queue_free()

	if selected_ship == null:
		return

	for skill_id in selected_ship.skills.skills:
		var skill: Skill = selected_ship.skills.skills[skill_id]

		# Probe whether this skill produces any variable controls.
		var probe := VBoxContainer.new()
		skill.build_preview_modal(probe, func() -> void:
			preview_state_changed.emit()
		)
		if probe.get_child_count() == 0:
			probe.queue_free()
			continue

		# Header label with the skill's name.
		var header := Label.new()
		header.text = skill.name
		variable_section.add_child(header)

		# Move the controls out of the probe into the section.
		for child in probe.get_children():
			probe.remove_child(child)
			variable_section.add_child(child)
		probe.queue_free()

		variable_section.add_child(HSeparator.new())
