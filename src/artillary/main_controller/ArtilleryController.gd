extends WeaponController
class_name ArtilleryController

# Gun-related variables
@export var params: GunParams
# var _gun_params: GunParams
@export var guns: Array[Gun] = []
# var shell_index: int = 1
var aim_point: Vector3
# var _ship: Ship
var target_mod: TargetMod = TargetMod.new()
var dispersion_calculator: DispersionCalculator = DispersionCalculator.new()
var fire_held: bool = false
var sequential_fire_timer: float = 0.0
var sequential_fire_delay: float = 0.2 # Delay between sequential gun fires

func _init():
	button_names = ["AP", "HE"]
	tool_tips = [
	 	Callable(_build_tooltip_text).bind(0),
		Callable(_build_tooltip_text).bind(1)
	]
# @export var button_names: Array[String] = ["HE", "AP"]
# # var select_held: bool = false
# var buttons: Array[Button] = []
# # var button_keys: Array[int] = []
# var switch_progresss: Array[ProgressBar] = []
# # var held: Array[bool] = []
# var held_dur: Array[float] = []

# var held_duration: float = 0.0
# var switched_shell: bool = false
# var button_key: int = -1

# var pressed_time: float = 0.0
# func get_weapon_ui(offset: int) -> Array[Button]:
# 	var shell1 = Button.new()
# 	shell1.text = "HE"
# 	shell1.set_meta("tooltip_provider", func() -> String: return _build_tooltip_text(params.dynamic_mod as GunParams, params.dynamic_mod.shell2))
# 	shell1.button_down.connect(func():
# 		held[0] = true
# 		# pressed_time = Time.get_ticks_msec() / 1000.0
# 	)
# 	shell1.pressed.connect(func():
# 		_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
# 		select_shell.rpc_id(1, 1)
# 	)
# 	shell1.button_up.connect(func():
# 		# if Time.get_ticks_msec() / 1000.0 - pressed_time < 0.5:
# 		# 	_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
# 		# 	pressed_time = 0.0
# 		held[0] = false
# 		switched_shell = false
# 	)
# 	var switch_progress = ProgressBar.new()
# 	switch_progress.min_value = 0.0
# 	switch_progress.max_value = 1.0
# 	switch_progress.value = 0.0
# 	switch_progress.show_percentage = false
# 	switch_progress.set_anchors_preset(Control.PRESET_FULL_RECT)
# 	switch_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
# 	switch_progress.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP

# 	shell1.add_child(switch_progress)
# 	buttons.append(shell1)
# 	button_keys.append(offset)
# 	switch_progresss.append(switch_progress)
# 	held.append(false)
# 	held_dur.append(0.0)

# 	var shell2 = Button.new()
# 	shell2.text = "AP"
# 	shell2.set_meta("tooltip_provider", func() -> String: return _build_tooltip_text(params.dynamic_mod as GunParams, params.dynamic_mod.shell1))
# 	shell2.button_down.connect(func():
# 		held[1] = true
# 		# pressed_time = Time.get_ticks_msec() / 1000.0
# 	)
# 	shell2.pressed.connect(func():
# 		_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
# 		select_shell.rpc_id(1, 0)
# 	)
# 	shell2.button_up.connect(func():
# 		# if Time.get_ticks_msec() / 1000.0 - pressed_time < 0.5:
# 		# 	_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
# 		# 	pressed_time = 0.0
# 		held[1] = false
# 		switched_shell = false
# 	)
# 	# button_key = offset + 1
# 	var switch_progress2 = ProgressBar.new()
# 	switch_progress2.min_value = 0.0
# 	switch_progress2.max_value = 1.0
# 	switch_progress2.value = 0.0
# 	switch_progress2.show_percentage = false
# 	switch_progress2.set_anchors_preset(Control.PRESET_FULL_RECT)
# 	switch_progress2.mouse_filter = Control.MOUSE_FILTER_IGNORE
# 	switch_progress2.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP
# 	shell2.add_child(switch_progress2)
# 	buttons.append(shell2)
# 	# button_keys.append(button_key)
# 	button_keys.append(offset + 1)
# 	switch_progresss.append(switch_progress2)
# 	held.append(false)
# 	held_dur.append(0.0)
# 	# button = shell1
# 	return [shell1, shell2]

