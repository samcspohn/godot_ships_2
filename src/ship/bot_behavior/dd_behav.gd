extends BotBehavior
class_name DDBehavior

var ammo = ShellParams.ShellType.HE

# Speed variation for evasion
var speed_variation_timer: float = 0.0
var current_speed_multiplier: float = 1.0
const SPEED_VARIATION_PERIOD: float = 3.0
const SPEED_VARIATION_MIN: float = 0.6
const SPEED_VARIATION_MAX: float = 1.0

# Track torpedo hits and floods for shooting decision
var last_torpedo_count: int = 0
var last_flood_count: int = 0
var target_is_flooding: bool = false

# Track closest enemy for retreat decisions
var closest_enemy: Ship

# Skills
var _skill_hunt: SkillHunt = SkillHunt.new()
var _skill_chase: SkillChase = SkillChase.new()
var _skill_torpedo_run: SkillTorpedoRun = SkillTorpedoRun.new()
var _skill_retreat: SkillRetreat = SkillRetreat.new()
var _skill_kite: SkillKite = SkillKite.new()
var _skill_flank: SkillFlank = SkillFlank.new()
var _skill_spot: SkillSpot = SkillSpot.new()
var _skill_spread: SkillSpread = SkillSpread.new()

# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(10),
		max_angle = deg_to_rad(25),
		evasion_period = 2.5,  # Quick, erratic weaving
		vary_speed = true      # Only DDs vary speed
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 1.5   # CAs are DD hunters
		Ship.ShipClass.DD: return 1.0
	return 1.0

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.50,
		range_increase_when_damaged = 0.30,
		min_safe_distance_ratio = 0.30,
		flank_bias_healthy = 0.7,
		flank_bias_damaged = 0.1,
		spread_distance = 1500.0,  # DDs spread more
		spread_multiplier = 1.0,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.8,      # DDs hunt aggressively
		cautious_hp_threshold = 0.3,
	}

func _roll_flank_depth() -> float:
	return randf_range(0.4, 0.9)

# ============================================================================
# EVASION - DD-specific with speed variation
# ============================================================================

func get_desired_heading(target: Ship, current_heading: float, delta: float, destination: Vector3) -> Dictionary:
	"""Override to add speed variation for DDs."""
	var result = super.get_desired_heading(target, current_heading, delta, destination)

	# Update speed variation when evading
	if result.use_evasion:
		speed_variation_timer += delta
		var speed_wave = (sin(speed_variation_timer * TAU / SPEED_VARIATION_PERIOD) + 1.0) / 2.0
		current_speed_multiplier = lerp(SPEED_VARIATION_MIN, SPEED_VARIATION_MAX, speed_wave)
	else:
		current_speed_multiplier = 1.0

	return result

func get_speed_multiplier() -> float:
	"""Returns current speed multiplier for evasion."""
	return current_speed_multiplier

# ============================================================================
# TARGET SELECTION - DD-specific logic (visible vs hidden priority)
# ============================================================================

func pick_target(targets: Array[Ship], _last_target: Ship) -> Ship:
	"""DD target selection differs based on visibility - torpedoes vs guns.
	Prefers targets we can actually shoot at over ones behind cover."""
	var best_shootable: Ship = null
	var best_shootable_priority: float = -1.0
	var best_fallback: Ship = null
	var best_fallback_priority: float = -1.0
	var gun_range = _ship.artillery_controller.get_params()._range
	var torpedo_range: float = -1.0

	if _ship.torpedo_controller != null:
		torpedo_range = _ship.torpedo_controller.get_params()._range

	for ship in targets:
		var disp = ship.global_position - _ship.global_position
		var dist = disp.length()
		var angle = (-ship.basis.z).angle_to(disp)
		angle -= PI / 4  # Best angle to torpedo is 45 degrees incoming
		var priority: float = 0.0

		if !_ship.visible_to_enemy:
			# Hidden - prioritize torpedo targets
			priority = cos(angle) * ship.movement_controller.ship_length / dist
			if torpedo_range > 0:
				priority = priority * 0.3 + (1.0 - dist / torpedo_range) * 0.7
			if ship.ship_class == Ship.ShipClass.BB:
				priority *= 3.0  # BBs are prime torpedo targets
		else:
			# Visible - prioritize gun targets
			priority = (1.0 - dist / gun_range)

		# Boost targets within range
		if dist <= gun_range or (torpedo_range > 0 and dist <= torpedo_range):
			priority *= 10.0

		# Apply flanking priority boost - DDs should intercept flankers
		var flank_info = _get_flanking_info(ship)
		if flank_info.is_flanking:
			# DDs are excellent at intercepting flankers due to speed and torpedoes
			var flank_multiplier = 6.0  # High priority for flankers
			var depth_scale = 1.0 + flank_info.penetration_depth
			priority *= flank_multiplier * depth_scale

		# Sort into shootable vs fallback based on line-of-fire check
		# When visible (using guns), prefer targets we can actually hit
		if _ship.visible_to_enemy and dist <= gun_range and can_hit_target(ship):
			if priority > best_shootable_priority:
				best_shootable = ship
				best_shootable_priority = priority
		else:
			if priority > best_fallback_priority:
				best_fallback = ship
				best_fallback_priority = priority

	# Prefer shootable gun targets when visible; otherwise fall back
	# (when hidden, torpedo targets don't need line-of-fire for guns)
	return best_shootable if best_shootable != null else best_fallback

