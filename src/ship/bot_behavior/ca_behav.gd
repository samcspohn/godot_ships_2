extends BotBehavior
class_name CABehavior

const SAFE_DIR_INVALIDATION_DOT: float = cos(deg_to_rad(20.0))

var ammo = ShellParams.ShellType.HE

# ============================================================================
# STATE TRACKING
# ============================================================================

# Cover zone state — kept for debug.gd compatibility
var _cover_zone_valid: bool = false
var _cover_zone_radius: float = 200.0
var _cover_can_shoot: bool = false
var _cover_island_center: Vector3 = Vector3.ZERO
var _cover_island_radius: float = 0.0

# Current island target (-1 = none)
var _target_island_id: int = -1
var _target_island_pos: Vector3 = Vector3.ZERO
var _target_island_radius: float = 0.0
var _nav_destination: Vector3 = Vector3.ZERO
var _nav_destination_valid: bool = false

# Engagement tracking
var _last_in_range_ms: int = 0
var _last_known_enemy_pos: Vector3 = Vector3.ZERO
var _last_known_enemy_valid: bool = false

var _fire_suppressed: bool = false
var _suppress_guns: bool = false

# Cover recalculation cooldown (ms) — when spotted, recalc at most this often
const _COVER_RECALC_COOLDOWN_MS: int = 3000
var _cover_recalc_ms: int = 0

# Skills
var _skill_hunt: SkillHunt = SkillHunt.new()
var _skill_chase: SkillChase = SkillChase.new()
var _skill_cover: SkillFindCover = SkillFindCover.new()
var _skill_angle: SkillAngle = SkillAngle.new()
var _skill_kite: SkillKite = SkillKite.new()
var _skill_flank: SkillFlank = SkillFlank.new()
var _skill_spot: SkillSpot = SkillSpot.new()
var _skill_spread: SkillSpread = SkillSpread.new()
var _skill_broadside: SkillBroadside = SkillBroadside.new()

# ============================================================================
# WEIGHT CONFIGURATION
# ============================================================================

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(30),
		max_angle = deg_to_rad(45),
		evasion_period = 5.0,
		vary_speed = false
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 0.5
	return 1.0

func get_target_weights() -> Dictionary:
	return {
		size_weight = 0.4,
		range_weight = 0.6,
		hp_weight = 0.0,
		class_modifiers = {
			Ship.ShipClass.BB: 1.0,
			Ship.ShipClass.CA: 1.2,
			Ship.ShipClass.DD: 1.5,
		},
		prefer_broadside = true,
		in_range_multiplier = 10.0,
		flanking_multiplier = 5.0,
		overextension_weight = 0.4,  # CAs balance between close threats and overextended enemies
		proximity_override_distance = 3000.0,
		overextension_bonus = 2.0,
	}

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.65,
		range_increase_when_damaged = 0.30,
		min_safe_distance_ratio = 0.40,
		flank_bias_healthy = 0.6,
		flank_bias_damaged = 0.2,
		spread_distance = 2000.0,
		spread_multiplier = 2.0,
	}

func get_island_cover_params() -> Dictionary:
	return {
		aggressive_range = 0.60,
		defensive_range = 0.70,
		abandon_too_close = 0.35,
		abandon_too_far = 0.80,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.3,
		cautious_hp_threshold = 0.5,
	}

func should_evade(_destination: Vector3) -> bool:
	if not _ship.visible_to_enemy:
		return false
	return true

func get_theatened(server: GameServer) -> bool:
	## TODO: add dispersion + caliber checks to this
	var spotted = server.get_valid_targets(_ship.team.team_id)
	var my_hp = _ship.health_controller.current_hp
	var hp_ratio = my_hp / _ship.health_controller.max_hp
	var desired_dist = clampf(1.0 - hp_ratio + 0.5, 0.5, 1.0)
	for enemy in spotted:
		var dist = enemy.global_position.distance_to(_ship.global_position)
		var enemy_range = enemy.artillery_controller.get_params()._range
		var enemy_hp = enemy.health_controller.current_hp
		match enemy.ship_class:
			Ship.ShipClass.BB:
				if dist < enemy_range * clamp(desired_dist, 0.7, 1.0) and enemy_hp > my_hp * 0.5:
					return true
			Ship.ShipClass.CA:
				if dist < enemy_range * desired_dist and enemy_hp > my_hp:
					return true
			Ship.ShipClass.DD:
				pass
	return false

