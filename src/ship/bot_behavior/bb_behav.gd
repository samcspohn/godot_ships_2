extends BotBehavior
class_name BBBehavior

var ammo = ShellParams.ShellType.AP

# Overmatch ratio cache: { ship_instance_id: { "bow": float, "stern": float } }
var _overmatch_cache: Dictionary = {}

const OVERMATCH_RATIO_THRESHOLD: float = 0.4  # 40% of faces must be overmatchable to prefer AP

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
		Ship.ShipClass.BB: return 0.5
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 2.0
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

func _get_cached_overmatch(target: Ship) -> Dictionary:
	"""Return { bow: float, stern: float } overmatch ratios, cached per target."""
	var tid = target.get_instance_id()
	if _overmatch_cache.has(tid):
		return _overmatch_cache[tid]

	var bow_ratio = get_overmatch_ratio(target, ArmorPart.Type.BOW)
	var stern_ratio = get_overmatch_ratio(target, ArmorPart.Type.STERN)
	var entry = { "bow": bow_ratio, "stern": stern_ratio }
	_overmatch_cache[tid] = entry
	return entry

func _can_overmatch_bow(target: Ship) -> bool:
	return _get_cached_overmatch(target).bow >= OVERMATCH_RATIO_THRESHOLD

func _can_overmatch_stern(target: Ship) -> bool:
	return _get_cached_overmatch(target).stern >= OVERMATCH_RATIO_THRESHOLD

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _target.global_position - _ship.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var offset = Vector3(0, 0, 0)
	angle = abs(angle)

	# Default to AP
	ammo = ShellParams.ShellType.AP

	match _target.ship_class:
		Ship.ShipClass.BB:
			# Determine if the target is showing bow or stern
			var is_bow_on = angle < PI / 2.0   # forward half of target faces us
			var can_overmatch = _can_overmatch_bow(_target) if is_bow_on else _can_overmatch_stern(_target)

			if angle < deg_to_rad(10) or angle > deg_to_rad(170):
				# Heavily angled (nearly bow/stern-on)
				if can_overmatch:
					# AP will punch through the thin plating regardless of angle
					ammo = ShellParams.ShellType.AP
					offset.y = 0.1
				else:
					# Thick bow/stern — AP will bounce, use HE on superstructure
					ammo = ShellParams.ShellType.HE
					offset.y = _target.movement_controller.ship_height / 2.0
			elif angle < deg_to_rad(30) or angle > deg_to_rad(150):
				# Moderately angled
				if can_overmatch:
					# AP through the bow/stern plate into the hull
					ammo = ShellParams.ShellType.AP
					offset.y = 0.1
				else:
					# Can't overmatch — AP at superstructure for reliable damage
					ammo = ShellParams.ShellType.AP
					offset.y = _target.movement_controller.ship_height / 2.0
			else:
				# Broadside — always AP at waterline for citadel hits
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
			# AP at destroyers — overpens citadel for good damage
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
	wants_stealth = false  # BBs push or camp — never route around detection zones
	var ctx = SkillContext.create(ship, target, server, self)
	_init_flank_identity(ship, server)

	var spotted = server.get_valid_targets(ship.team.team_id)
	var has_spotted = spotted.size() > 0
	var unspotted = server.get_unspotted_enemies(ship.team.team_id)
	var has_enemies = has_spotted or not unspotted.is_empty()
	var params = get_positioning_params()
	var gun_range = ship.artillery_controller.get_params()._range
	var threat = get_threat_score(server)
	var nearest: Ship = null
	var _nearest_dist: float = INF
	for _e in spotted:
		if is_instance_valid(_e) and _e.health_controller.is_alive():
			var _d = ship.global_position.distance_to(_e.global_position)
			if _d < _nearest_dist:
				_nearest_dist = _d
				nearest = _e
	var dist: float = _nearest_dist

	var _prev_skill_name = _active_skill_name
	var intent: NavIntent = null

	if not has_enemies:
		# No enemies at all — hunt then chase
		intent = _skill_hunt.execute(ctx, {})
		_active_skill_name = &"Hunt"
		if intent == null:
			intent = _skill_chase.execute(ctx, {})
			if intent:
				_active_skill_name = &"Chase"
	elif not has_spotted:
		# Enemies exist but none spotted — chase then hunt
		intent = _skill_chase.execute(ctx, {})
		_active_skill_name = &"Chase"
		if intent == null:
			intent = _skill_hunt.execute(ctx, {})
			if intent:
				_active_skill_name = &"Hunt"
	elif threat < 0.25:
		# Low threat: push directly at 40% gun range
		_skill_cover.reset()
		intent = _skill_angle.execute(ctx, {"desired_range_ratio": 0.0})
		if intent:
			_active_skill_name = &"Push"
	elif dist < 6000.0 and nearest != null:
		# High-ish threat (>= 0.65) AND enemy is close — calculate the optimal
		# presentation angle and choose angle skill (bow-in) or kite (stern-in).
		var to_nearest = nearest.global_position - ship.global_position
		to_nearest.y = 0.0
		var enemy_bearing = atan2(to_nearest.x, to_nearest.z)
		var optimal_heading = SkillAngle.calc_heading(enemy_bearing, ctx, {})
		var bow_diff = absf(angle_difference(optimal_heading, enemy_bearing))
		if bow_diff < PI * 0.5:
			# Optimal heading is bow-in — angle toward enemy
			intent = _skill_angle.execute(ctx, {"desired_range_ratio": 0.65})
			if intent != null:
				_active_skill_name = &"Angle"
		else:
			# Optimal heading is stern-in — kite away while keeping guns on target
			intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.65})
			if intent != null:
				_active_skill_name = &"Kite"
	elif threat < 0.4:
		intent = _skill_flank.execute(ctx, {"desired_range_ratio": 0.5, "flank_bias": params.flank_bias_healthy})
		if intent:
			_active_skill_name = &"Flank"
	elif threat < 0.65:
		intent = _skill_camp.execute(ctx, {"desired_range_ratio": 0.5})
		if intent:
			_active_skill_name = &"Camp"
	elif threat < 0.8:
		# Medium threat: camp/flank near island — cover at 60% range, fall back to camp at 0.65 ratio
		intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.6})
		if intent != null:
			_active_skill_name = &"Kite"
		else:
			intent = _skill_camp.execute(ctx, {"desired_range_ratio": 0.65})
			if intent:
				_active_skill_name = &"Camp"
	else:
		# High threat: take cover — cover at 70% range, fall back to kite
		intent = _skill_cover.execute(ctx, {"desired_range": gun_range * 0.7})
		if intent != null:
			_active_skill_name = &"FindCover"
		else:
			intent = _skill_kite.execute(ctx, {"desired_range_ratio": 0.75, "pull_toward_friendly_weight": 0.3})
			if intent:
				_active_skill_name = &"Kite"

	# Fallback chain
	if intent == null:
		intent = _skill_chase.execute(ctx, {})
		if intent:
			_active_skill_name = &"Chase"
	if intent == null:
		var fwd = ship.global_position - ship.basis.z * 10000
		fwd.y = 0.0
		intent = NavIntent.create(_get_valid_nav_point(fwd), _calc_approach_heading(ship, fwd))
		_active_skill_name = &"SailForward"

	# Reset camp lock when switching away from Camp
	if _prev_skill_name == &"Camp" and _active_skill_name != &"Camp":
		_skill_camp.reset()

	# Post-process broadside when skill is not Hunt or SailForward
	if _active_skill_name != &"Hunt" and _active_skill_name != &"SailForward":
		intent = _skill_broadside.apply(intent, ctx, {"oscillation_bias": 0.5})

	# Post-process spread when skill is not FindCover, Angle, or Kite
	if _active_skill_name not in [&"FindCover", &"Angle", &"Kite"]:
		intent = _skill_spread.apply(intent, ctx, {"spread_distance": params.spread_distance, "spread_multiplier": params.spread_multiplier})

	return intent


## Compute approach heading from ship to destination
func _calc_approach_heading(ship: Ship, dest: Vector3) -> float:
	var to_dest = dest - ship.global_position
	to_dest.y = 0.0
	if to_dest.length_squared() > 1.0:
		return atan2(to_dest.x, to_dest.z)
	return _get_ship_heading()
