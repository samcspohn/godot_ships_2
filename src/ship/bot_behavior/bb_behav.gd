extends BotBehavior
class_name BBBehavior

var ammo = ShellParams.ShellType.AP

# Arc movement state
var current_arc_direction: int = 0
var arc_direction_timer: float = 0.0
var arc_direction_initialized: bool = false
const ARC_DIRECTION_CHANGE_TIME: float = 30.0
const ARC_MOVEMENT_SPEED: float = 0.15
const MIN_SAFE_ANGLE_FROM_THREAT: float = PI / 3.0

# Skills
var _skill_hunt: SkillHunt = SkillHunt.new()
var _skill_chase: SkillChase = SkillChase.new()
var _skill_broadside: SkillBroadside = SkillBroadside.new()
var _skill_kite: SkillKite = SkillKite.new()
var _skill_camp: SkillCamp = SkillCamp.new()
var _skill_flank: SkillFlank = SkillFlank.new()
var _skill_cover: SkillFindCover = SkillFindCover.new()
var _skill_spread: SkillSpread = SkillSpread.new()
var _skill_angle: SkillAngle = SkillAngle.new()

# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(25),
		max_angle = deg_to_rad(35),
		evasion_period = 20.0,  # Slow, deliberate weaves
		vary_speed = false
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 2.0   # Other BBs are primary threat
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 3.0   # DDs less relevant for angling
	return 1.0

func get_target_weights() -> Dictionary:
	return {
		size_weight = 0.3,
		range_weight = 0.5,
		hp_weight = 0.2,
		class_modifiers = {
			Ship.ShipClass.BB: 1.0,
			Ship.ShipClass.CA: 1.0,
			Ship.ShipClass.DD: 1.0,
		},
		prefer_broadside = true,
		in_range_multiplier = 10.0,
		flanking_multiplier = 4.0,  # BBs prioritize flanking enemies (slightly lower than CA/DD since BBs turn slowly)
		overextension_weight = 0.5,  # BBs care a lot about overextended enemies (big guns punish pushes)
		proximity_override_distance = 4000.0,  # BBs have larger proximity threshold due to slow turning
		overextension_bonus = 2.5,  # Strong bonus for the most forward enemy when nothing is close
	}

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.60,           # 60% of gun range — active engagement distance
		range_increase_when_damaged = 0.10, # Up to +10% range when low HP — don't retreat to max range
		min_safe_distance_ratio = 0.30,     # Only retreat if something gets within 30% range (very close)
		flank_bias_healthy = 0.6,
		flank_bias_damaged = 0.2,
		spread_distance = 3000.0,
		spread_multiplier = 1.0,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.4,      # Stand off 40% of gun range in front of last known position
		cautious_hp_threshold = 0.4,    # Only pull back toward friendlies when quite damaged
	}

func _roll_flank_depth() -> float:
	return randf_range(0.1, 0.3)

func get_theatened(server: GameServer) -> bool:
	## TODO: add dispersion + caliber checks to this
	var spotted = server.get_valid_targets(_ship.team.team_id)
	var my_hp = _ship.health_controller.current_hp
	var hp_ratio = my_hp / _ship.health_controller.max_hp
	var desired_dist = clampf(1.0 - hp_ratio + 0.3, 0.3, 1.0)
	var total_hp: float = 0.0
	for enemy in spotted:
		var dist = enemy.global_position.distance_to(_ship.global_position)
		var enemy_range = enemy.artillery_controller.get_params()._range
		var enemy_hp = enemy.health_controller.current_hp
		total_hp += enemy_hp
		match enemy.ship_class:
			Ship.ShipClass.BB:
				if enemy_hp > my_hp * 0.9:
					return true
			Ship.ShipClass.CA:
				if enemy_hp > my_hp * 0.7:
					return true
			Ship.ShipClass.DD:
				if dist < enemy_range * desired_dist * 0.8:
					return true
	if total_hp > my_hp * 1.5:
		return true
	return false

# ============================================================================
# AMMO AND AIM - Class-specific targeting logic
# ============================================================================