# ============================================================================
# AMMO AND AIM
# ============================================================================

func _can_shoot_over(target: Ship) -> bool:
	var target_pos = target.global_position + target_aim_offset(target)
	for gun in _ship.artillery_controller.guns:
		if gun.sim_can_shoot_over_terrain(target_pos):
			return true
	return false

func engage_target(target: Ship) -> void:
	var aim_pos = target.global_position + target_aim_offset(target)
	if not can_fire_guns():
		_ship.artillery_controller.set_aim_input(aim_pos)
		return
	if _suppress_guns:
		_ship.artillery_controller.set_aim_input(aim_pos)
		return
	super.engage_target(target)

func pick_ammo(_target: Ship) -> int:
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _ship.global_position - _target.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var dist = disp.length()
	var offset = Vector3.ZERO

	ammo = ShellParams.ShellType.HE
	var is_broadside = abs(sin(angle)) > sin(deg_to_rad(45))

	match _target.ship_class:
		Ship.ShipClass.BB:
			if is_broadside and dist < 8000:
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 4
			else:
				offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.CA:
			if is_broadside:
				if dist < 10000:
					ammo = ShellParams.ShellType.AP
					offset.y = 0.5
				# elif dist < 10000:
				# 	ammo = ShellParams.ShellType.AP
				# 	offset.y = _target.movement_controller.ship_height / 4
				else:
					offset.y = _target.movement_controller.ship_height / 3
			else:
				offset.y = _target.movement_controller.ship_height / 3
		Ship.ShipClass.DD:
			offset.y = 1.0

	return offset

# ============================================================================
# ENEMY TRACKING
# ============================================================================

func _update_enemy_tracking(ship: Ship, server: GameServer, spotted: Array) -> void:
	var gun_range = ship.artillery_controller.get_params()._range
	for enemy in spotted:
		if enemy.global_position.distance_to(ship.global_position) <= gun_range:
			_last_in_range_ms = Time.get_ticks_msec()
			break
	# Track nearest known enemy for hunting
	var best_dist = INF
	for enemy in spotted:
		var d = enemy.global_position.distance_to(ship.global_position)
		if d < best_dist:
			best_dist = d
			_last_known_enemy_pos = enemy.global_position
			_last_known_enemy_valid = true
	for pos in server.get_unspotted_enemies(ship.team.team_id).values():
		var d = pos.distance_to(ship.global_position)
		if d < best_dist:
			best_dist = d
			_last_known_enemy_pos = pos
			_last_known_enemy_valid = true

# ============================================================================
# HUNTING — move toward last known enemy position
# ============================================================================

func _intent_hunt(ship: Ship) -> NavIntent:
	var to_enemy = _last_known_enemy_pos - ship.global_position
	to_enemy.y = 0.0
	if to_enemy.length() < 500.0:
		_last_known_enemy_valid = false
		return _intent_sail_forward(ship)
	var dest = _get_valid_nav_point(_last_known_enemy_pos)
	var heading = atan2(to_enemy.x, to_enemy.z)
	var intent = NavIntent.create(dest, heading)
	intent.throttle_override = 4
	return intent

# ============================================================================
# ANGLING — maintain armor angle toward target
# ============================================================================

func _get_angle_range(ship_class: Ship.ShipClass) -> Vector2:
	match ship_class:
		Ship.ShipClass.BB: return Vector2(deg_to_rad(25), deg_to_rad(31))
		Ship.ShipClass.CA: return Vector2(deg_to_rad(0), deg_to_rad(30))
		Ship.ShipClass.DD: return Vector2(deg_to_rad(0), deg_to_rad(40))
	return Vector2(deg_to_rad(0), deg_to_rad(30))