# func update_weapon_ui(delta: float) -> void:
# 	for i in range(buttons.size()):
# 		var button = buttons[i]
# 		var switch_progress = switch_progresss[i]
# 		if held[i]:
# 			held_dur[i] += delta
# 			button.button_pressed = true
# 		else:
# 			if held_dur[i] < 0.2 and held_dur[i] > 0.0: # pressed for less than 0.2 seconds, treat as a tap
# 				_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
# 				select_shell.rpc_id(1, 1 - i)
# 				# switched_shell = true
# 			held_dur[i] = 0.0
# 			if _ship.get_node("Modules/PlayerControl").current_weapon_controller == self and shell_index != i:
# 				button.button_pressed = true
# 			else:
# 				button.button_pressed = false
# 			# if _ship.get_node("Modules/PlayerControl").current_weapon_controller != self:
# 			# 	if shell_index == i:
# 			# 		button.button_pressed = true
# 			# 	else:
# 			# 		button.button_pressed = false
# 		if switch_progress and not switched_shell:
# 			switch_progress.value = min(held_dur[i], 1.0)
# 		if held_dur[i] > 1.0 and not switched_shell:
# 			select_shell.rpc_id(1, 1 - i)
# 			switched_shell = true
# 		# if button:
# 		# 	if select_held:
# 		# 		held_duration += delta
# 		# 		button.button_pressed = true
# 		# 	else:
# 		# 		held_duration = 0.0
# 		# 		if _ship.get_node("Modules/PlayerControl").current_weapon_controller != self:
# 		# 			button.button_pressed = false
# 		# 	if switch_progress and not switched_shell:
# 		# 		switch_progress.value = min(held_duration, 1.0)
# 		# 	if held_duration > 1.0 and not switched_shell:
# 		# 		select_shell.rpc_id(1, 1 - shell_index)
# 		# 		switched_shell = true
# 		# 		# held_duration = 0.0

# func _process(delta: float) -> void:
# 	update_weapon_ui(delta)

# func _input(event: InputEvent) -> void:
# 	if event is InputEventKey:
# 		if event.pressed and not event.echo:
# 			if event.keycode == Key.KEY_1 + button_key:
# 				select_held = true
# 				pressed_time = Time.get_ticks_msec() / 1000.0
# 		elif !event.pressed and not event.echo:
# 			if event.keycode == Key.KEY_1 + button_key:
# 				if Time.get_ticks_msec() / 1000.0 - pressed_time < 0.2:
# 					_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
# 				select_held = false
# 				switched_shell = false

func _build_tooltip_text(shell: int) -> String:
	var gp := get_params()
	var sp := gp.shell1 if shell == 0 else gp.shell2
	var shell_label := "AP" if sp.type == ShellParams.ShellType.AP else "HE"
	# var num_guns := guns.size()
	var lines := [
		"Main Battery (%s)" % shell_label,
		"----------------------------------",
		"Caliber: %.0f mm" % sp.caliber,
		"Reload: %.1f s" % gp.reload_time,
		"Range: %.1f km" % (gp._range / 1000.0),
		"Traverse: %.1f s" % (180.0 / gp.traverse_speed),
		"----------------------------------",
		"Shell: %s" % shell_label,
		"  Damage: %d" % int(sp.damage),
		"  Muzzle velocity: %.0f m/s" % sp.speed,
		"  Mass: %.1f kg" % sp.mass,
	]
	if sp.type == ShellParams.ShellType.HE:
		lines.append("  Fire chance buildup: %.0f" % sp.fire_buildup)
		lines.append("  Overmatch: %d mm" % sp.overmatch)
	else:
		lines.append("  Arming threshold: %d mm" % sp.arming_threshold)
		lines.append("  Fuze delay: %.3f s" % sp.fuze_delay)
		lines.append("  Ricochet angle: %.0f°" % rad_to_deg(sp.ricochet_angle))
		lines.append("  Auto-bounce angle: %.0f°" % rad_to_deg(sp.auto_bounce))
	# lines.append("  Pen modifier: %.2fx" % sp.penetration_modifier)
	return "\n".join(PackedStringArray(lines))

