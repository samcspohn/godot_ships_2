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

# Cover recalculation cooldown (ms) — when spotted, recalc at most this often
const _COVER_RECALC_COOLDOWN_MS: int = 3000
var _cover_recalc_ms: int = 0

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
		Ship.ShipClass.BB: return 2.5
		Ship.ShipClass.CA: return 1.2
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
	var hunting = not _nav_destination_valid and _last_known_enemy_valid
	var shooting_ok = is_in_cover or hunting or (_ship.visible_to_enemy and not _fire_suppressed)
	if not shooting_ok:
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
	var is_broadside = abs(sin(angle)) > sin(deg_to_rad(60))

	match _target.ship_class:
		Ship.ShipClass.BB:
			if is_broadside and dist < 6000:
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 4
			else:
				offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.CA:
			if is_broadside:
				if dist < 7000:
					ammo = ShellParams.ShellType.AP
					offset.y = 0.5
				elif dist < 10000:
					ammo = ShellParams.ShellType.AP
					offset.y = _target.movement_controller.ship_height / 4
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
	_ensure_safe_dir(ship, server)

	var spotted = server.get_valid_targets(ship.team.team_id)
	var unspotted = server.get_unspotted_enemies(ship.team.team_id)
	var has_spotted = spotted.size() > 0
	var has_enemies = has_spotted or not unspotted.is_empty()

	# Recompute safe direction if enemies are known
	if has_enemies:
		var new_safe_dir = _compute_safe_direction(ship, server)
		if _nav_destination_valid and _cached_safe_dir.dot(new_safe_dir) < SAFE_DIR_INVALIDATION_DOT:
			_nav_destination_valid = false
		_cached_safe_dir = new_safe_dir

	_update_enemy_tracking(ship, server, spotted)

	# HUNT: no enemies known — head toward last known position
	if not has_enemies:
		_nav_destination_valid = false
		_cover_zone_valid = false
		if _last_known_enemy_valid:
			return _intent_hunt(ship)
		return _intent_sail_forward(ship)

	# HUNT (stale): enemies are only known from stale unspotted positions.
	if not has_spotted:
		_nav_destination_valid = false
		_cover_zone_valid = false
		if _last_known_enemy_valid:
			return _intent_hunt(ship)
		return _intent_sail_forward(ship)

	# Change island after 20s without in-range targets — push up toward the fight.
	if _nav_destination_valid and Time.get_ticks_msec() - _last_in_range_ms > 20000:
		_nav_destination_valid = false
		_fire_suppressed = true
		_last_in_range_ms = Time.get_ticks_msec()

	# Find a new island if we don't have one — scored to push toward the fight.
	if not _nav_destination_valid:
		var island = _get_cover_position(_get_desired_range(), target)
		if not island.is_empty():
			_set_island_from_result(island)
		else:
			# No island available — angle toward target and fight in the open.
			_cover_zone_valid = false
			var angle_target = target if target else _pick_nearest_spotted(ship, spotted)
			if angle_target:
				return _intent_angle(ship, angle_target)
			return _intent_sail_forward(ship)

	# Periodically recalculate cover position on the current island to find
	# a spot that restores concealment (and ideally keeps shootability).
	var now_ms = Time.get_ticks_msec()
	if now_ms - _cover_recalc_ms >= _COVER_RECALC_COOLDOWN_MS:
		_cover_recalc_ms = now_ms
		var gun_range = _ship.artillery_controller.get_params()._range
		var pos_params = get_positioning_params()
		var cover_desired_range = gun_range * pos_params.base_range_ratio
		var island = _get_cover_position(cover_desired_range, target)
		if not island.is_empty():
			_set_island_from_result(island)
		else:
			_cover_zone_valid = false
			var angle_target = target if target else _pick_nearest_spotted(ship, spotted)
			if angle_target:
				return _intent_angle(ship, angle_target)
			return _intent_sail_forward(ship)

	# Approach / station-keep
	var dist_to_dest = ship.global_position.distance_to(_nav_destination)
	var clearance = _get_ship_clearance()
	var arrival_radius = clearance * 2.0
	# Hysteresis: once in cover, allow a larger drift before losing cover status.
	var exit_radius = clearance * 3.5
	var arrived: bool
	if is_in_cover:
		arrived = dist_to_dest < exit_radius
	else:
		arrived = dist_to_dest < arrival_radius
	var heading = _tangential_heading(_target_island_pos, _nav_destination)

	is_in_cover = arrived
	if arrived:
		_fire_suppressed = false

	# Check if shells can arc over terrain to any spotted target.
	# When arrived, test from ship position; when en route, test from destination.
	var check_pos = ship.global_position if arrived else _nav_destination
	_cover_can_shoot = false
	var shell_params = ship.artillery_controller.get_shell_params()
	if shell_params != null:
		var gun_range = ship.artillery_controller.get_params()._range
		for enemy in spotted:
			if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
				continue
			var tgt_pos = enemy.global_position + target_aim_offset(enemy)
			if check_pos.distance_to(tgt_pos) > gun_range:
				continue
			var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(check_pos, tgt_pos, shell_params)
			if sol[0] == null:
				continue
			var result = Gun.sim_can_shoot_over_terrain_static(check_pos, sol[0], sol[1], shell_params, ship)
			if result.can_shoot_over_terrain:
				_cover_can_shoot = true
				break

	if arrived:
		var intent = _make_intent(_nav_destination, heading, arrival_radius * 0.5)
		intent.near_terrain = true
		if dist_to_dest > arrival_radius:
			intent.throttle_override = -1
		return intent

	var intent = _make_intent(_nav_destination, heading)
	intent.near_terrain = true
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