func pick_ammo(_target: Ship) -> int:
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _target.global_position - _ship.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var offset = Vector3(0, 0, 0)
	angle = abs(angle)
	#if angle > PI / 2.0:
		#angle = PI - angle

	# Default to AP
	ammo = ShellParams.ShellType.AP

	match _target.ship_class:
		Ship.ShipClass.BB:
			if angle < deg_to_rad(10) or angle > deg_to_rad(170):
				# HE against heavily angled battleships
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 2.0
			elif angle < deg_to_rad(30) or angle > deg_to_rad(150):
				# AP at battleship superstructure when angled
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 2.0
			else:
				ammo = ShellParams.ShellType.AP
				offset.y = 0.1
		Ship.ShipClass.CA:
			if angle < deg_to_rad(30):
				# AP at angled cruiser bow/stern
				ammo = ShellParams.ShellType.AP
				offset.z -= _target.movement_controller.ship_length * 0.25
			elif angle > deg_to_rad(180-30):
				ammo = ShellParams.ShellType.AP
				offset.z += _target.movement_controller.ship_length * 0.25
			else:
				# AP at broadside cruisers waterline
				ammo = ShellParams.ShellType.AP
				offset.y = 0.0
		Ship.ShipClass.DD:
			# HE at destroyers
			ammo = ShellParams.ShellType.AP
			offset.y = 2.0
			offset.z -= _target.movement_controller.ship_length * 0.2
	return offset

func _apply_arc_movement(base_position: Vector3, danger_center: Vector3, engagement_range: float, server_node: GameServer) -> Vector3:
	"""Apply continuous arc movement around danger center to avoid parking."""
	var my_pos = _ship.global_position

	var to_me = my_pos - danger_center
	to_me.y = 0.0
	var current_angle = atan2(to_me.x, to_me.z)

	var friendly_angle = current_angle
	if server_node:
		var friendly_avg = server_node.get_team_avg_position(_ship.team.team_id)
		if friendly_avg != Vector3.ZERO:
			var to_friendly = friendly_avg - danger_center
			to_friendly.y = 0.0
			friendly_angle = atan2(to_friendly.x, to_friendly.z)

	# Initialize arc direction
	if not arc_direction_initialized:
		arc_direction_initialized = true
		var angle_to_friendly = _normalize_angle(friendly_angle - current_angle)
		current_arc_direction = -1 if angle_to_friendly > 0 else 1

	# Update arc direction periodically
	arc_direction_timer += 1.0 / Engine.physics_ticks_per_second
	if arc_direction_timer >= ARC_DIRECTION_CHANGE_TIME:
		arc_direction_timer = 0.0
		var angle_to_friendly = _normalize_angle(friendly_angle - current_angle)
		var preferred_direction = -sign(angle_to_friendly) if abs(angle_to_friendly) > 0.1 else current_arc_direction
		current_arc_direction = 1 if preferred_direction > 0 else -1

	# Apply arc movement
	var arc_movement = ARC_MOVEMENT_SPEED * current_arc_direction
	var new_angle = current_angle + arc_movement

	var arc_position = danger_center + Vector3(sin(new_angle), 0, cos(new_angle)) * engagement_range
	arc_position.y = 0.0

	# Blend between tactical position and arc position
	var blend_factor = 0.3
	return base_position * (1.0 - blend_factor) + arc_position * blend_factor