func get_aim_ui() -> Dictionary:
	var ship_position = _ship.global_position + Vector3(0.0, _ship.movement_controller.ship_draft * 0.5, 0.0)
	var shell_params: ShellParams = get_shell_params()
	var time_to_target = -1
	var penetration_power = -1
	var terrain_hit = false

	if Vector2(aim_point.x, aim_point.z).distance_to(Vector2(ship_position.x, ship_position.z)) > get_params()._range:
		return {
			"terrain_hit": terrain_hit,
			"penetration_power": penetration_power,
			"time_to_target": time_to_target
		}

	var launch_result = ProjectilePhysicsWithDragV2.calculate_launch_vector(
		ship_position,
		aim_point,
		shell_params
	)
	var launch_vector = launch_result[0]

	if launch_vector:
		time_to_target = launch_result[1] / ProjectileManager.get_shell_time_multiplier()
		var can_shoot: Gun.ShootOver = Gun.sim_can_shoot_over_terrain_static(
			ship_position,
			launch_vector,
			launch_result[1],
			shell_params,
			_ship
			)

		terrain_hit = not can_shoot.can_shoot_over_terrain
		var shell = get_shell_params()
		if shell.type == ShellParams.ShellType.HE:
			penetration_power = shell.overmatch * (shell as ShellParams).penetration_modifier
		else:
			var velocity_at_impact_vec = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
				launch_vector,
				launch_result[1],
				shell_params
			)
			var velocity_at_impact = velocity_at_impact_vec.length()
			var raw_pen = _ArmorInteraction.calculate_de_marre_penetration(
				shell.mass,
				velocity_at_impact,
				shell.caliber)
			# var raw_pen = 1.0

			# Calculate impact angle (angle from vertical)
			var impact_angle = PI / 2 - velocity_at_impact_vec.normalized().angle_to(Vector3.UP)

			# Calculate effective penetration against vertical armor
			# Effective penetration = raw penetration * cos(impact_angle)
			penetration_power = raw_pen * cos(impact_angle) * (shell as ShellParams).penetration_modifier

	# return terrain hit, penetration power, time to target
	return {
		"terrain_hit": terrain_hit,
		"penetration_power": penetration_power,
		"time_to_target": time_to_target
	}

func get_max_range() -> float:
	return get_params()._range

# guns is sorted front-to-back (ascending local z) in _ready(), so this
# getter returns turrets in front-to-back order for UI consumption.
var weapons: Array[Turret]:
	get:
		var arr: Array[Turret] = []
		for g in guns:
			arr.append(g)
		return arr

func to_dict() -> Dictionary:
	return {
		"params": params.dynamic_mod.to_dict(),
	}

func to_bytes() -> PackedByteArray:
	return params.dynamic_mod.to_bytes()

func from_dict(d: Dictionary) -> void:
	params.dynamic_mod.from_dict(d.get("params", {}))

func from_bytes(b: PackedByteArray) -> void:
	params.dynamic_mod.from_bytes(b)

func _ready() -> void:
	_ship = get_parent().get_parent() as Ship
	var i = 0
	# params = params.duplicate(true)
	params = params.instantiate(_ship) as GunParams
	target_mod = target_mod.instantiate(_ship) as TargetMod

	guns.sort_custom(func(a: Gun, b: Gun) -> bool:
		return a.get_parent().position.z < b.get_parent().position.z
	)

	for g in guns:
		g.gun_id = i
		g.controller = self
		g._ship = _ship
		g.dispersion_calculator = self.dispersion_calculator
		i += 1


	if _Utils.authority():
		set_physics_process(true)
		set_process(false)
	else:
		if _ship.ship_class == Ship.ShipClass.BB:
			select_shell.rpc_id(1, 0)

		set_physics_process(false)

## Returns the 3D velocity vector at impact for a ballistic trajectory to target_pos.
## Returns Vector3.ZERO if no firing solution exists (e.g. target out of range).
func get_landing_velocity_to_point(target_pos: Vector3) -> Vector3:
	var ship_position = _ship.global_position + Vector3(0.0, _ship.movement_controller.ship_draft * 0.5, 0.0)
	var shell_params: ShellParams = get_shell_params()
	var launch_result = ProjectilePhysicsWithDragV2.calculate_launch_vector(
		ship_position, target_pos, shell_params
	)
	var launch_vector = launch_result[0]
	if not launch_vector:
		return Vector3.ZERO
	return ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
		launch_vector, launch_result[1], shell_params
	)

