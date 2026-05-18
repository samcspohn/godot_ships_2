# src/client/commander_skills_tab.gd
extends Control

var selected_ship = null
@onready var skill_grid = $VBoxContainer/ScrollContainer/GridContainer

signal skill_toggled(skill_id: String, enabled: bool)
## Emitted whenever a preview slider/spinner changes value.
## main_menu_ui.gd connects this to stats_panel.refresh().
signal preview_state_changed

var _preview_popup: PopupPanel = null

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
	for button in skill_grid.get_children():
		if button is SkillButton:
			button.toggled.connect(_on_skill_toggled.bind(button))
			button.gui_input.connect(_on_skill_button_gui_input.bind(button))

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

	skill_toggled.emit(button.skill_id, toggled)

func _on_skill_button_gui_input(event: InputEvent, button: SkillButton) -> void:
	if not (event is InputEventMouseButton):
		return
	var mbe := event as InputEventMouseButton
	if mbe.button_index != MOUSE_BUTTON_RIGHT or not mbe.pressed:
		return
	if not button.button_pressed:
		return  # Only show preview for active skills
	if selected_ship == null or button.skill_id == "":
		return
	var skill: Skill = selected_ship.skills.skills.get(button.skill_id)
	if skill == null:
		return
	_show_preview_popup(button, skill)

func _show_preview_popup(anchor: Control, skill: Skill) -> void:
	# Close any existing popup first
	if _preview_popup != null and is_instance_valid(_preview_popup):
		_preview_popup.queue_free()
		_preview_popup = null

	var popup := PopupPanel.new()
	_preview_popup = popup

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 10)
	popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(240, 0)
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = skill.name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	skill.build_preview_modal(vbox, func() -> void:
		preview_state_changed.emit()
	)

	popup.popup_hide.connect(func() -> void:
		_preview_popup = null
	)

	get_tree().root.add_child(popup)
	popup.reset_size()

	var btn_screen := anchor.get_screen_position()
	var btn_size := anchor.size
	popup.position = Vector2i(int(btn_screen.x + btn_size.x + 4), int(btn_screen.y))
	popup.popup()