# ============================================================================
# NAVINTENT — V4 bot controller interface
# ============================================================================

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	var ctx = SkillContext.create(ship, target, server, self)
	var delta = 1.0 / Engine.physics_ticks_per_second
	_init_flank_identity(ship, server)

	var spotted = server.get_valid_targets(ship.team.team_id)
	var has_spotted = spotted.size() > 0
	var unspotted = server.get_unspotted_enemies(ship.team.team_id)
	var has_enemies = has_spotted or not unspotted.is_empty()
	var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp
	var threatened = get_theatened(server)

	if not has_enemies:
		# No enemies at all — default to hunting behavior
		_tactical_state = TacticalState.State.HUNTING
		# print("no enemies, hunting")

	# --- Tactical state transitions ---
	match _tactical_state:
		TacticalState.State.HUNTING:
			if has_spotted:
				_tactical_state = TacticalState.State.ENGAGED
		TacticalState.State.ENGAGED:
			if not has_enemies:
				_tactical_state = TacticalState.State.HUNTING
			elif hp_ratio < 0.2 and ship.visible_to_enemy:
				_tactical_state = TacticalState.State.DISENGAGING
				_bloom_probe.enter()
		TacticalState.State.DISENGAGING:
			_bloom_probe.update(ship, delta)
			if _bloom_probe.went_dark:
				_tactical_state = TacticalState.State.SNEAKING
			elif _bloom_probe.probe_failed:
				_tactical_state = TacticalState.State.ENGAGED
			if hp_ratio > 0.35:
				_tactical_state = TacticalState.State.ENGAGED
		TacticalState.State.SNEAKING:
			if ship.visible_to_enemy or has_spotted:
				_tactical_state = TacticalState.State.ENGAGED

	# --- Execute skill based on state ---
	var _prev_skill_name = _active_skill_name
	var intent: NavIntent = null
	var params = get_positioning_params()
	match _tactical_state:
		TacticalState.State.HUNTING:
			intent = _skill_hunt.execute(ctx, {})
			_active_skill_name = &"Hunt"
		TacticalState.State.SNEAKING:
			intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.75})
			if intent:
				_active_skill_name = &"Kite"
		TacticalState.State.ENGAGED:
			intent = _execute_bb_engaged_skill(ctx, threatened)
		TacticalState.State.DISENGAGING:
			var desired_range_ratio = 0.7 + (1.0 - hp_ratio) * 0.6
			intent = _skill_kite.execute(ctx, {"desired_range_ratio": clampf(desired_range_ratio, 0.0, 1.01), "pull_toward_friendly_weight": 0.4})
			if intent:
				_active_skill_name = &"Kite"

	# Fallback
	if intent == null:
		var fwd = ship.global_position - ship.basis.z * 10000
		fwd.y = 0.0
		intent = NavIntent.create(_get_valid_nav_point(fwd), _calc_approach_heading(ship, fwd))
		_active_skill_name = &"SailForward"

	# Reset camp lock when switching away from Camp
	if _prev_skill_name == &"Camp" and _active_skill_name != &"Camp":
		_skill_camp.reset()

	# Post-process broadside (oscillate heading toward all-guns-bearing angles)
	if _active_skill_name in [&"Kite", &"Angle", &"Camp"]:
		intent = _skill_broadside.apply(intent, ctx, {
			"oscillation_bias": 0.5,
		})

	# Post-process spread
	if _active_skill_name not in [&"FindCover", &"Angle", &"Kite"]:
		intent = _skill_spread.apply(intent, ctx, {"spread_distance": params.spread_distance, "spread_multiplier": params.spread_multiplier})
	return intent

func _execute_bb_engaged_skill(ctx: SkillContext, threatened: bool) -> NavIntent:
	var hp_ratio = ctx.ship.health_controller.current_hp / ctx.ship.health_controller.max_hp
	var intent: NavIntent = null

	# Very damaged: seek cover if available
	if hp_ratio < 0.2:
		intent = _skill_cover.execute(ctx, {"desired_range": ctx.ship.artillery_controller.get_params()._range * 0.7})
		if intent != null:
			_active_skill_name = &"FindCover"
			return intent

	# Damaged: kite
	var nearest_enemy = ctx.behavior._get_nearest_enemy()[&"position"]
	if hp_ratio < 0.4 and nearest_enemy.distance_to(ctx.ship.global_position) < ctx.ship.artillery_controller.get_params()._range * 0.8:
		intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.7, "pull_toward_friendly_weight": 0.3})
		if intent:
			_active_skill_name = &"Kite"
		return intent
	if hp_ratio < 0.4 and !_ship.visible_to_enemy:
		intent = _skill_cover.execute(ctx, {"desired_range": ctx.ship.artillery_controller.get_params()._range * 0.7})
		if intent != null:
			_active_skill_name = &"FindCover"
			return intent

	# Healthy: camp or broadside
	if threatened:
		var desired_range_ratio = 0.6 + (1.0 - hp_ratio) * 0.3  # Closer to 90% range when at full HP, down to 60% when damaged
		intent = _skill_camp.execute(ctx, {"desired_range_ratio": desired_range_ratio})
		if intent:
			_active_skill_name = &"Camp"
			return intent
	else:
		var desired_range_ratio = (1.0 - hp_ratio) * 0.3
		intent = _skill_angle.execute(ctx, {"desired_range_ratio": desired_range_ratio})
		if intent:
			_active_skill_name = &"Angle"
			return intent

	return intent


## Compute approach heading from ship to destination
func _calc_approach_heading(ship: Ship, dest: Vector3) -> float:
	var to_dest = dest - ship.global_position
	to_dest.y = 0.0
	if to_dest.length_squared() > 1.0:
		return atan2(to_dest.x, to_dest.z)
	return _get_ship_heading()