func _intent_angle(ship: Ship, target: Ship) -> NavIntent:
	var to_enemy = target.global_position - ship.global_position
	to_enemy.y = 0.0
	var enemy_bearing = atan2(to_enemy.x, to_enemy.z)
	var angle_range = _get_angle_range(target.ship_class)
	var desired = (angle_range.x + angle_range.y) * 0.5
	var cw = _normalize_angle(enemy_bearing + desired)
	var ccw = _normalize_angle(enemy_bearing - desired)

	# Score each candidate heading against all secondary threats.
	var server_node: GameServer = ship.get_node_or_null("/root/Server")
	var cw_score: float = 0.0
	var ccw_score: float = 0.0
	if server_node != null:
		var all_threats = _gather_threat_positions(ship)
		for threat_pos in all_threats:
			if threat_pos.distance_to(target.global_position) < 50.0:
				continue
			var to_threat = threat_pos - ship.global_position
			to_threat.y = 0.0
			if to_threat.length_squared() < 1.0:
				continue
			var threat_dir = to_threat.normalized()
			var cw_fwd = Vector3(sin(cw), 0.0, cos(cw))
			var ccw_fwd = Vector3(sin(ccw), 0.0, cos(ccw))
			var cw_side = Vector3(cw_fwd.z, 0.0, -cw_fwd.x)
			var ccw_side = Vector3(ccw_fwd.z, 0.0, -ccw_fwd.x)
			cw_score += abs(cw_side.dot(threat_dir))
			ccw_score += abs(ccw_side.dot(threat_dir))

	var heading: float
	if abs(cw_score - ccw_score) > 0.05:
		heading = cw if cw_score < ccw_score else ccw
	else:
		var current = _get_ship_heading()
		heading = cw if abs(_normalize_angle(cw - current)) < abs(_normalize_angle(ccw - current)) else ccw

	# Maintain engagement range while angling
	var gun_range = ship.artillery_controller.get_params()._range
	var desired_dist = gun_range * 0.55
	var enemy_dist = to_enemy.length()
	var fwd = Vector3(sin(heading), 0.0, cos(heading))
	var dest = ship.global_position + fwd * 1000.0
	if enemy_dist > gun_range:
		var close_dist = (enemy_dist - desired_dist) * 0.8
		dest = ship.global_position + to_enemy.normalized() * close_dist
	elif enemy_dist > desired_dist * 1.3:
		var close_dist = (enemy_dist - desired_dist) * 0.5
		dest = ship.global_position + to_enemy.normalized() * close_dist
	elif enemy_dist < desired_dist * 0.4:
		dest = ship.global_position - to_enemy.normalized() * 1000.0
	dest.y = 0.0
	dest = _get_valid_nav_point(dest)
	return NavIntent.create(dest, heading)

# ============================================================================
# ISLAND STATE HELPER
# ============================================================================

func _set_island_state(id: int, center: Vector3, radius: float, dest: Vector3) -> void:
	_target_island_id = id
	_target_island_pos = center
	_target_island_radius = radius
	_nav_destination = dest
	_nav_destination_valid = true

	if _last_in_range_ms == 0:
		_last_in_range_ms = Time.get_ticks_msec()
	_cover_island_center = center
	_cover_island_radius = radius
	_cover_zone_valid = true
	_cover_zone_radius = _get_ship_clearance() * 3.0

func _set_island_from_result(island: Dictionary) -> void:
	"""Apply a result dictionary from _get_cover_position() to island state."""
	_set_island_state(island["id"], island["center"], island["radius"], island["dest"])

# ============================================================================
# DESIRED RANGE — compute the engagement range from positioning params + HP
# ============================================================================

func _get_desired_range() -> float:
	var gun_range = _ship.artillery_controller.get_params()._range
	var pos_params = get_positioning_params()
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp
	var desired = pos_params.base_range_ratio * gun_range
	desired += pos_params.range_increase_when_damaged * gun_range * (1.0 - hp_ratio)
	return desired

# ============================================================================
# NAVINTENT HELPERS
# ============================================================================

func _make_intent(dest: Vector3, heading: float, arrival_radius: float = 0.0) -> NavIntent:
	if arrival_radius > 0.0:
		return NavIntent.create(dest, heading, arrival_radius)
	return NavIntent.create(dest, heading)

func _pick_nearest_spotted(ship: Ship, spotted: Array) -> Ship:
	var best: Ship = null
	var best_dist: float = INF
	for enemy in spotted:
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		var d = enemy.global_position.distance_to(ship.global_position)
		if d < best_dist:
			best_dist = d
			best = enemy
	return best

