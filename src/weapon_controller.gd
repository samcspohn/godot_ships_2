extends Node
class_name WeaponController

var _ship: Ship
# var select_held: bool = false
var held: Array[bool] = []

# var buttons: Array[Button]
# var curr_button: Button
# var switch_progress: Array[ProgressBar]

# var held_duration: float = 0.0
var switched_shell: bool = false
# var button_key: int = -1
var button_keys: Array[int] = []
# var shell_index: int = 1
# var pressed_time: float = 0.0
# var select_held: bool = false
var buttons: Array[Button] = []
# var button_keys: Array[int] = []
var switch_progresss: Array[ProgressBar] = []
# Yellow "not available yet" overlay drawn on top of each button, driven by
# get_button_cooldown() below. Unused (and invisible) unless a subclass
# overrides that hook - see AviationController's launch cooldowns.
var cooldown_progresss: Array[ProgressBar] = []
# var held: Array[bool] = []
var held_dur: Array[float] = []

var shell_index: int = 1
var multi_select: bool = false
# used with multi_select
var shell_indices: Array[int] = []

@export var button_names: Array[String] = []
var tool_tips: Array[Callable] = []

var frame_count: int = 0
func _input(event: InputEvent) -> void:
	if _ship.control is not PlayerController or _ship.peer_id != multiplayer.get_unique_id() and frame_count < 1:
		set_process_input(false)
		frame_count	+= 1
		return
	if event is InputEventKey:
		if event.pressed and not event.echo:
			for i in range(button_keys.size()):
				if event.keycode == Key.KEY_1 + button_keys[i]:
					held[i] = true
					# pressed_time = Time.get_ticks_msec() / 1000.0
		elif !event.pressed and not event.echo:
			for i in range(button_keys.size()):
				if event.keycode == Key.KEY_1 + button_keys[i]:
					if held_dur[i] < 0.2 and held_dur[i] > 0.0: # pressed for less than 0.2 seconds, treat as a tap
						_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
						select_shell.rpc_id(1, i)
					held[i] = false
					switched_shell = false

func get_weapon_ui(offset: int) -> Array[Button]:
	var ui_buttons: Array[Button] = []
	for i in range(button_names.size()):
		var button = Button.new()
		button.text = button_names[i]
		button.set_meta("tooltip_provider", tool_tips[i])
		button.button_down.connect(func():
			held[i] = true
		)
		button.pressed.connect(func():
			_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
			select_shell.rpc_id(1, i)
		)
		button.button_up.connect(func():
			held[i] = false
			switched_shell = false
		)
		var cooldown_progress = _make_cooldown_bar(button)
		button.add_child(cooldown_progress)

		var switch_progress = ProgressBar.new()
		switch_progress.min_value = 0.0
		switch_progress.max_value = 1.0
		switch_progress.value = 0.0
		switch_progress.show_percentage = false
		switch_progress.set_anchors_preset(Control.PRESET_FULL_RECT)
		switch_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
		switch_progress.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP

		button.add_child(switch_progress)
		var key_label = Label.new()
		key_label.text = str(offset + i + 1)
		key_label.position = Vector2(4, 2)
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key_label.add_theme_font_size_override("font_size", 12)
		key_label.modulate = Color(1, 1, 1, 0.7)
		button.add_child(key_label)
		buttons.append(button)
		button_keys.append(offset + i)
		switch_progresss.append(switch_progress)
		cooldown_progresss.append(cooldown_progress)
		held.append(false)
		held_dur.append(0.0)
		# button.name = "WeaponButton" + str(i + offset)
		ui_buttons.append(button)
	return ui_buttons


const COOLDOWN_COLOR := Color(1.0, 0.82, 0.12, 0.45)
# Alpha every cooldown colour is drawn at, so an overridden one still reads as
# part of the button rather than a panel over it.
const COOLDOWN_ALPHA: float = 0.45
# Fallback corner radius, used only if the button's own style is not a
# StyleBoxFlat to read the real radius off (see _button_corner_radius).
const COOLDOWN_CORNER_RADIUS: int = 3
# Tint applied to a button whose weapon cannot be used right now (self_modulate
# rather than modulate so the cooldown bar on top of it stays bright).
const UNAVAILABLE_TINT := Color(0.5, 0.5, 0.5, 1.0)

# Corner radius of the button's own background, so anything overlaid on top of
# it can be rounded off to match instead of poking out past its corners.
static func _button_corner_radius(button: Button) -> int:
	var style := button.get_theme_stylebox("normal") as StyleBoxFlat
	if style == null:
		return COOLDOWN_CORNER_RADIUS
	return style.corner_radius_bottom_left

