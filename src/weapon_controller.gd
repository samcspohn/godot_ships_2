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
## The hold already selected this button's shell; its release must not select it again (that forces the switch).
var _held_selected: Array[bool] = []

# The selected weapon, for controllers that only ever have one selected at a
# time. MEANINGLESS when multi_select is on - read selected_indices() instead,
# never this. A multi-select controller's selection lives solely in
# shell_indices; letting shell_index shadow it is how a box-selected squadron
# ended up being aimed and launched with a different squadron's parameters.
var shell_index: int = 1
# Temporary diagnostic for the box-select/aim-UI bug - see
# PlayerController.BOX_SELECT_DEBUG. Remove once the cause is pinned down.
const SHELL_INDEX_DEBUG: bool = false
var multi_select: bool = false
# used with multi_select
var shell_indices: Array[int] = []

# The current selection, whichever mode this controller is in - the one thing
# every caller should read rather than picking shell_index or shell_indices
# themselves.
func selected_indices() -> Array[int]:
	if multi_select:
		return shell_indices
	var single: Array[int] = [shell_index]
	return single

## Ammo switch: every gun fires what it is loading once more, then loads the new shell. Selecting the new
## shell again switches now: a gun keeps at least this share of its reload left (1: full reload).
const SWITCH_RELOAD_LEFT: float = 1.0
## Ammo some gun still has loaded from before a switch, -1 with none; the owner's client gets it from the server.
var queued_index: int = -1
const LOADED_COLOR := Color(0.35, 0.95, 0.45, 0.9)
const QUEUED_COLOR := Color(1.0, 0.7, 0.15, 0.9)
var ammo_marks: Array[ColorRect] = []

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
					_held_selected[i] = false

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
			if _held_selected[i]:
				_held_selected[i] = false
				return
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
		var mark := ColorRect.new()
		mark.set_anchors_preset(Control.PRESET_TOP_WIDE)
		mark.offset_bottom = 3.0
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark.visible = false
		button.add_child(mark)
		ammo_marks.append(mark)
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
		_held_selected.append(false)
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
		if i < ammo_marks.size():
			var loaded := next_index()
			ammo_marks[i].visible = not ammo_guns().is_empty() and (i == loaded or i == shell_index)
			ammo_marks[i].color = LOADED_COLOR if i == loaded else QUEUED_COLOR
		if switch_progress and not switched_shell:
			switch_progress.value = min(held_dur[i], 1.0)
		if held_dur[i] > 1.0 and not switched_shell:
			select_shell_now.rpc_id(1, i)
			switched_shell = true
			_held_selected[i] = true


func _process(delta: float) -> void:
	update_weapon_ui(delta)

@rpc("any_peer", "call_remote", "reliable")
func select_shell(_shell_index: int) -> void:
	if !(_Utils.authority()):
		return
	_select(_shell_index, false)


## The hold-to-select: switches at once, as selecting the queued shell again does.
@rpc("any_peer", "call_remote", "reliable")
func select_shell_now(_shell_index: int) -> void:
	if !(_Utils.authority()):
		return
	_select(_shell_index, true)


func _select(i: int, now: bool) -> void:
	var idx: int = clamp(i, 0, button_names.size() - 1)
	if not multi_select:
		_switch_guns(shell_index, idx)
		if now:
			_switch_guns(idx, idx)
	_apply_selection(idx)
	_sync_queue()
	select_shell_c.rpc_id(multiplayer.get_remote_sender_id(), idx)


## Guns whose shell an ammo switch changes; none for weapons without one.
func ammo_guns() -> Array:
	return []


## The ammo the next shot fires: what is still loaded from before a switch, else the selection.
func next_index() -> int:
	return queued_index if queued_index >= 0 else shell_index


func _switch_guns(from: int, to: int) -> void:
	for g in ammo_guns():
		if from == to:
			if g.loaded >= 0 and g.loaded != to:
				g.reload = minf(g.reload, 1.0 - SWITCH_RELOAD_LEFT)
				g.loaded = -1
			continue
		if g.loaded < 0:
			g.loaded = from
		if g.loaded == to:
			g.loaded = -1


## The queued salvo is going out: guns holding the old shell that cannot fire with it switch now.
func _force_stragglers() -> void:
	for g in ammo_guns():
		if g.loaded >= 0 and g.loaded != shell_index and not (g.reload >= 1.0 and g.can_fire and not g.disabled):
			g.reload = minf(g.reload, 1.0 - SWITCH_RELOAD_LEFT)
			g.loaded = -1


## Server: recompute queued_index after a switch or a shot, and tell the owning player.
func _sync_queue() -> void:
	var q := -1
	for g in ammo_guns():
		if g.loaded >= 0 and g.loaded != shell_index and not g.disabled:
			q = g.loaded
			break
	if q == queued_index:
		return
	queued_index = q
	if _ship != null and multiplayer.get_peers().has(_ship.peer_id):
		set_queued_c.rpc_id(_ship.peer_id, q)


@rpc("authority", "call_remote", "reliable")
func set_queued_c(q: int) -> void:
	queued_index = q


## A single click while a switch is queued fires everything loaded, WoWS style.
func fires_full_salvo() -> bool:
	return queued_index >= 0



# todo: only broadcast if shooting or detected
@rpc("authority", "call_remote", "reliable")
func select_shell_c(_shell_index: int) -> void:
	_apply_selection(_shell_index)

# Selects a single index. In multi_select mode the selection lives entirely in
# shell_indices and shell_index is left untouched - see selected_indices().
func _apply_selection(idx: int) -> void:
	if multi_select:
		var single: Array[int] = [idx]
		shell_indices = single
	else:
		shell_index = idx

# Replaces the whole multi-select set at once instead of toggling a single
# index (select_shell above) - used by box-select drag selection.
func _apply_shell_indices(indices: Array[int]) -> void:
	shell_indices = indices

func _clamp_shell_indices(indices: Array[int]) -> Array[int]:
	var clamped: Array[int] = []
	for idx in indices:
		if idx >= 0 and idx < button_names.size() and idx not in clamped:
			clamped.append(idx)
	return clamped

@rpc("any_peer", "call_remote", "reliable")
func set_shell_indices(indices: Array[int]) -> void:
	if !(_Utils.authority()):
		if SHELL_INDEX_DEBUG:
			print("[shellidx] set_shell_indices ignored (not authority) ", indices)
		return
	if not multi_select:
		if SHELL_INDEX_DEBUG:
			print("[shellidx] set_shell_indices ignored (not multi_select) ", indices)
		return
	var clamped := _clamp_shell_indices(indices)
	_apply_shell_indices(clamped)
	if SHELL_INDEX_DEBUG:
		print("[shellidx] server applied %s -> echoing to %d" % [clamped, multiplayer.get_remote_sender_id()])
	set_shell_indices_c.rpc_id(multiplayer.get_remote_sender_id(), clamped)

@rpc("authority", "call_remote", "reliable")
func set_shell_indices_c(indices: Array[int]) -> void:
	if SHELL_INDEX_DEBUG:
		print("[shellidx] client received %s (was %s)" % [indices, shell_indices])
	_apply_shell_indices(indices)