# ============================================================================
# AMMO AND AIM - Class-specific targeting logic
# ============================================================================

func pick_ammo(_target: Ship) -> int:
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _ship.global_position - _target.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var dist = disp.length()
	var offset = Vector3.ZERO

	ammo = ShellParams.ShellType.HE

	match _target.ship_class:
		Ship.ShipClass.BB:
			# HE at battleship superstructure
			ammo = ShellParams.ShellType.HE
			offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.CA:
			# Check if broadside
			if abs(sin(angle)) > sin(deg_to_rad(70)):
				if dist < 500:
					# AP at broadside cruisers waterline < 500
					ammo = ShellParams.ShellType.AP
					offset.y = 0.0
				elif dist < 1000:
					# AP at broadside cruisers when < 1000
					ammo = ShellParams.ShellType.AP
					offset.y = 0.5
				else:
					# HE at cruiser superstructure
					ammo = ShellParams.ShellType.HE
					offset.y = _target.movement_controller.ship_height / 2
			else:
				# HE at cruiser superstructure when angled
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.DD:
			# Check if broadside for AP at waterline
			if abs(sin(angle)) > sin(deg_to_rad(70)) and dist < 1000:
				# AP at broadside destroyers at waterline when < 1000
				ammo = ShellParams.ShellType.AP
				offset.y = 0.0
			else:
				# HE at destroyers
				ammo = ShellParams.ShellType.HE
				offset.y = 1.0
	return offset

# ============================================================================
# NAVINTENT — V4 bot controller interface
# ============================================================================

var base_intent_pos = null
func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	var ctx = SkillContext.create(ship, target, server, self)
	var delta = 1.0 / Engine.physics_ticks_per_second
	_init_flank_identity(ship, server)

	var spotted = server.get_valid_targets(ship.team.team_id)
	var unspotted = server.get_unspotted_enemies(ship.team.team_id)
	var has_spotted = spotted.size() > 0
	var has_targets = has_spotted or not unspotted.is_empty()
	var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp

	# --- Tactical state transitions ---
	match _tactical_state:
		TacticalState.State.HUNTING:
			if has_targets:
				_tactical_state = TacticalState.State.SNEAKING
		TacticalState.State.SNEAKING:
			if ship.visible_to_enemy:
				_tactical_state = TacticalState.State.DISENGAGING
				_bloom_probe.enter()
				_bloom_probe.probe_timeout = 3.0  # DD: shorter probe
		TacticalState.State.ENGAGED:
			if not ship.visible_to_enemy:
				_tactical_state = TacticalState.State.SNEAKING
		TacticalState.State.DISENGAGING:
			_bloom_probe.update(ship, delta)
			if _bloom_probe.went_dark:
				_tactical_state = TacticalState.State.SNEAKING
			elif _bloom_probe.probe_failed:
				_tactical_state = TacticalState.State.ENGAGED

	# --- Execute skill based on state ---
	var intent: NavIntent = null
	match _tactical_state:
		TacticalState.State.HUNTING:
			intent = _skill_hunt.execute(ctx, {})
			_active_skill_name = &"Hunt"
		TacticalState.State.SNEAKING:
			intent = _execute_dd_sneak_skill(ctx)
		TacticalState.State.ENGAGED:
			if hp_ratio < 0.3:
				intent = _skill_retreat.execute(ctx, {})
				if intent:
					_active_skill_name = &"Retreat"
				else:
					intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.6, "angle_to_threat_deg": 25.0})
					if intent:
						_active_skill_name = &"Kite"
			else:
				intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.6, "angle_to_threat_deg": 25.0})
				if intent:
					_active_skill_name = &"Kite"
		TacticalState.State.DISENGAGING:
			intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.7, "angle_to_threat_deg": 30.0})
			if intent:
				_active_skill_name = &"Kite"

	# Fallback
	if intent == null:
		intent = _intent_sail_forward(ship)
		_active_skill_name = &"SailForward"

	# Post-process spread
	var params = get_positioning_params()
	intent = _skill_spread.apply(intent, ctx, {"spread_distance": params.spread_distance, "spread_multiplier": params.spread_multiplier})
	return intent