# Yellow bar filling from the bottom of a weapon button, showing how much of
# the current cooldown is left. Kept transparent-backgrounded, and rounded to
# the button's own corner radius, so it reads as part of the button rather
# than a square overlay on top of it.
func _make_cooldown_bar(button: Button) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = 0.0
	bar.visible = false
	bar.show_percentage = false
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	bar.add_theme_stylebox_override("background", background)
	var fill := StyleBoxFlat.new()
	fill.bg_color = COOLDOWN_COLOR
	bar.add_theme_stylebox_override("fill", fill)
	_match_button_corners(bar, button)
	# The button is not in the scene tree yet, so the radius just applied comes
	# from the default theme - redo it once it is parented, in case a theme
	# inherited from an ancestor rounds its corners differently.
	button.tree_entered.connect(_match_button_corners.bind(bar, button))
	return bar

# Rounds a bar overlaid on `button` to the button's own corner radius.
func _match_button_corners(bar: ProgressBar, button: Button) -> void:
	var radius := _button_corner_radius(button)
	(bar.get_theme_stylebox("background") as StyleBoxFlat).set_corner_radius_all(radius)
	(bar.get_theme_stylebox("fill") as StyleBoxFlat).set_corner_radius_all(radius)

# ── per-button availability hooks ───────────────────────────────────────────
# Default to "always ready, no cooldown"; subclasses that have one override
# these (see AviationController).

## 0..1 share of this button's cooldown still to run; 0 hides the bar.
func get_button_cooldown(_index: int) -> float:
	return 0.0

## false dims the button to show the weapon cannot be used yet.
func is_button_ready(_index: int) -> bool:
	return true

## Colour of this button's cooldown bar, re-read every frame so one bar can say
## what KIND of wait it is showing rather than needing one bar per kind (see
## AviationController, where the same bar is a sortie, a rearm or a deck wait).
func get_button_cooldown_color(_index: int) -> Color:
	return COOLDOWN_COLOR


func update_weapon_ui(delta: float) -> void:
	for i in range(buttons.size()):
		var button = buttons[i]
		var switch_progress = switch_progresss[i]
		if held[i]:
			held_dur[i] += delta
			button.button_pressed = true
		else:
			# if held_dur[i] < 0.2 and held_dur[i] > 0.0: # pressed for less than 0.2 seconds, treat as a tap
			# 	_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
			# 	select_shell.rpc_id(1, i)
			held_dur[i] = 0.0
			if _ship.get_node("Modules/PlayerControl").current_weapon_controller == self and (shell_index == i if !multi_select else i in shell_indices):
				button.button_pressed = true
			else:
				button.button_pressed = false
		var cooldown_progress = cooldown_progresss[i]
		if cooldown_progress:
			var cooldown := get_button_cooldown(i)
			cooldown_progress.value = cooldown
			cooldown_progress.visible = cooldown > 0.0
			if cooldown_progress.visible:
				var fill := cooldown_progress.get_theme_stylebox("fill") as StyleBoxFlat
				var color := get_button_cooldown_color(i)
				if fill != null and fill.bg_color != color:
					fill.bg_color = color
		button.self_modulate = Color.WHITE if is_button_ready(i) else UNAVAILABLE_TINT
		if switch_progress and not switched_shell:
			switch_progress.value = min(held_dur[i], 1.0)
		if held_dur[i] > 1.0 and not switched_shell:
			select_shell.rpc_id(1, i)
			switched_shell = true


func _process(delta: float) -> void:
	update_weapon_ui(delta)

@rpc("any_peer", "call_remote", "reliable")
func select_shell(_shell_index: int) -> void:
	if !(_Utils.authority()):
		return
	shell_index = clamp(_shell_index, 0, button_names.size() - 1)
	if multi_select:
		shell_indices.clear()
		shell_indices.append(shell_index)
		# if shell_index in shell_indices:
		# 	shell_indices.erase(shell_index)
		# else:
		# 	shell_indices.append(shell_index)
	select_shell_c.rpc_id(multiplayer.get_remote_sender_id(), shell_index)



# todo: only broadcast if shooting or detected
@rpc("authority", "call_remote", "reliable")
func select_shell_c(_shell_index: int) -> void:
	shell_index = _shell_index
	if multi_select:
		shell_indices.clear()
		shell_indices.append(shell_index)
		# if shell_index in shell_indices:
		# 	shell_indices.erase(shell_index)
		# else:
		# 	shell_indices.append(shell_index)

# Replaces the whole multi-select set at once instead of toggling a single
# index (select_shell above) - used by box-select drag selection.
@rpc("any_peer", "call_remote", "reliable")
func set_shell_indices(indices: Array[int]) -> void:
	if !(_Utils.authority()):
		return
	if not multi_select:
		return
	var clamped: Array[int] = []
	for idx in indices:
		if idx >= 0 and idx < button_names.size() and idx not in clamped:
			clamped.append(idx)
	shell_indices = clamped
	set_shell_indices_c.rpc_id(multiplayer.get_remote_sender_id(), clamped)

@rpc("authority", "call_remote", "reliable")
func set_shell_indices_c(indices: Array[int]) -> void:
	shell_indices = indices
