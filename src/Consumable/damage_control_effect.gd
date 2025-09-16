# extends Mod
# class_name DamageControlEffect

# var fire_duration_reduction: float = 0.65  # 65% reduction
# var fire_damage_reduction: float = 0.65    # 65% reduction
# var original_fire_durations: Dictionary = {}
# var original_fire_dps: Dictionary = {}

# var params: FireParams

# signal damage_control_activated
# signal damage_control_expired

# # func setup_damage_control(target_ship: Ship, duration: float):
# # 	setup(target_ship, duration)

# func apply(ship: Ship) -> void:
# 	# This method is called when the modifier is applied to the ship
# 	ship.fires

# func activate_effect():
# 	if not ship:
# 		return
	
# 	# Apply fire duration and damage reduction to all active fires
# 	modify_active_fires()
	
# 	print("Damage Control Party activated on ", ship.name, " - Fire duration and damage reduced by 65%")
# 	damage_control_activated.emit()
	
# 	# Visual effects - could add particle effects, ship glow, etc.
# 	add_visual_effects()

# func modify_active_fires():
# 	if not ship:
# 		return
	
# 	# Apply modifications to all active fires
# 	var fires = ship.fires
# 	for fire in fires:
# 		if fire and is_instance_valid(fire):
# 			# Store original values if not already stored
# 			if not original_fire_durations.has(fire):
# 				original_fire_durations[fire] = fire.duration
# 				original_fire_dps[fire] = fire.dps
			
# 			# Reduce fire duration by 65%
# 			fire.duration = original_fire_durations[fire] * (1.0 - fire_duration_reduction)
			
# 			# Reduce fire damage by 65%
# 			fire.dps = original_fire_dps[fire] * (1.0 - fire_damage_reduction)
	
# 	print("Modified ", fires.size(), " active fires - reduced duration and damage by 65%")

# func get_fire_effects() -> Array:
# 	var fires = []
# 	# Search ship's children for fire effects
# 	_find_effects_recursive(ship, "Fire", fires)
# 	return fires

# func _find_effects_recursive(node: Node, effect_type: String, results: Array):
# 	# Check if current node is the effect type we're looking for
# 	if node.get_script() and node.get_script().get_global_name() == effect_type:
# 		results.append(node)
# 	elif node.name.contains(effect_type):
# 		results.append(node)
	
# 	# Recursively search children
# 	for child in node.get_children():
# 		_find_effects_recursive(child, effect_type, results)

# func add_visual_effects():
# 	# Add visual feedback for damage control being active
# 	if ship.has_method("add_effect_glow"):
# 		ship.add_effect_glow(Color.BLUE, remaining_duration)
	
# 	# Could add particle effects, sound, etc.

# func _process(delta):
# 	if effect_active:
# 		remaining_duration -= delta
		
# 		# Apply modifications to any new fires that started during the effect
# 		modify_new_fires()
		
# 		if remaining_duration <= 0:
# 			deactivate_effect()

# func modify_new_fires():
# 	# Check for any fires that weren't modified yet
# 	var fires = ship.fires
# 	for fire in fires:
# 		if fire and is_instance_valid(fire):
# 			# If this fire wasn't modified yet, modify it
# 			if not original_fire_durations.has(fire):
# 				original_fire_durations[fire] = fire.duration
# 				original_fire_dps[fire] = fire.total_dmg_p
				
# 				# Apply reductions
# 				fire.duration = original_fire_durations[fire] * (1.0 - fire_duration_reduction)
# 				fire.total_dmg_p = original_fire_dps[fire] * (1.0 - fire_damage_reduction)

# func deactivate_effect():
# 	if ship:
# 		# Restore original fire properties for all fires we modified
# 		restore_fire_properties()
		
# 		print("Damage Control Party expired on ", ship.name, " - Fire properties restored")
# 		remove_visual_effects()
	
# 	damage_control_expired.emit()
# 	super.deactivate_effect()

# func restore_fire_properties():
# 	# Restore original fire durations and damage percentages
# 	for fire in original_fire_durations.keys():
# 		if fire and is_instance_valid(fire):
# 			fire.duration = original_fire_durations[fire]
# 			fire.total_dmg_p = original_fire_dps[fire]
	
# 	# Clear our stored values
# 	original_fire_durations.clear()
# 	original_fire_dps.clear()

# func remove_visual_effects():
# 	# Remove visual effects
# 	if ship.has_method("remove_effect_glow"):
# 		ship.remove_effect_glow()