func _execute_dd_sneak_skill(ctx: SkillContext) -> NavIntent:
	var intent: NavIntent = null
	# If target is BB/CA and has torpedoes: torpedo run
	if ctx.target != null and ctx.target.ship_class != Ship.ShipClass.DD and ctx.ship.torpedo_controller != null:
		intent = _skill_torpedo_run.execute(ctx, {})
		if intent:
			_active_skill_name = &"TorpedoRun"
	# Fallback to flank
	if intent == null:
		intent = _skill_flank.execute(ctx, {"flank_side": _flank_side, "flank_depth": _flank_depth})
		if intent:
			_active_skill_name = &"Flank"
	# Fallback to hunt
	if intent == null:
		intent = _skill_hunt.execute(ctx, {})
		if intent:
			_active_skill_name = &"Hunt"
	return intent

var _fwd = null
func _intent_sail_forward(ship: Ship) -> NavIntent:
	if _fwd == null:
		_fwd = -ship.global_transform.basis.z
	var fwd = _fwd
	fwd.y = 0.0
	if fwd.length_squared() < 0.1:
		fwd = Vector3(0, 0, -1)
	var dest = ship.global_position + fwd.normalized() * 5000.0
	dest.y = 0.0
	dest = _get_valid_nav_point(dest)
	return NavIntent.create(dest, atan2(fwd.x, fwd.z))


func _get_retreat_intent(ship: Ship, enemy: Array[Ship], friendly: Array[Ship], concealment_radius: float, hp_ratio: float, separation: Vector3, server: GameServer) -> NavIntent:
	"""Calculate retreat position when spotted. Returns POSE intent with retreat heading."""
	closest_enemy = enemy[0]
	var closest_enemy_dist = (closest_enemy.global_position - ship.global_position).length()
	for s in enemy:
		var dist = (s.global_position - ship.global_position).length()
		if dist < closest_enemy_dist:
			closest_enemy = s
			closest_enemy_dist = dist

	var retreat_dir = (ship.global_position - closest_enemy.global_position).normalized()
	var desired_position = ship.global_position + retreat_dir * concealment_radius * 2.0

	# Only bias toward team if below 50% HP
	if hp_ratio < 0.5:
		var nearest_friendly_pos = Vector3.ZERO
		if server:
			var nearest_cluster = server.get_nearest_friendly_cluster(ship.global_position, ship.team.team_id)
			if nearest_cluster.size() > 0:
				nearest_friendly_pos = nearest_cluster.center
			else:
				nearest_friendly_pos = server.get_team_avg_position(ship.team.team_id)
		else:
			for s in friendly:
				nearest_friendly_pos += s.global_position
			nearest_friendly_pos /= friendly.size()
		desired_position = desired_position * 0.8 + nearest_friendly_pos * 0.2

	desired_position += separation * 500.0
	desired_position = _get_valid_nav_point(desired_position)
	var retreat_heading = _calc_approach_heading(ship, desired_position)
	return NavIntent.create(desired_position, retreat_heading)


func _get_torpedo_run_intent(ship: Ship, target: Ship, concealment_radius: float, separation: Vector3) -> NavIntent:
	"""Calculate torpedo run position and heading when hidden. Returns POSE intent for
	optimal torpedo launch angle, or POSITION if no torpedo controller."""

	var torpedo_range: float = -1.0
	if ship.torpedo_controller != null:
		torpedo_range = ship.torpedo_controller.get_params()._range

	# Choose flank side (left or right of target)
	var right = target.transform.basis.x * concealment_radius * 1.5
	var right_of = target.global_position + right
	var left_of = target.global_position - right

	right_of = _get_valid_nav_point(right_of)
	left_of = _get_valid_nav_point(left_of)

	var desired_position: Vector3
	if right_of.distance_to(ship.global_position) < left_of.distance_to(ship.global_position):
		desired_position = right_of
	else:
		desired_position = left_of

	desired_position += separation * 500.0
	desired_position = _get_valid_nav_point(desired_position)

	# If we have torpedoes, use POSE to arrive at optimal launch heading
	if torpedo_range > 0:
		var launch_heading = _calculate_torpedo_launch_heading(ship, target, desired_position)
		return NavIntent.create(desired_position, launch_heading)

	# No torpedoes — just navigate to flank position
	var approach_heading = _calc_approach_heading(ship, desired_position)
	return NavIntent.create(desired_position, approach_heading)


