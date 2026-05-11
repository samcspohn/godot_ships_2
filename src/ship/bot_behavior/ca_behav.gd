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
# var _suppress_guns: bool = false

# Cover recalculation cooldown (ms) — when spotted, recalc at most this often
const _COVER_RECALC_COOLDOWN_MS: int = 3000
var _cover_recalc_ms: int = 0

# Skills
var _skill_hunt: SkillHunt = SkillHunt.new()
var _skill_chase: SkillChase = SkillChase.new()
var _skill_cover: SkillFindCover = SkillFindCover.new()
var _skill_kite: SkillKite = SkillKite.new()
var _skill_flank: SkillFlank = SkillFlank.new()
var _skill_spread: SkillSpread = SkillSpread.new()
var _skill_broadside: SkillBroadside = SkillBroadside.new()
var _skill_push: SkillPush = SkillPush.new()

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
		Ship.ShipClass.BB: return 1.4
		Ship.ShipClass.CA: return 1.4
		Ship.ShipClass.DD: return 0.3
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
		base_range_ratio = 0.7,
		range_increase_when_damaged = 0.30,
		min_safe_distance_ratio = 0.40,
		flank_bias_healthy = 0.6,
		flank_bias_damaged = 0.2,
		spread_distance = 2000.0,
		spread_multiplier = 2.0,
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
	var target_pos = target.global_position + target.global_basis * target_aim_offset(target)
	for gun in _ship.artillery_controller.guns:
		if gun.sim_can_shoot_over_terrain(target_pos):
			return true
	return false

func engage_target(target: Ship) -> void:
	var aim_pos = target.global_position + target.global_basis * target_aim_offset(target)
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
	var dist_ratio: float = dist / _ship.artillery_controller.get_params()._range

	ammo = ShellParams.ShellType.HE
	var ap_auto_bounce: float = _ship.artillery_controller.get_params().shell1.auto_bounce
	var is_broadside = abs(angle - PI / 2.0) < lerp(ap_auto_bounce, PI * 0.25, pow(dist_ratio, 3.0))
	var bow_in = angle < PI / 2.0
	var stern_in = !bow_in

	match _target.ship_class:
		Ship.ShipClass.BB:
			if dist < 6000: # brawling range
				if is_broadside:
					ammo = ShellParams.ShellType.AP
					if _target.health_controller.casemate.pool1 > 0:
						offset.y = _target.movement_controller.ship_height / 4
					elif _target.health_controller.bow.pool1 > 0 and bow_in:
						offset.z = -_target.movement_controller.ship_length / 4
						offset.y = _target.movement_controller.ship_height / 5
					elif _target.health_controller.stern.pool1 > 0 and stern_in:
						offset.z = _target.movement_controller.ship_length / 4
						offset.y = _target.movement_controller.ship_height / 5
					else:
						offset.y = _target.movement_controller.ship_height / 4
				else:
					ammo = ShellParams.ShellType.HE
					if _target.health_controller.bow.pool1 > 0 and bow_in:
						offset.z = -_target.movement_controller.ship_length / 4
						offset.y = _target.movement_controller.ship_height / 5
					elif _target.health_controller.stern.pool1 > 0 and stern_in:
						offset.z = _target.movement_controller.ship_length / 4
						offset.y = _target.movement_controller.ship_height / 5
					else: # superstrucure
						offset.y = _target.movement_controller.ship_height / 2

			if is_broadside and dist < 12000:
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 4
			else: # angled and/or farther than 6000
				var fire_pos = null
				var priority_fires = [1,2,0,3]
				for i in priority_fires:
				# for fire: Fire in _target.fire_manager.fires:
					var fire: Fire = _target.fire_manager.fires[i]
					if fire.lifetime <= 0:
						fire_pos = fire.position
						break
				if fire_pos != null:
					offset = fire_pos
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
	var best_dist = INF
	for enemy in spotted:
		var d = enemy.global_position.distance_to(ship.global_position)
		if d <= gun_range:
			_last_in_range_ms = Time.get_ticks_msec()
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