## Returns the 3D velocity vector at impact for a ballistic trajectory whose
## start and end are both projected to the water plane (y=0). Useful for
## producing a stable, range-only impact angle that does not jitter as the
## camera tilts up/down across a ship's superstructure.
func get_landing_velocity_to_point_horizontal(target_pos: Vector3) -> Vector3:
	var ship_pos_h := Vector3(_ship.global_position.x, 0.0, _ship.global_position.z)
	var target_pos_h := Vector3(target_pos.x, 0.0, target_pos.z)
	var shell_params: ShellParams = get_shell_params()
	var launch_result = ProjectilePhysicsWithDragV2.calculate_launch_vector(
		ship_pos_h, target_pos_h, shell_params
	)
	var launch_vector = launch_result[0]
	if not launch_vector:
		return Vector3.ZERO
	return ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
		launch_vector, launch_result[1], shell_params
	)

## Given an aim point at any altitude, returns the water-level (y=0) point on
## the same ballistic trajectory. Lets the camera normalize a deck/altitude aim
## into the trajectory's water intercept so downstream code (gun aiming, UI)
## sees a consistent water-level target. Falls back to the input on no solution.
func get_water_intercept_for_aim_point(aim_point_in: Vector3) -> Vector3:
	var ship_position = _ship.global_position + Vector3(0.0, _ship.movement_controller.ship_draft * 0.5, 0.0)
	var shell_params: ShellParams = get_shell_params()
	var launch_result = ProjectilePhysicsWithDragV2.calculate_launch_vector(
		ship_position, aim_point_in, shell_params
	)
	var launch_vector = launch_result[0]
	if not launch_vector:
		return aim_point_in
	return ProjectilePhysicsWithDragV2.calculate_impact_position(
		ship_position, launch_vector, shell_params
	)

func set_aim_input(target_point: Vector3) -> void:
	# var ship_pos = _ship.global_position
	# ship_pos.y = 0
	# var target_offset = (target_point - ship_pos)
	# target_point = target_offset.normalized() * min(target_offset.length(), get_params()._range) + ship_pos

	aim_point = target_point

func _physics_process(delta: float) -> void:

	# Aim all guns toward the target point
	for g in guns:
		g._aim(aim_point, delta)

	if fire_held:
		sequential_fire_timer += delta
		var reload = get_params().reload_time
		var min_reload = reload / guns.size() - 0.01
		var adjusted_sequential_fire_delay = min(sequential_fire_delay, min_reload)
		while sequential_fire_timer >= adjusted_sequential_fire_delay:
			sequential_fire_timer -= adjusted_sequential_fire_delay
			fire_next_ready()

@rpc("any_peer", "call_remote")
func fire_all() -> void:
	for gun in guns:
		if gun.reload >= 1.0 and gun.can_fire:
			gun.fire(target_mod)

@rpc("any_peer", "call_remote")
func fire_next_ready() -> void:
	for g in guns:
		if g.reload >= 1 and g.can_fire:
			g.fire(target_mod)
			return

@rpc("any_peer", "call_remote")
func set_fire_held(held: bool) -> void:
				fire_held = held
				if !fire_held:
					sequential_fire_timer = 0.0

# @rpc("any_peer", "call_remote")
# func select_shell(_shell_index: int) -> void:
# 	if !(_Utils.authority()):
# 		return
# 	shell_index = clamp(_shell_index, 0, 1)
# 	select_shell_client.rpc(shell_index)



# # todo: only broadcast if shooting or detected
# @rpc("authority", "call_remote")
# func select_shell_client(_shell_index: int) -> void:
# 	shell_index = clamp(_shell_index, 0, 1)

func get_shell_params() -> ShellParams:
	if shell_index == 0:
		return params.dynamic_mod.shell1
	else:
		return params.dynamic_mod.shell2

func get_params() -> GunParams:
	return params.dynamic_mod as GunParams

func get_base_params() -> GunParams:
	return params.base as GunParams