# ============================================================================
# NAVINTENT — Primary entry point (V4 bot controller)
# ============================================================================

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	wants_stealth = false  # reset each tick; set true below if conditions are met
	wants_to_be_concealed = false  # reset each tick; set true below via probe
	_ensure_safe_dir(ship, server)
	_init_flank_identity(ship, server)
	var ctx = SkillContext.create(ship, target, server, self)

	# Cover debug sync (kept for debug.gd compatibility)
	is_in_cover = _skill_cover.is_complete(ctx)
	_cover_can_shoot = _skill_cover.can_shoot
	if _skill_cover._nav_destination_valid:
		_cover_zone_valid = true
		_cover_island_center = _skill_cover._target_island_pos
		_cover_island_radius = _skill_cover._target_island_radius
	else:
		_cover_zone_valid = false

	var spotted = server.get_valid_targets(ship.team.team_id)
	var unspotted = server.get_unspotted_enemies(ship.team.team_id)
	var has_spotted = spotted.size() > 0
	var has_enemies = has_spotted or not unspotted.is_empty()
	_update_enemy_tracking(ship, server, spotted)

	var desired_range = _get_desired_range()
	var cover_params = {
		"desired_range": desired_range,
		"recalc_cooldown_ms": _COVER_RECALC_COOLDOWN_MS,
		"push_timeout_ms": 20000
	}

	var intent: NavIntent = null
	_suppress_guns = false

	# ── No enemies at all ───────────────────────────────────────────────────
	if not has_enemies:
		intent = _skill_hunt.execute(ctx, {})
		if intent != null:
			_active_skill_name = &"Hunt"
		if intent == null:
			intent = _intent_sail_forward(ship)
			_active_skill_name = &"SailForward"
		return intent

	# ── No spotted (unspotted only) ─────────────────────────────────────────
	if not has_spotted:
		intent = _skill_chase.execute(ctx, {"chase_timeout": 60.0})
		if intent != null:
			_active_skill_name = &"Chase"
		if intent == null:
			intent = _skill_hunt.execute(ctx, {})
			if intent != null:
				_active_skill_name = &"Hunt"
		if intent == null:
			intent = _intent_sail_forward(ship)
			_active_skill_name = &"SailForward"
		return intent

	# ── Threat-score + distance decision tree ───────────────────────────────
	var threat = get_threat_score(server)
	var nearest = _pick_nearest_spotted(ship, spotted)
	var dist = ship.global_position.distance_to(nearest.global_position) if nearest else INF
	var gun_range = ship.artillery_controller.get_params()._range

	# if threat < 0.49:
	# 	# Low threat — push and engage
	# 	intent = _skill_angle.execute(ctx, {"desired_range_ratio": 0.5})
	# 	if intent != null:
	# 		_active_skill_name = &"Push"

	# elif threat < 0.6:
	# 	# Medium threat
	# 	if dist > gun_range:
	# 		intent = _skill_angle.execute(ctx, {"desired_range_ratio": 0.6})
	# 		if intent != null:
	# 			_active_skill_name = &"Angle"
	# 	elif dist > 5000.0:
	# 		intent = _skill_cover.execute(ctx, cover_params)
	# 		if intent != null:
	# 			_active_skill_name = &"FindCover"
	# 		else:
	# 			intent = _skill_angle.execute(ctx, {"desired_range_ratio": 0.65})
	# 			if intent != null:
	# 				_active_skill_name = &"Angle"
	# 	else:
	# 		intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.6})
	# 		if intent != null:
	# 			_active_skill_name = &"Kite"

	# else:
	# 	# High threat (>= 0.6)
	# 	if dist < 5000.0:
	# 		intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.65, "angle_to_threat_deg": 25.0})
	# 		if intent != null:
	# 			_active_skill_name = &"AngledReverse"
	# 		_suppress_guns = false
	# 	else:
	# 		intent = _skill_cover.execute(ctx, cover_params, true)
	# 		if intent != null:
	# 			_active_skill_name = &"FindCover"
	# 		# _suppress_guns = not _skill_cover.is_complete(ctx)
	# 		# Route around detection zones only when undetected, heading to cover,
	# 		# and not carrying torpedoes (torpedo CAs push close regardless)
	# 		wants_stealth = not ship.visible_to_enemy and ship.torpedo_controller == null
	# 		# Concealment probe: suppress guns when detected + bloom active + enemy
	# 		# far enough that going dark would drop us off detection.
	# 		# Only applies for non-torpedo CAs in cover-seeking mode.
	# 		if ship.torpedo_controller == null:
	# 			wants_to_be_concealed = _probe_concealment(server)
	# 		if wants_to_be_concealed:
	# 			_suppress_guns = true

	# _suppress_guns = false
	# # ── Fallback ────────────────────────────────────────────────────────────
	# if intent == null:
	# 	intent = _skill_angle.execute(ctx, {})
	# 	if intent != null:
	# 		_active_skill_name = &"Angle"
	# if intent == null:
	# 	intent = _intent_sail_forward(ship)
	# 	_active_skill_name = &"SailForward"
	if threat < 0.5:
		intent = _skill_angle.execute(ctx, {"desired_range_ratio": 0.0})
		if intent != null:
			_active_skill_name = &"Push"
	else:
		intent = _skill_cover.execute(ctx, cover_params, true)
		if intent != null:
			_active_skill_name = &"FindCover"
		else:
			intent = _skill_angle.execute(ctx, {"desired_range_ratio": 0.65})
			if intent != null:
				_active_skill_name = &"Angle"

	if threat > 0.85:
		wants_stealth = true
		wants_to_be_concealed = _probe_concealment(server)
	else:
		wants_stealth = false
		wants_to_be_concealed = false

	if wants_to_be_concealed:
		_suppress_guns = true


	# ── Post-process: broadside ──────────────────────────────────────────────
	if _active_skill_name in [&"Kite", &"Angle", &"AngledReverse", &"Push"]:
		intent = _skill_broadside.apply(intent, ctx, {"oscillation_bias": 0.4})

	# ── Post-process: spread ─────────────────────────────────────────────────
	var pos_params = get_positioning_params()
	if _active_skill_name not in [&"FindCover", &"Angle", &"Kite", &"AngledReverse"]:
		intent = _skill_spread.apply(intent, ctx, {
			"spread_distance": pos_params.spread_distance,
			"spread_multiplier": pos_params.spread_multiplier
		})

	return intent

