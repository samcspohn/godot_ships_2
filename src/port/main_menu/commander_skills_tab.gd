# src/client/commander_skills_tab.gd
extends Control

const SKILL_BUTTON_SCRIPT: Script = preload("res://src/port/main_menu/skill_button.gd")

const SKILL_BTN_SIZE := Vector2(150, 110)
const MAX_TIERS := 4

var selected_ship: Ship = null

@onready var skill_rows: VBoxContainer = $VBoxContainer/HBoxContainer/ScrollContainer/SkillRows
@onready var tooltip_label: RichTextLabel = $VBoxContainer/HBoxContainer/InfoPanel/MarginContainer/InfoContent/TooltipLabel
@onready var variable_section: VBoxContainer = $VBoxContainer/HBoxContainer/InfoPanel/MarginContainer/InfoContent/VariableSection
@onready var points_label: Label = $VBoxContainer/HeaderRow/PointsLabel

## Map of skill_id -> SkillButton for quick toggle/refresh.
var _buttons: Dictionary[String, Button] = {}

signal skill_toggled(skill_id: String, enabled: bool)
## Emitted when a variable-skill control changes value.
## main_menu_ui.gd connects this to stats_panel.refresh().
signal preview_state_changed

func _ready() -> void:
	_build_skill_grid()

func set_ship(ship: Ship) -> void:
	selected_ship = ship
	_refresh_buttons()
	_rebuild_variable_section()
	_refresh_points_label()

# ── Static grid construction ─────────────────────────────────────────────────

## Builds one row of SkillButtons per tier from the registry. Run once at
## _ready(); selection/enabled state is updated by _refresh_buttons().
func _build_skill_grid() -> void:
	for child in skill_rows.get_children():
		child.queue_free()
	_buttons.clear()

	# Bucket skills by tier.
	var by_tier: Dictionary[int, Array] = {}
	for id in SkillsRegistry.get_all_ids():
		var probe: Skill = SkillsRegistry.create_skill(id)
		if probe == null:
			continue
		var t := clampi(probe.tier, 1, MAX_TIERS)
		if not by_tier.has(t):
			by_tier[t] = []
		by_tier[t].append(probe)

	for tier in range(1, MAX_TIERS + 1):
		if not by_tier.has(tier):
			continue
		var skills_in_tier: Array = by_tier[tier]
		skills_in_tier.sort_custom(func(a: Skill, b: Skill) -> bool: return a.name < b.name)

		var tier_label := Label.new()
		tier_label.text = "Tier %d" % tier
		tier_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
		skill_rows.add_child(tier_label)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		skill_rows.add_child(row)

		for skill in skills_in_tier:
			var btn := _make_skill_button(skill)
			row.add_child(btn)
			_buttons[skill.skill_id] = btn

func _make_skill_button(skill: Skill) -> Button:
	var btn := Button.new()
	btn.set_script(SKILL_BUTTON_SCRIPT)
	btn.skill_id = skill.skill_id
	btn.toggle_mode = true
	btn.custom_minimum_size = SKILL_BTN_SIZE
	btn.clip_text = true
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.text = "%s\n(%d pt%s)" % [skill.name, skill.cost, "s" if skill.cost != 1 else ""]
	btn.toggled.connect(_on_skill_toggled.bind(btn))
	btn.mouse_entered.connect(_on_skill_button_hovered.bind(btn))
	btn.mouse_exited.connect(_on_skill_button_unhovered.bind(btn))
	return btn

# ── Per-ship state refresh ───────────────────────────────────────────────────

func _refresh_buttons() -> void:
	if selected_ship == null:
		return
	for skill_id in _buttons:
		var btn: Button = _buttons[skill_id]
		var probe: Skill = SkillsRegistry.create_skill(skill_id)
		if probe == null:
			continue
		var equipped := selected_ship.skills.has_skill_id(skill_id)
		var class_ok := probe.is_allowed_for_ship(selected_ship)
		var affordable := equipped or _can_afford(probe)
		var enabled := class_ok and affordable
		btn.set_pressed_no_signal(equipped and class_ok)
		btn.disabled = not enabled and not equipped
		# Visual states: dim when class-locked, slightly dim when unaffordable.
		if not class_ok:
			btn.modulate = Color(0.45, 0.45, 0.45, 1.0)
		elif not affordable and not equipped:
			btn.modulate = Color(0.7, 0.7, 0.7, 1.0)
		else:
			btn.modulate = Color(1, 1, 1, 1)

func _refresh_points_label() -> void:
	if points_label == null:
		return
	if selected_ship == null:
		points_label.text = "0 / 0 pts"
		return
	var used := selected_ship.skills.get_used_points()
	var maxp := selected_ship.max_skill_points
	points_label.text = "%d / %d pts" % [used, maxp]
	if used > maxp:
		points_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	else:
		points_label.add_theme_color_override("font_color", Color(1, 1, 1))

func _can_afford(skill: Skill) -> bool:
	if selected_ship == null:
		return true
	return selected_ship.skills.get_used_points() + skill.cost <= selected_ship.max_skill_points

# ── Toggle handling ──────────────────────────────────────────────────────────

func _on_skill_toggled(toggled: bool, button: Button) -> void:
	if selected_ship == null or button.skill_id == "":
		return
	if not SkillsRegistry.has_skill(button.skill_id):
		push_error("Unknown skill id: " + button.skill_id)
		return
	if toggled:
		var skill_instance: Skill = SkillsRegistry.create_skill(button.skill_id)
		if skill_instance == null:
			return
		if not skill_instance.is_allowed_for_ship(selected_ship):
			button.set_pressed_no_signal(false)
			return
		# Mutual exclusivity: remove other skills sharing this group first
		# (frees up their points before the budget check).
		if skill_instance.exclusive_group != "":
			_remove_conflicting_skills(skill_instance.exclusive_group, button.skill_id)
		# Budget check.
		if not _can_afford(skill_instance):
			button.set_pressed_no_signal(false)
			_refresh_buttons()
			_refresh_points_label()
			return
		selected_ship.skills.add_skill(skill_instance)
	else:
		selected_ship.skills.remove_skill_by_id(button.skill_id)
	skill_toggled.emit(button.skill_id, toggled)
	_refresh_buttons()
	_refresh_points_label()
	_rebuild_variable_section()

## Removes every installed skill in `group` except `keep_id`, and untoggles
## the corresponding buttons.
func _remove_conflicting_skills(group: String, keep_id: String) -> void:
	var to_remove: Array[String] = []
	for installed_id in selected_ship.skills.skills:
		if installed_id == keep_id:
			continue
		var installed: Skill = selected_ship.skills.skills[installed_id]
		if installed != null and installed.exclusive_group == group:
			to_remove.append(installed_id)
	for rid in to_remove:
		selected_ship.skills.remove_skill_by_id(rid)
		if _buttons.has(rid):
			_buttons[rid].set_pressed_no_signal(false)
		skill_toggled.emit(rid, false)

# ── Hover tooltip ─────────────────────────────────────────────────────────────

func _on_skill_button_hovered(button: Button) -> void:
	if button.skill_id == "":
		tooltip_label.text = ""
		return
	var applied: Skill = null
	if selected_ship != null:
		applied = selected_ship.skills.skills.get(button.skill_id)
	var skill: Skill = applied if applied != null else SkillsRegistry.create_skill(button.skill_id)
	tooltip_label.text = skill.get_tooltip_bbcode() if skill != null else ""

func _on_skill_button_unhovered(_button: Button) -> void:
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
