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
var _skill_kite: SkillKite = SkillKite.new()
var _skill_flank: SkillFlank = SkillFlank.new()
var _skill_spot: SkillSpot = SkillSpot.new()
var _skill_spread: SkillSpread = SkillSpread.new()
var _skill_broadside: SkillBroadside = SkillBroadside.new()

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

func get_concealment_radius_multiplier() -> float:
	## DDs increase detection-avoidance circle by up to 50% as HP drops,
	## so they route farther around enemies when damaged rather than retreating.
	if _ship == null:
		return 1.0
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp
	return lerp(1.5, 1.0, hp_ratio)

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
	Prefers targets we can actually shoot at over ones behind cover.
	Balances proximity threats against overextended enemies:
	 - Enemies very close get a strong proximity boost.
	 - Enemies farthest into friendly territory get an overextension bonus.
	 - When nothing is dangerously close, the most overextended enemy wins."""
	var gun_range = _ship.artillery_controller.get_params()._range
	var torpedo_range: float = -1.0
	var proximity_override_dist: float = 2500.0  # DDs are fast, smaller threshold
	var overextension_weight: float = 0.3
	var overextension_bonus: float = 1.8

	if _ship.torpedo_controller != null:
		torpedo_range = _ship.torpedo_controller.get_params()._range

	# --- First pass: compute base priority and overextension for every target ---
	var candidate_data: Array[Dictionary] = []
	var max_overextension: float = 0.0
	var has_close_threat: bool = false

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

		# Overextension score: how far into friendly territory this enemy is
		var overext = _get_overextension_score(ship)
		if overext > max_overextension:
			max_overextension = overext

		# Track whether any enemy is dangerously close
		if dist < proximity_override_dist:
			has_close_threat = true

		var shootable = _ship.visible_to_enemy and dist <= gun_range and can_hit_target(ship)
		candidate_data.append({
			ship = ship,
			base_priority = priority,
			dist = dist,
			overextension = overext,
			shootable = shootable,
		})

	# --- Second pass: apply overextension vs proximity weighting ---
	var best_shootable: Ship = null
	var best_shootable_priority: float = -1.0
	var best_fallback: Ship = null
	var best_fallback_priority: float = -1.0

	for data in candidate_data:
		var priority: float = data.base_priority
		var dist: float = data.dist
		var overext: float = data.overextension
		var ship: Ship = data.ship

		# Overextension contribution: reward enemies deeper into friendly territory
		if max_overextension > 0.0 and overextension_weight > 0.0:
			var relative_overext = overext / max_overextension
			var overext_contrib = relative_overext * overextension_weight
			priority += overext_contrib

			# Extra bonus for the most overextended target when nothing is dangerously close
			if not has_close_threat and relative_overext > 0.9:
				priority *= overextension_bonus

		# Proximity override: if this enemy is very close, give a strong boost
		if dist < proximity_override_dist:
			var proximity_factor = 1.0 + 2.0 * (1.0 - dist / proximity_override_dist)
			priority *= proximity_factor

		# Sort into shootable vs fallback
		if data.shootable:
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
	wants_stealth = false  # reset each tick; set true below if undetected
	wants_to_be_concealed = false  # reset each tick; set true below via probe
	var ctx = SkillContext.create(ship, target, server, self)
	_init_flank_identity(ship, server)

	var spotted   = server.get_valid_targets(ship.team.team_id)
	var unspotted = server.get_unspotted_enemies(ship.team.team_id)
	var has_targets = spotted.size() > 0 or not unspotted.is_empty()

	var hp_ratio          = ship.health_controller.current_hp / ship.health_controller.max_hp
	var concealment_radius: float = (ship.concealment.params.p() as ConcealmentParams).radius
	var pos_params        = get_positioning_params()

	var intent: NavIntent = null

	# ── 1. No enemies → hunt ─────────────────────────────────────────────────
	if not has_targets:
		intent = _skill_hunt.execute(ctx, {})
		_active_skill_name = &"Hunt"

	# ── 2. Target is a DD → kite + broadside post-process, fallback hunt ──────
	elif target != null and target.ship_class == Ship.ShipClass.DD:
		intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.5, "angle_to_threat_deg": 20.0})
		if intent:
			_active_skill_name = &"Kite"
			intent = _skill_broadside.apply(intent, ctx, {"oscillation_bias": 0.3})
		else:
			intent = _skill_hunt.execute(ctx, {})
			_active_skill_name = &"Hunt"

	# ── 3. No torpedo controller → spot, fallback hunt ───────────────────────
	elif ship.torpedo_controller == null:
		intent = _skill_spot.execute(ctx, {"approach_distance": concealment_radius})
		_active_skill_name = &"Spot"
		if intent == null:
			intent = _skill_hunt.execute(ctx, {})
			_active_skill_name = &"Hunt"

	# ── 4. Torpedoes ready → torpedo run (non-DD targets only) ───────────────
	elif _get_max_torp_reload() >= 1.0 and target != null and target.ship_class != Ship.ShipClass.DD:
		intent = _skill_torpedo_run.execute(ctx, {})
		if intent:
			_active_skill_name = &"TorpedoRun"
		# Null intent — fall through to spotting
		if intent == null:
			intent = _skill_spot.execute(ctx, {"approach_distance": concealment_radius})
			_active_skill_name = &"Spot"
			if intent == null:
				intent = _skill_hunt.execute(ctx, {})
				_active_skill_name = &"Hunt"

	# ── 5. Reloading → spot, fallback hunt ───────────────────────────────────
	else:
		intent = _skill_spot.execute(ctx, {"approach_distance": concealment_radius})
		_active_skill_name = &"Spot"
		if intent == null:
			intent = _skill_hunt.execute(ctx, {})
			_active_skill_name = &"Hunt"

	# Final fallback
	if intent == null:
		intent = _intent_sail_forward(ship)
		_active_skill_name = &"SailForward"

	# DDs always want stealth routing when undetected — both spotting runs and
	# torpedo approaches rely on staying outside enemy detection zones in transit
	wants_stealth = not ship.visible_to_enemy

	# Concealment probe: suppress guns when detected + bloom active + enemy
	# is far enough away that going dark would actually drop us off detection.
	# DDs should always try to go dark when the opportunity exists.
	wants_to_be_concealed = _probe_concealment(server)

	# Post-process spread (skip for Retreat and Kite)
	if _active_skill_name != &"Retreat" and _active_skill_name != &"Kite":
		intent = _skill_spread.apply(intent, ctx, {
			"spread_distance": pos_params.spread_distance,
			"spread_multiplier": pos_params.spread_multiplier,
		})

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
	# Guns only when already spotted (revealing position is already done)
	if _ship.visible_to_enemy and can_fire_guns():
		super.engage_target(target)
	else:
		# Aim turrets but don't fire
		_ship.artillery_controller.set_aim_input(target.global_position + target_aim_offset(target))

	# Torpedoes are always managed
	update_torpedo_aim(target)
	torpedo_fire_timer += 1.0 / Engine.physics_ticks_per_second
	if torpedo_fire_timer >= torpedo_fire_interval:
		torpedo_fire_timer = 0.0
		try_fire_torpedoes(target)