func _execute_ca_sneak_skill(ctx: SkillContext, cover_params: Dictionary) -> NavIntent:
	var intent = _skill_cover.execute(ctx, cover_params)
	if intent != null:
		_active_skill_name = &"FindCover"
		return intent
	# No island — try flanking
	var hp_ratio = ctx.ship.health_controller.current_hp / ctx.ship.health_controller.max_hp
	if hp_ratio > 0.5:
		intent = _skill_flank.execute(ctx, {"flank_side": _flank_side, "flank_depth": _flank_depth})
		if intent != null:
			_active_skill_name = &"Flank"
	if intent == null:
		intent = _skill_hunt.execute(ctx, {})
		if intent != null:
			_active_skill_name = &"Hunt"
	return intent

func _execute_ca_engaged_skill(ctx: SkillContext, cover_params: Dictionary, threatened: bool, any_targets: bool) -> NavIntent:
	var intent
	# If at cover, stay there
	if _skill_cover.is_complete(ctx):
		intent = _skill_cover.execute(ctx, cover_params)
		if intent != null:
			_active_skill_name = &"FindCover"
		return intent
	# Try new cover
	if not _ship.visible_to_enemy and threatened :
		intent = _skill_cover.execute(ctx, cover_params)
		if intent != null:
			_active_skill_name = &"FindCover"
			return intent
	## TODO: decide on angle vs kite depending on target, outnumbered, and HP ratio
	if not threatened and not any_targets:
		intent = _skill_angle.execute(ctx, {})
		_active_skill_name = &"Angle"
	else:
		intent = _skill_cover.execute(ctx, cover_params, true)
		if _skill_cover.get_dist() < 2500.0:
			_active_skill_name = &"FindCover"
		else:
			intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.8})
			_active_skill_name = &"Kite"
		# var cover_intent = _skill_cover.execute(ctx, cover_params)
		# intent.target_position = intent.target_position * 0.7 + cover_intent.target_position * 0.3 if cover_intent != null else intent.target_position
	return intent

# ============================================================================
# FALLBACK — sail forward when no island available
# ============================================================================

var _fwd = null
func _intent_sail_forward(ship: Ship) -> NavIntent:
	"""Fallback: sail straight ahead."""
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