func _get_desired_range(pos_params: Dictionary) -> float:
	var gun_range = _ship.artillery_controller.get_params()._range
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

	var pos_params = get_positioning_params()
	# var desired_range = _get_desired_range(pos_params)
	var cover_params = {
		"desired_range": pos_params.base_range_ratio,
	}

	var intent: NavIntent = null
	_suppress_guns = false
	var previous_intent = _active_skill_name

	# ── No enemies at all ───────────────────────────────────────────────────
	if not has_enemies:
		# intent = _skill_hunt.execute(ctx, {})
		# if intent != null:
		# 	_active_skill_name = &"Hunt"
		# if intent == null:
		# 	intent = _intent_sail_forward(ship)
		# 	_active_skill_name = &"SailForward"
		# return intent
		intent = _skill_cover.execute(ctx, cover_params, true)
		if intent != null:
			_active_skill_name = &"FindCover"
			return intent
		intent = _skill_flank.execute(ctx, {})
		if intent != null:
			_active_skill_name = &"Flank"
		if intent == null:
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
	var threat = get_threat_score(ctx)
	var nearest = _pick_nearest_spotted(ship, spotted)
	var dist = ship.global_position.distance_to(nearest.global_position) if nearest else INF
	var gun_range = ship.artillery_controller.get_params()._range

	var nearest_unspotted_dist = INF
	for pos in unspotted.values():
		var d = ship.global_position.distance_to(pos)
		if d < nearest_unspotted_dist:
			nearest_unspotted_dist = d

	if threat < 0.5:
		# Push toward the enemy — but prefer a closer unspotted enemy
		# over crossing the map to fight a distant detected one.
		var _unspotted_near = _nearest_unspotted_info(server)
		if not _unspotted_near.is_empty() and _unspotted_near.distance < dist and dist > gun_range:
			intent = _skill_chase.execute(ctx, {})
			if intent != null:
				_active_skill_name = &"Chase"
		if intent == null:
			intent = _skill_push.execute(ctx, {})
			if intent != null:
				_active_skill_name = &"Push"
	elif (dist < 8000.0 or nearest_unspotted_dist < 8000.0) and ship.visible_to_enemy:
		# # High threat and enemy is close — find the optimal presentation angle
		# # then choose angle skill (bow-in) or kite (stern-in) accordingly.
		# var to_nearest = nearest.global_position - ship.global_position
		# to_nearest.y = 0.0
		# # var enemy_bearing = atan2(to_nearest.x, to_nearest.z)
		var angle_to_enemy = SkillAngle.calc_heading(ctx, {})
		# # if absf(angle_difference(optimal_heading, enemy_bearing)) > PI * 0.5:
		# # 	optimal_heading = wrapf(optimal_heading + PI, -PI, PI)
		var bow_diff = absf(angle_difference(angle_to_enemy, _get_ship_heading()))
		if threat < 0.5:
			# Optimal heading is bow-in — push toward enemy
			intent = _skill_push.execute(ctx, {})
			if intent != null:
				_active_skill_name = &"Push"
				# threat behind — reverse to close the gap stern-first
				if bow_diff > PI * 0.5:
					intent.force_reverse = true
					intent.target_heading = wrapf(intent.target_heading + PI, -PI, PI)

		else:
			# Optimal heading is stern-in — kite away while keeping guns on target
			intent = _skill_kite.execute(ctx, {})
			if intent != null:
				_active_skill_name = &"Kite"
				# threat is ahead — reverse away from enemy
				if bow_diff < PI * 0.5:
					intent.force_reverse = true
					intent.target_heading = wrapf(intent.target_heading + PI, -PI, PI)

		# if too close to terrain, prioritize
		if NavigationMapManager.get_distance(ship.global_position) < ship.movement_controller.turning_circle_radius * 4.0:
			intent.heading_weight = 0.9

	else:
		if not ship.visible_to_enemy:
			# Undetected — seek cover as normal, fall back to angle
			intent = _skill_cover.execute(ctx, cover_params, true)
			if intent != null:
				# if _ship.global_position.distance_to(_skill_cover._nav_destination) > 750.0:
				# 	_suppress_guns = true
				# else:
				# 	_suppress_guns = false
				var los_blocked = true
				for enemy in spotted:
					var _dist = enemy.global_position.distance_to(ship.global_position)
					if _dist < gun_range and !_is_los_blocked_with_clearance(ship.global_position, enemy.global_position):
						los_blocked = false
						break
				if los_blocked:
					for pos in unspotted.values():
						var _dist = pos.distance_to(ship.global_position)
						if _dist < gun_range and !_is_los_blocked_with_clearance(ship.global_position, pos):
							los_blocked = false
							break
				if los_blocked:
					_suppress_guns = false
				else:
					_suppress_guns = true

				_active_skill_name = &"FindCover"
			else:
				intent = _skill_push.execute(ctx, {})
				if intent != null:
					_active_skill_name = &"Push"
		else:
			# Detected but enemy is far — check if cover destination is on the way
			var cover_intent = _skill_cover.execute(ctx, cover_params, true)
			if cover_intent != null and nearest != null and threat > 0.85:
				if not _skill_cover.is_cover_on_the_way(ctx, nearest) and active_shooters_at_me.size() > 0:
				# Cover is too far off the optimal angle and there are active shooters — kite instead
					intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.65})
					if intent != null:
						_active_skill_name = &"Kite"
					else:
						intent = _skill_push.execute(ctx, {})
						if intent != null:
							_active_skill_name = &"Push"

					intent.target_position = intent.target_position.lerp(cover_intent.target_position, 0.1)
				else:
					intent = cover_intent
					_active_skill_name = &"FindCover"
			else:
				# No cover available or no spotted target — fall back to angle
				if cover_intent != null:
					intent = cover_intent
					_active_skill_name = &"FindCover"
				else:
					intent = _skill_push.execute(ctx, {})
					if intent != null:
						_active_skill_name = &"Push"

	var _a = _probe_concealment(server)

	# if threat > 0.85:
	# 	wants_stealth = true
	# 	wants_to_be_concealed = _probe_concealment(server)

	# else:
	# 	wants_stealth = false
	# 	wants_to_be_concealed = false

	# if wants_to_be_concealed:
	# 	_suppress_guns = true
	# else:
	# 	_suppress_guns = false


	# ── Post-process: broadside ──────────────────────────────────────────────
	# if _active_skill_name not in [&"Chase"]:
	intent = _skill_broadside.apply(intent, ctx, {"oscillation_bias": 0.5})

	if previous_intent == &"FindCover" and _active_skill_name != &"FindCover":
		_skill_cover.reset()
	# ── Post-process: spread ─────────────────────────────────────────────────
	if _active_skill_name not in [&"FindCover", &"Push", &"Kite"]:
		intent = _skill_spread.apply(intent, ctx, {"spread_distance": 1000.0, "spread_multiplier": 1.0})
	if _active_skill_name in [&"FindCover", &"Push", &"Kite"]:
		intent = _skill_spread.apply(intent, ctx, {"spread_distance": 250.0, "spread_multiplier": 1.0})

	return intent


# var repair = -1
# var damage_control = -1

func try_use_consumable():
	super.try_use_consumable()
