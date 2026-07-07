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
# var held: Array[bool] = []
var held_dur: Array[float] = []

var shell_index: int = 1

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
					# if Time.get_ticks_msec() / 1000.0 - pressed_time < 0.2:
					# 	_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
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
		var switch_progress = ProgressBar.new()
		switch_progress.min_value = 0.0
		switch_progress.max_value = 1.0
		switch_progress.value = 0.0
		switch_progress.show_percentage = false
		switch_progress.set_anchors_preset(Control.PRESET_FULL_RECT)
		switch_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
		switch_progress.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP

		button.add_child(switch_progress)
		buttons.append(button)
		button_keys.append(offset + i)
		switch_progresss.append(switch_progress)
		held.append(false)
		held_dur.append(0.0)
		# button.name = "WeaponButton" + str(i + offset)
		ui_buttons.append(button)
	return ui_buttons


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
			if _ship.get_node("Modules/PlayerControl").current_weapon_controller == self and shell_index == i:
				button.button_pressed = true
			else:
				button.button_pressed = false
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
	select_shell_c.rpc_id(multiplayer.get_remote_sender_id(), shell_index)



# todo: only broadcast if shooting or detected
@rpc("authority", "call_remote", "reliable")
func select_shell_c(_shell_index: int) -> void:
	shell_index = _shell_index

# func get_weapon_ui(offset: int) -> Array[Button]:
# 	print("weapon ui not setup")
# 	return []
# # Called when the node enters the scene tree for the first time.
# func _ready() -> void:
# 	pass # Replace with function body.


# func update_weapon_ui(delta: float) -> bool:
# 	var switched = false
# 	for i in range(buttons.size()):
# 		var button = buttons[i]
# 		if button and button == curr_button:
# 			button.button_pressed = _ship.get_node("Modules/PlayerControl").current_weapon_controller == self
# 		# button.text = "AP" if shell_index == 0 else "HE"
# 		if select_held:
# 			held_duration += delta
# 			button.button_pressed = true
# 		else:
# 			held_duration = 0.0
# 			if _ship.get_node("Modules/PlayerControl").current_weapon_controller != self:
# 				button.button_pressed = false
# 		if switch_progress and not switched_shell:
# 			switch_progress[i].value = min(held_duration, 1.0)
# 		if held_duration > 1.0 and not switched_shell:
# 			# select_shell.rpc_id(1, 1 - shell_index)
# 			switched = true
# 			switched_shell = true
# 			held_duration = 0.0
# 	return switched
# 	# for button in buttons:
# 	# 	if button and button == curr_button:
# 	# 		button.button_pressed = _ship.get_node("Modules/PlayerControl").current_weapon_controller == self
# 	# 	button.text = "AP" if shell_index == 0 else "HE"
# 	# 	if select_held:
# 	# 		held_duration += delta
# 	# 		button.button_pressed = true
# 	# 	else:
# 	# 		held_duration = 0.0
# 	# 		if _ship.get_node("Modules/PlayerControl").current_weapon_controller != self:
# 	# 			button.button_pressed = false
# 	# 	if switch_progress and not switched_shell:
# 	# 		switch_progress.value = min(held_duration, 1.0)
# 	# 	if held_duration > 1.0 and not switched_shell:
# 	# 		select_shell.rpc_id(1, 1 - shell_index)
# 	# 		switched_shell = true
# 	# 		held_duration = 0.0

# # Called every frame. 'delta' is the elapsed time since the previous frame.
# func _process(delta: float) -> void:
# 	pass