func _calculate_torpedo_launch_heading(ship: Ship, target: Ship, launch_pos: Vector3) -> float:
	"""Calculate the heading the DD should face when launching torpedoes.
	DDs want their torpedo tubes (beam-mounted) to bear on the target's predicted path.
	The ideal heading is roughly perpendicular to the line between us and the target,
	so the torpedo tubes point at the target."""

	# Predict where the target will be when torpedoes arrive
	var target_pos = target.global_position
	if target.linear_velocity.length() > 0.5 and ship.torpedo_controller != null:
		#var torp_speed = ship.torpedo_controller.get_params().speed
		var torp_speed = ship.torpedo_controller.get_torp_params().speed
		if torp_speed > 0:
			var dist_to_target = launch_pos.distance_to(target_pos)
			var torp_time = dist_to_target / torp_speed
			target_pos = target_pos + target.linear_velocity * torp_time * 0.5  # conservative lead

	# Direction from launch position to (predicted) target
	var to_target = target_pos - launch_pos
	to_target.y = 0.0
	var target_bearing = atan2(to_target.x, to_target.z)

	# Torpedo tubes are beam-mounted, so we want our beam to face the target
	# That means our heading should be perpendicular to the target bearing
	# Choose the perpendicular closest to our current heading
	var current_heading = _get_ship_heading()

	var perp_right = _normalize_angle(target_bearing + PI / 2.0)
	var perp_left = _normalize_angle(target_bearing - PI / 2.0)

	var diff_right = abs(_normalize_angle(perp_right - current_heading))
	var diff_left = abs(_normalize_angle(perp_left - current_heading))

	# Slight bias toward the perpendicular that keeps us moving away (escape route)
	var away_from_target = _normalize_angle(target_bearing + PI)
	var right_escape = abs(_normalize_angle(perp_right - away_from_target))
	var left_escape = abs(_normalize_angle(perp_left - away_from_target))

	# Blend heading preference (60% ease of turn, 40% escape route)
	var right_score = diff_right * 0.6 + right_escape * 0.4
	var left_score = diff_left * 0.6 + left_escape * 0.4

	if right_score <= left_score:
		return perp_right
	else:
		return perp_left

# ============================================================================
# COMBAT - DD-specific engagement with torpedo logic
# ============================================================================

## Compute approach heading from ship to destination
func _calc_approach_heading(ship: Ship, dest: Vector3) -> float:
	var to_dest = dest - ship.global_position
	to_dest.y = 0.0
	if to_dest.length_squared() > 1.0:
		return atan2(to_dest.x, to_dest.z)
	return _get_ship_heading()

func engage_target(target: Ship):
	# Track torpedo hits and floods
	var current_torpedo_count = _ship.stats.torpedo_count
	var current_flood_count = _ship.stats.flood_count

	if current_torpedo_count > last_torpedo_count:
		last_torpedo_count = current_torpedo_count

	if current_flood_count > last_flood_count:
		last_flood_count = current_flood_count
		target_is_flooding = true

	# Determine if we should shoot guns
	var should_shoot_guns = false
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	# if hp_ratio < 0.3:
	# 	# Low health - prioritize stealth
	# 	should_shoot_guns = false
	if _bloom_probe.can_fire():
		# Spotted and within detection range
		should_shoot_guns = true
	# elif target_is_flooding:
	# 	# Target is flooding from our torpedoes
	# 	should_shoot_guns = true

	if should_shoot_guns and can_fire_guns():
		super.engage_target(target)
		target_is_flooding = false

	# Fire torpedoes using base class torpedo system
	update_torpedo_aim(target)

	torpedo_fire_timer += 1.0 / Engine.physics_ticks_per_second
	if torpedo_fire_timer >= torpedo_fire_interval:
		torpedo_fire_timer = 0.0
		try_fire_torpedoes(target)
