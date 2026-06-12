extends Node
class_name BotBehavior
# Base class for bot behavior with configurable weights and shared utilities

var _ship: Ship = null
var nav: NavigationAgent3D

# Evasion state variables
var evasion_timer: float = 0.0
var evasion_direction: int = 1  # 1 or -1, which side we're currently angling
var last_target_bearing: float = 0.0  # Track target to keep guns on it

# Island cover state (used by CA and bot controller)
var is_in_cover: bool = false

# Cached safe direction (toward spawn, away from enemies)
var _cached_safe_dir: Vector3 = Vector3.ZERO
var _safe_dir_initialized: bool = false

# ============================================================================
# TORPEDO SYSTEM (moved from DD - available to ships with torpedoes)
# ============================================================================
var torpedo_fire_interval: float = 3.0
var torpedo_fire_timer: float = 0.0
var torpedo_target_position: Vector3 = Vector3.ZERO
var has_valid_torpedo_solution: bool = false
var current_torpedo_range: float = 0.0

# Long-term velocity average for torpedo prediction
# EMA with a ~100s time constant ≈ average displacement over the last 100 seconds,
# with recent frames weighted more heavily than old ones.
var _torp_avg_target: Ship = null
var _torp_vel_ema: Vector3 = Vector3.ZERO
const TORP_VEL_EMA_SECONDS: float = 100.0   # long-average time constant
const TORP_BLEND_REFERENCE_TIME: float = 15.0 # flight time (s) at which the long average reaches full weight

# Torpedo spread parameters
const SPREAD_ANGLE_BASE: float = 0.05
const SPREAD_ANGLE_PER_KM: float = 0.01
const MIN_TORPEDO_INTERVAL: float = 0.5
const MAX_TORPEDO_INTERVAL: float = 15.0
const RANGE_FOR_MAX_INTERVAL: float = 10000.0

# Torpedo salvo state
var torpedoes_in_salvo: int = 0
var salvo_spread_index: int = 0
var current_salvo_positions: Array[Vector3] = []

# Friendly fire check
var friendly_fire_check_radius: float = 5000.0
var friendly_fire_safety_margin: float = 500.0

# Flanking detection cache
var _cached_friendly_spawn: Vector3 = Vector3.ZERO
var _cached_enemy_spawn: Vector3 = Vector3.ZERO
var _spawn_cache_initialized: bool = false

# Active skill name for debug
var _active_skill_name: StringName = &""

var _fwd = null

# Per-frame result caches — cleared automatically on frame change
var _spotted_danger_center_cache: Vector3 = Vector3.ZERO
var _spotted_danger_center_frame: int = -1
var _threat_score_cache: float = 0.0
var _threat_score_frame: int = -1
var threat_mod: float = 1.0

## Set to true by each ship class in get_nav_intent when the ship wants the
## bot controller to route around enemy detection zones during transit.
## Reset to false at the start of every get_nav_intent call so it is always
## freshly computed — never stale from a previous tick.
## Rules of thumb:
##   DD  : true whenever undetected (torpedo approach, spotting run)
##   CA  : true when undetected + seeking island cover + no torpedo launcher
##         (torpedo CAs push close regardless of detection)
##   BB  : always false — BBs push or camp, never sneak
var wants_stealth: bool = false

## Set to true by each ship class in get_nav_intent when the ship wants to
## suppress gun fire in order to let firing bloom decay and re-enter
## concealment. When true, engage_target will aim turrets but NOT fire.
## Reset to false at the start of every get_nav_intent call.
##   DD  : true when detected AND bloom active AND nearest enemy beyond base radius
##   CA  : true when in stealth-cover mode AND same bloom condition
##   BB  : always false
var wants_to_be_concealed: bool = false

## Enemies currently shooting at this bot.
## Maps Ship -> float wall-clock expiry (seconds). An enemy is kept for 1.5x its
## reload time after its last detected shell so the window stays open even when
## no projectiles are in the air. Managed by BotControllerV4; use .has(ship) in skills.
var active_shooters_at_me: Dictionary = {}  # Ship -> float expiry_sec

# Skill instances (created in subclass _init or on first use)
var _skills: Dictionary = {}  # StringName -> BotSkill

# Flank identity (rolled once at match start)
var _flank_side: int = 0      # -1 left, +1 right, 0 unassigned
var _flank_depth: float = 0.0
var _flank_initialized: bool = false

var _suppress_guns: bool = false

# ============================================================================
# CONFIGURABLE WEIGHT SYSTEMS - Override in subclasses
# ============================================================================

func get_target_weights() -> Dictionary:
	"""Override to customize target selection weights."""
	return {
		size_weight = 0.3,
		range_weight = 0.5,
		hp_weight = 0.2,
		overextension_weight = 0.4,  # Weight for how far into friendly territory an enemy has pushed
		class_modifiers = {
			Ship.ShipClass.BB: 1.0,
			Ship.ShipClass.CA: 1.0,
			Ship.ShipClass.DD: 1.0,
		},
		prefer_broadside = true,
		in_range_multiplier = 10.0,
		flanking_multiplier = 5.0,  # Priority boost for flanking enemies
		# If an enemy is closer than this distance, always prioritize it over overextended targets
		proximity_override_distance = 3000.0,
		# Bonus multiplier applied to the most overextended target among candidates
		overextension_bonus = 2.0,
	}

func get_flanking_params() -> Dictionary:
	"""Override to customize flanking detection thresholds."""
	return {
		# Enemy is flanking if closer to our spawn than this fraction of spawn-to-spawn distance
		deep_flank_threshold = 0.3,  # Very deep in our territory
		flank_threshold = 0.5,       # Past midfield toward our spawn
		# Minimum distance to spawn to be considered flanking (prevents false positives at map edges)
		min_spawn_distance = 5000.0,
		# Enable/disable flanking detection
		enabled = true,
	}

func get_positioning_params() -> Dictionary:
	"""Override to customize positioning behavior."""
	return {
		base_range_ratio = 0.60,
		range_increase_when_damaged = 0.20,
		min_safe_distance_ratio = 0.40,
		flank_bias_healthy = 0.5,
		flank_bias_damaged = 0.2,
		spread_distance = 500.0,
		spread_multiplier = 2.0,
	}



func get_cover_search_params() -> Dictionary:
	"""Override to customize cover position search tuning."""
	return {
		angle_step = deg_to_rad(20.0),
		angle_half_span = PI / 2.0,
		los_clearance = -75.0,
	}

func get_hunting_params() -> Dictionary:
	"""Override to customize hunting behavior."""
	return {
		approach_multiplier = 0.4,
		cautious_hp_threshold = 0.5,
	}

func get_evasion_params() -> Dictionary:
	"""Override for class-specific evasion parameters."""
	return {
		min_angle = deg_to_rad(25),
		max_angle = deg_to_rad(35),
		evasion_period = 6.0,
		vary_speed = false
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	"""Weight for threat calculation based on enemy ship class."""
	match ship_class:
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 1.0
	return 1.0

# ============================================================================
# TACTICAL STATE HELPERS
# ============================================================================

func _init_flank_identity(ship: Ship, server: GameServer) -> void:
	if _flank_initialized:
		return
	_flank_initialized = true
	var spawn_pos = ship.global_position
	var team_spawn = server.get_team_spawn_position(ship.team.team_id)
	if team_spawn == Vector3.ZERO:
		_flank_side = 1 if randf() > 0.5 else -1
		_flank_depth = _roll_flank_depth()
		return
	var to_ship = spawn_pos - team_spawn
	to_ship.y = 0.0
	var enemy_spawn = server.get_team_spawn_position(1 - ship.team.team_id)
	var forward = (enemy_spawn - team_spawn).normalized() if enemy_spawn != Vector3.ZERO else Vector3(0, 0, -1)
	var right = Vector3.UP.cross(forward).normalized()
	var side_dot = to_ship.dot(right)
	if abs(side_dot) < 2000.0:
		_flank_side = 1 if randf() > 0.5 else -1
	else:
		_flank_side = 1 if side_dot > 0 else -1
	_flank_depth = _roll_flank_depth()

func _roll_flank_depth() -> float:
	## Override per ship class
	return randf_range(0.2, 0.5)

func can_fire_guns() -> bool:
	## Always allowed at the base level.
	## Each ship class gates firing in its own engage_target override.
	return true

func _probe_concealment(server: GameServer) -> bool:
	## Returns true when guns should be suppressed to protect or achieve
	## concealment.
	##
	## Decision tree:
	##   1. No spotted enemies:
	##      → If detected with active bloom, a concealed ship has LOS; inject
	##        proxy and suppress. Otherwise safe to fire.
	##   2. For each spotted enemy:
	##      a. LOS blocked by terrain → skip (terrain shields us from them).
	##      b. LOS unblocked + we are already detected + enemy inside base
	##         radius → suppression is useless (they see us regardless) → false.
	##      c. LOS unblocked → open water; firing will expose/keep us exposed
	##        → suppress_useful = true.
	##   3. All spotted enemies have blocked LOS:
	##      → If detected, a concealed ship must have LOS; inject proxy + suppress.
	##      → If not detected, terrain shields us from all threats; safe to fire.
	##   4. Return suppress_useful.
	##
	## NOTE: intentionally no top-level visible_to_enemy guard — we suppress
	## proactively in open water even before the ship is detected so that bloom
	## never builds up in the first place.

	var concealment_node = _ship.concealment
	if concealment_node == null:
		return false

	var base_radius: float = (concealment_node.params.p() as ConcealmentParams).radius

	var spotted = server.get_valid_targets(_ship.team.team_id)

	# No spotted enemies at all
	if spotted.is_empty():
		# If we are detected with bloom, a concealed ship must have direct LOS.
		if _ship.visible_to_enemy and concealment_node.bloom_value > 0.0:
			_inject_proxy_spotter(server)
			return true
		return false

	var all_los_blocked: bool = true
	var suppress_useful: bool = false

	for enemy in spotted:
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		var d = enemy.global_position.distance_to(_ship.global_position)
		var los_blocked = _is_los_blocked_with_clearance(_ship.global_position, enemy.global_position)

		if not los_blocked:
			all_los_blocked = false
			if _ship.visible_to_enemy and d < base_radius:
				# Already detected and enemy is inside base detection radius
				# with direct LOS — suppressing bloom won't make them lose us.
				return false
			# Open-water enemy: firing creates or sustains bloom that exposes us.
			suppress_useful = true

	if all_los_blocked:
		if _ship.visible_to_enemy:
			# Terrain covers every spotted enemy yet we are still detected —
			# a concealed ship must have direct LOS.
			_inject_proxy_spotter(server)
			return true
		# Not detected and all enemies behind terrain — safe to fire.
		return false

	return suppress_useful


func _inject_proxy_spotter(server: GameServer) -> void:
	## If concealment.spotted_by is a valid, living, currently-unspotted ship,
	## write it into the server's unspotted-enemies dict so the navigation and
	## threat systems treat it as a known threat even though it is concealed.
	var concealment_node = _ship.concealment
	if concealment_node == null:
		return
	var spotter: Ship = concealment_node.spotted_by
	if not is_instance_valid(spotter):
		return
	if not spotter.health_controller.is_alive():
		return
	# Don't inject if the spotter is already in the spotted (visible) list
	var spotted = server.get_valid_targets(_ship.team.team_id)
	if spotter in spotted:
		return
	var my_team: int = _ship.team.team_id
	var unspotted: Dictionary = server.team_0_unspotted_enemies if my_team == 0 else server.team_1_unspotted_enemies
	var unspotted_times: Dictionary = server.team_0_unspotted_times if my_team == 0 else server.team_1_unspotted_times
	# Only refresh the stored position when the last known position no longer
	# has line-of-sight to us.  If the old position still has clear LOS to our
	# ship the spotter may not have moved — keeping the stale position prevents
	# bots from being omniscient about a concealed spotter's exact location.
	# We always write on first contact (spotter not yet in the dict).
	if spotter in unspotted:
		var last_known: Vector3 = unspotted[spotter]
		if not NavigationMapManager.is_los_blocked(last_known, _ship.global_position):
			return
	unspotted[spotter] = spotter.global_position
	unspotted_times[spotter] = Time.get_ticks_msec() / 1000.0

# ============================================================================
# NAVIGATION UTILITIES
# ============================================================================

func _get_valid_nav_point(target: Vector3) -> Vector3:
	# V4 path: use NavigationMapManager SDF + safe destination selection
	if nav == null:
		if NavigationMapManager != null and NavigationMapManager.is_map_ready():
			var clearance = 100.0
			var turning_radius = 300.0
			if _ship and _ship.movement_controller:
				clearance = _ship.movement_controller.ship_beam * 0.5 + 50.0
				turning_radius = _ship.movement_controller._p().turning_circle_radius

			var ship_pos = _ship.global_position if _ship else target
			# Use the C++ safe_nav_point which handles:
			#   1. Pushing points out of land with adequate buffer
			#   2. Sliding points tangentially along coastlines so the ship
			#      approaches parallel to shore rather than head-on
			#   3. Ensuring at least clearance + turning_radius margin from land
			var safe_target = NavigationMapManager.safe_nav_point(
				ship_pos, target, clearance, turning_radius
			)

			# Second pass: validate the full approach path won't create an
			# unrecoverable collision course (e.g. destination behind an island
			# that forces a perpendicular approach on the last segment)
			safe_target = NavigationMapManager.validate_destination(
				ship_pos, safe_target, clearance, turning_radius
			)

			return safe_target
		# No navigation system available — return target as-is
		return target

	# V3 path: use NavigationAgent3D
	var nav_map = nav.get_navigation_map()
	var closest_point = NavigationServer3D.map_get_closest_point(nav_map, target)
	return closest_point

# ============================================================================
# TARGET SELECTION
# ============================================================================

func _get_overextension_score(enemy: Ship) -> float:
	"""Calculate how far an enemy has pushed into friendly territory.
	Returns 0.0 (at enemy spawn) to 1.0 (at friendly spawn)."""
	_initialize_spawn_cache()
	if not _spawn_cache_initialized:
		return 0.0

	var spawn_to_spawn = _cached_enemy_spawn - _cached_friendly_spawn
	spawn_to_spawn.y = 0.0
	var total_distance = spawn_to_spawn.length()
	if total_distance < 1.0:
		return 0.0

	var spawn_axis = spawn_to_spawn.normalized()
	var enemy_from_enemy_spawn = enemy.global_position - _cached_enemy_spawn
	enemy_from_enemy_spawn.y = 0.0
	var projection = enemy_from_enemy_spawn.dot(spawn_axis)
	return clampf(projection / total_distance, 0.0, 1.0)

# func pick_target(targets: Array[Ship], last_target: Ship) -> Ship:
# 	"""Configurable target selection using weights from get_target_weights().
# 	Prefers targets we can actually hit (not behind cover) over ones we can't.
# 	Balances proximity threats against overextended enemies using a weight system:
# 	 - Enemies very close to the bot get a strong proximity boost.
# 	 - Enemies farthest into friendly territory get an overextension bonus.
# 	 - When no enemy is dangerously close, the most overextended enemy wins."""
# 	var weights = get_target_weights()
# 	var gun_range = _ship.artillery_controller.get_params()._range
# 	var proximity_override_dist: float = weights.get("proximity_override_distance", 3000.0)
# 	var overextension_bonus: float = weights.get("overextension_bonus", 2.0)
# 	var overextension_weight: float = weights.get("overextension_weight", 0.4)

# 	# --- First pass: compute base priority and overextension for every target ---
# 	var candidate_data: Array[Dictionary] = []
# 	var max_overextension: float = 0.0
# 	var has_close_threat: bool = false

# 	for ship in targets:
# 		var disp = ship.global_position - _ship.global_position
# 		var dist = disp.length()
# 		var angle = (-ship.basis.z).angle_to(disp)
# 		var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp

# 		# Calculate apparent size (broadside profile)
# 		var priority: float = 0.0
# 		if weights.prefer_broadside:
# 			priority = ship.movement_controller.ship_length / dist * abs(sin(angle)) + ship.movement_controller.ship_beam / dist * abs(cos(angle))
# 		else:
# 			priority = ship.movement_controller.ship_length / dist

# 		# Apply class modifier
# 		var class_mods: Dictionary = weights.class_modifiers
# 		if class_mods.has(ship.ship_class):
# 			priority *= class_mods[ship.ship_class]

# 		# Combine with range and HP weights
# 		var size_contrib = priority * weights.size_weight
# 		var range_contrib = (1.0 - dist / gun_range) * weights.range_weight
# 		var hp_contrib = (1.0 - hp_ratio) * weights.hp_weight
# 		priority = size_contrib + range_contrib + hp_contrib

# 		# Boost targets within range
# 		if dist <= gun_range:
# 			priority *= weights.in_range_multiplier

# 		# Apply flanking priority boost
# 		var flank_info = _get_flanking_info(ship)
# 		if flank_info.is_flanking:
# 			var flank_multiplier = weights.get("flanking_multiplier", 5.0)
# 			var depth_scale = 1.0 + flank_info.penetration_depth
# 			priority *= flank_multiplier * depth_scale

# 		# Overextension score: how far into friendly territory this enemy is
# 		var overext = _get_overextension_score(ship)
# 		if overext > max_overextension:
# 			max_overextension = overext

# 		# Track whether any enemy is dangerously close
# 		if dist < proximity_override_dist:
# 			has_close_threat = true

# 		var shootable = dist <= gun_range and can_hit_target(ship)
# 		candidate_data.append({
# 			ship = ship,
# 			base_priority = priority,
# 			dist = dist,
# 			overextension = overext,
# 			shootable = shootable,
# 		})

# 	# --- Second pass: apply overextension vs proximity weighting ---
# 	var best_shootable_target: Ship = null
# 	var best_shootable_priority: float = -1.0
# 	var best_fallback_target: Ship = null
# 	var best_fallback_priority: float = -1.0

# 	for data in candidate_data:
# 		var priority: float = data.base_priority
# 		var dist: float = data.dist
# 		var overext: float = data.overextension
# 		var ship: Ship = data.ship

# 		# Overextension contribution: reward enemies deeper into friendly territory
# 		if max_overextension > 0.0 and overextension_weight > 0.0:
# 			# Normalized 0-1 among current targets (most forward = 1.0)
# 			var relative_overext = overext / max_overextension
# 			var overext_contrib = relative_overext * overextension_weight
# 			priority += overext_contrib

# 			# Extra bonus for the most overextended target when nothing is dangerously close
# 			if not has_close_threat and relative_overext > 0.9:
# 				priority *= overextension_bonus

# 		# Proximity override: if this enemy is very close, give a strong boost
# 		if dist < proximity_override_dist:
# 			# Scales from 1.0 at the threshold up to 3.0 at point-blank
# 			var proximity_factor = 1.0 + 2.0 * (1.0 - dist / proximity_override_dist)
# 			priority *= proximity_factor

# 		# Sort into shootable vs fallback
# 		if data.shootable:
# 			if priority > best_shootable_priority:
# 				best_shootable_target = ship
# 				best_shootable_priority = priority
# 		else:
# 			if priority > best_fallback_priority:
# 				best_fallback_target = ship
# 				best_fallback_priority = priority

# 	# Prefer shootable targets; only fall back to blocked targets if nothing is shootable
# 	var best_target = best_shootable_target if best_shootable_target != null else best_fallback_target

# 	# Stick to last target if nearby and alive, but only if it's still shootable
# 	if best_target != null and last_target != null and last_target.is_alive():
# 		if last_target.position.distance_to(best_target.position) < 1000:
# 			# If last target is shootable (or both are blocked), keep it for stability
# 			if best_shootable_target == null or can_hit_target(last_target):
# 				return last_target

# 	return best_target

var potential_target_weight_cache: Dictionary = {}  # Ship -> float
func get_potential_target_weight(target: Ship) -> float:
	if potential_target_weight_cache.has(target):
		return potential_target_weight_cache[target]
	var my_range = _ship.artillery_controller.get_params()._range
	var hp_ratio = target.health_controller.current_hp / target.health_controller.max_hp

	# Prefer close targets; falls off exponentially beyond gun range
	var weight = exp(-target.global_position.distance_to(_ship.global_position) / my_range)

	# Prefer targets presenting a large side profile (easier to hit)
	var target_heading = target.global_transform.basis.z.normalized()
	var to_target = (target.global_position - _ship.global_position).normalized()
	var angle = target_heading.angle_to(to_target)
	var side_profile = target.movement_controller.ship_length * abs(sin(angle)) + target.movement_controller.ship_beam * abs(cos(angle))
	side_profile *= 0.01
	match target.ship_class:
		Ship.ShipClass.BB:
			side_profile *= 1.0
		Ship.ShipClass.CA:
			side_profile *= 2.0
		Ship.ShipClass.DD:
			side_profile *= 3.0
	# weight *= side_profile * 0.01

	# Prefer damaged targets (finish them off), but keep full-health targets at 10% weight floor
	weight += maxf(pow(1.0 - hp_ratio, 2.0), 0.5)


	# Prefer high-threat targets
	weight += target.stats.total_damage * (1.0 / 100_000.0)

	potential_target_weight_cache[target] = weight
	return weight

func pick_target(targets: Array[Ship], last_target: Ship) -> Ship:
	potential_target_weight_cache.clear()
	targets.sort_custom(func(a: Ship, b: Ship) -> bool:
		return get_potential_target_weight(a) > get_potential_target_weight(b)
	)

	# Find the highest-weight target that is visible and can be shot at
	var best: Ship = null
	for potential in targets:
		if potential.visible_to_enemy and can_hit_target(potential):
			best = potential
			break

	if best == null:
		return null

	# Keep the current target unless a significantly better one exists (25% threshold)
	if last_target != null and last_target.is_alive() \
			and last_target.visible_to_enemy and can_hit_target(last_target):
		var last_weight = get_potential_target_weight(last_target)
		var best_weight = get_potential_target_weight(best)
		if best_weight <= last_weight * 1.1:
			return last_target

	return best


func pick_ammo(target: Ship) -> int:
	var ammo = ShellParams.ShellType.AP
	if target.ship_class == Ship.ShipClass.DD:
		ammo = ShellParams.ShellType.HE
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	"""Returns the offset to the target to aim at in local space. Override in subclasses."""
	return Vector3.ZERO

func get_overmatch_ratio(target: Ship, zone_type: ArmorPart.Type) -> float:
	"""Returns the fraction (0.0–1.0) of faces on the target's armor zone that
	our AP shell can overmatch. Requires target.armor_system and armor_parts."""
	if target.armor_system == null:
		return 0.0

	var ap_overmatch: int = _ship.artillery_controller.get_params().shell1.overmatch

	var total_faces: int = 0
	var overmatched_faces: int = 0

	for part in target.armor_parts:
		if part.type != zone_type:
			continue
		var stats = target.armor_system.get_node_armor_stats(part.armor_path)
		if stats.is_empty():
			continue
		var distribution: Dictionary = stats.armor_distribution
		for thickness in distribution:
			var count: int = distribution[thickness]
			if thickness <= 0:
				continue
			total_faces += count
			if thickness <= ap_overmatch:
				overmatched_faces += count

	if total_faces == 0:
		return 0.0
	return float(overmatched_faces) / float(total_faces)

# ============================================================================
# EVASION SYSTEM
# ============================================================================

func get_speed_multiplier() -> float:
	"""Returns current speed multiplier for evasion. Override in DD for speed variation."""
	return 1.0

func should_evade(destination: Vector3) -> bool:
	"""Determine if ship should be evading vs traveling to destination."""
	if not _ship.visible_to_enemy:
		return false

	var dist_to_dest = _ship.global_position.distance_to(destination)
	var movement = _ship.get_node_or_null("Modules/MovementController") as ShipMovementV4
	if movement == null:
		return true

	var arrival_threshold = movement.turning_circle_radius * 2.0
	return dist_to_dest < arrival_threshold

func get_desired_heading(target: Ship, current_heading: float, delta: float, destination: Vector3) -> Dictionary:
	"""Returns {heading: float, use_evasion: bool}."""
	if not should_evade(destination):
		return {heading = current_heading, use_evasion = false}

	var threat_bearing = _get_weighted_threat_bearing()
	if threat_bearing == null:
		return {heading = current_heading, use_evasion = false}

	var evasion_heading = _calculate_evasion_heading(target, threat_bearing, delta)
	return {heading = evasion_heading, use_evasion = true}

func _calculate_evasion_heading(target: Ship, threat_bearing: float, delta: float) -> float:
	"""Calculate heading that angles toward threat while keeping guns on target."""
	var params = get_evasion_params()
	var min_angle = params.min_angle
	var max_angle = params.max_angle
	var period = params.evasion_period

	evasion_timer += delta

	var wave = (sin(evasion_timer * TAU / period) + 1.0) / 2.0
	var current_angle = lerp(min_angle, max_angle, wave)

	if target != null:
		var to_target = target.global_position - _ship.global_position
		var target_bearing = atan2(to_target.x, to_target.z)
		var wave_derivative = cos(evasion_timer * TAU / period)

		if wave_derivative < 0:
			var current_ship_heading = _get_ship_heading()
			var angle_to_target = _normalize_angle(target_bearing - current_ship_heading)
			evasion_direction = 1 if angle_to_target > 0 else -1

		last_target_bearing = target_bearing

	return _normalize_angle(threat_bearing + current_angle * evasion_direction)

func _get_weighted_threat_bearing() -> Variant:
	"""Returns bearing to weighted average of enemy clusters. null if no threats."""
	var danger_center = _get_spotted_danger_center()
	if danger_center == Vector3.ZERO:
		return null
	var to_danger = danger_center - _ship.global_position
	return atan2(to_danger.x, to_danger.z)

# ============================================================================
# THREAT ANALYSIS
# ============================================================================



func _get_spotted_danger_center() -> Vector3:
	"""Calculate threat-weighted center of currently spotted enemies.
	unspotted enemies are included at very low weight
	Returns Vector3.ZERO if no enemies are spotted.
	Use this when positioning must be based on confirmed, live threats."""
	var frame := Engine.get_physics_frames()
	if frame == _spotted_danger_center_frame:
		return _spotted_danger_center_cache
	var result := Vector3.ZERO
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node != null:
		var spotted = server_node.get_valid_targets(_ship.team.team_id)
		var unspotted = server_node.get_unspotted_enemies(_ship.team.team_id)
		var weighted_pos = Vector3.ZERO
		var total_weight = 0.0
		# if spotted.size() > 0:
		for ship in spotted:
			if ship == null or not is_instance_valid(ship):
				continue
			var to_ship = ship.global_position - _ship.global_position
			var dist = to_ship.length()
			if dist < 1.0:
				dist = 1.0
			var base_weight = 1.0 / (dist * dist / 100_000_000.0 + 1.0)
			var threat = get_threat_class_weight(ship.ship_class)
			var ship_range = ship.artillery_controller.get_params()._range if ship.artillery_controller != null else 10000.0
			if dist > ship_range:
				threat *= 0.1
			var weight = base_weight * threat
			if active_shooters_at_me.has(ship):
				weight *= 10.0  # Boost weight for enemies actively shooting at us
				# Optionally, could also factor in how recently they shot at us based on expiry time
			weighted_pos += ship.global_position * weight
			total_weight += weight
		for ship in unspotted.keys():
			var last_pos: Vector3 = unspotted[ship]
			var to_ship = last_pos - _ship.global_position
			var dist = to_ship.length()
			if dist < 1.0:
				dist = 1.0
			var base_weight = 1.0 / (dist * dist / 100_000_000.0 + 1.0)
			var threat = get_threat_class_weight(ship.ship_class) if is_instance_valid(ship) else 1.0
			var ship_range = ship.artillery_controller.get_params()._range if ship.artillery_controller != null else 10000.0
			if dist > ship_range:
				threat *= 0.1
			var weight = base_weight * threat * 0.5
			if active_shooters_at_me.has(ship):
				weight *= 10.0  # Boost weight for enemies actively shooting at us
			weighted_pos += last_pos * weight
			total_weight += weight
		if total_weight >= 0.00001:
			result = weighted_pos / total_weight
		if is_nan(result.x) or is_nan(result.y) or is_nan(result.z):
			print("NaN detected in danger center calculation! Resetting to zero.")
			result = Vector3.ZERO
	_spotted_danger_center_cache = result
	_spotted_danger_center_frame = frame
	return result

func _get_nearest_enemy() -> Dictionary:
	"""Find the nearest known enemy. Returns {position, distance, ship} or empty dict."""
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return {}

	var nearest_pos = Vector3.ZERO
	var nearest_dist = INF
	var nearest_ship: Ship = null

	var valid_targets = server_node.get_valid_targets(_ship.team.team_id)
	for ship in valid_targets:
		var dist = _ship.global_position.distance_to(ship.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_pos = ship.global_position
			nearest_ship = ship

	var unspotted = server_node.get_unspotted_enemies(_ship.team.team_id)
	for ship in unspotted.keys():
		var last_pos: Vector3 = unspotted[ship]
		var dist = _ship.global_position.distance_to(last_pos)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_pos = last_pos
			nearest_ship = ship

	if nearest_dist == INF:
		return {}

	return {position = nearest_pos, distance = nearest_dist, ship = nearest_ship}

func _nearest_unspotted_info(server: GameServer) -> Dictionary:
	"""Returns last-known position info for the nearest unspotted enemy.
	Keys: ship, position, distance.  Returns empty dict if none exists."""
	var unspotted := server.get_unspotted_enemies(_ship.team.team_id)
	var best_ship = null
	var best_pos  := Vector3.ZERO
	var best_dist := INF
	for s in unspotted.keys():
		if not is_instance_valid(s):
			continue
		var last_pos: Vector3 = unspotted[s]
		var d := _ship.global_position.distance_to(last_pos)
		if d < best_dist:
			best_dist = d
			best_pos  = last_pos
			best_ship = s
	if best_ship == null:
		return {}
	return {ship = best_ship, position = best_pos, distance = best_dist}

func _initialize_spawn_cache() -> void:
	"""Initialize spawn position cache for flanking detection."""
	if _spawn_cache_initialized:
		return

	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return

	var my_team_id = _ship.team.team_id
	var enemy_team_id = 1 - my_team_id

	_cached_friendly_spawn = server_node.get_team_spawn_position(my_team_id)
	_cached_enemy_spawn = server_node.get_team_spawn_position(enemy_team_id)

	if _cached_friendly_spawn != Vector3.ZERO and _cached_enemy_spawn != Vector3.ZERO:
		_spawn_cache_initialized = true

func _get_flanking_info(enemy: Ship) -> Dictionary:
	"""Determine if an enemy is flanking (pushing into friendly spawn area).
	Returns {is_flanking: bool, penetration_depth: float (0-1)}."""
	var params = get_flanking_params()

	if not params.enabled:
		return {is_flanking = false, penetration_depth = 0.0}

	# Initialize spawn cache if needed
	_initialize_spawn_cache()

	if not _spawn_cache_initialized:
		return {is_flanking = false, penetration_depth = 0.0}

	var enemy_pos = enemy.global_position
	var spawn_to_spawn = _cached_enemy_spawn - _cached_friendly_spawn
	spawn_to_spawn.y = 0.0
	var total_distance = spawn_to_spawn.length()

	if total_distance < 1.0:
		return {is_flanking = false, penetration_depth = 0.0}

	# Calculate how far along the spawn-to-spawn axis the enemy is
	# 0.0 = at enemy spawn, 1.0 = at our spawn
	var enemy_to_friendly_spawn = _cached_friendly_spawn - enemy_pos
	enemy_to_friendly_spawn.y = 0.0
	var dist_to_friendly_spawn = enemy_to_friendly_spawn.length()

	# Project enemy position onto spawn-to-spawn line
	var spawn_axis = spawn_to_spawn.normalized()
	var enemy_from_enemy_spawn = enemy_pos - _cached_enemy_spawn
	enemy_from_enemy_spawn.y = 0.0
	var projection = enemy_from_enemy_spawn.dot(spawn_axis)
	var penetration_ratio = projection / total_distance

	# Check minimum distance to spawn (to avoid false positives at map edges)
	if dist_to_friendly_spawn > params.min_spawn_distance * 2:
		# Too far from our spawn to be a real flanking threat
		if penetration_ratio < params.flank_threshold:
			return {is_flanking = false, penetration_depth = 0.0}

	# Determine if flanking based on penetration depth
	var is_flanking = false
	var depth = 0.0

	if penetration_ratio >= params.deep_flank_threshold:
		# Deep flank - very high priority
		is_flanking = true
		# Scale depth from 0.5 to 1.0 based on how deep (0.3 to 1.0 penetration)
		depth = remap(penetration_ratio, params.deep_flank_threshold, 1.0, 0.5, 1.0)
		depth = clamp(depth, 0.5, 1.0)
	elif penetration_ratio >= params.flank_threshold:
		# Moderate flank
		is_flanking = true
		# Scale depth from 0.0 to 0.5 based on penetration
		depth = remap(penetration_ratio, params.flank_threshold, params.deep_flank_threshold, 0.0, 0.5)
		depth = clamp(depth, 0.0, 0.5)

	# Additional check: if enemy is closer to our spawn than our team average, boost priority
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node and is_flanking:
		var friendly_avg = server_node.get_team_avg_position(_ship.team.team_id)
		if friendly_avg != Vector3.ZERO:
			var friendly_dist_to_spawn = friendly_avg.distance_to(_cached_friendly_spawn)
			if dist_to_friendly_spawn < friendly_dist_to_spawn:
				# Enemy is behind our lines - extra dangerous
				depth = min(depth + 0.25, 1.0)

	return {is_flanking = is_flanking, penetration_depth = depth}

func _get_flanking_direction(danger_center: Vector3, friendly_avg: Vector3) -> int:
	"""Determine which direction to flank (1 = right, -1 = left)."""
	if danger_center == Vector3.ZERO:
		return 1

	var to_danger = danger_center - _ship.global_position
	to_danger.y = 0.0
	var danger_bearing = atan2(to_danger.x, to_danger.z)

	var right_angle = _normalize_angle(danger_bearing + PI / 2.0)
	var left_angle = _normalize_angle(danger_bearing - PI / 2.0)

	if friendly_avg != Vector3.ZERO:
		var to_friendly = friendly_avg - _ship.global_position
		to_friendly.y = 0.0
		var friendly_bearing = atan2(to_friendly.x, to_friendly.z)

		var right_diff = abs(_normalize_angle(right_angle - friendly_bearing))
		var left_diff = abs(_normalize_angle(left_angle - friendly_bearing))

		return 1 if right_diff > left_diff else -1

	var current_heading = _get_ship_heading()
	var angle_to_danger = _normalize_angle(danger_bearing - current_heading)
	return 1 if angle_to_danger > 0 else -1



func _calculate_spread_offset(friendly: Array[Ship], min_spread_distance: float, multiplier: float = 2.0) -> Vector3:
	"""Calculate offset to avoid clumping with teammates."""
	var spread_offset = Vector3.ZERO
	var check_distance = min_spread_distance * multiplier

	for ship in friendly:
		if ship == _ship:
			continue
		var to_teammate = _ship.global_position - ship.global_position
		var dist_to_teammate = to_teammate.length()
		if dist_to_teammate < check_distance and dist_to_teammate > 0.1:
			var push_strength = 1.0 - (dist_to_teammate / check_distance)
			spread_offset += to_teammate.normalized() * push_strength * min_spread_distance

	return spread_offset

# ============================================================================
# HUNTING BEHAVIOR
# ============================================================================

func _get_hunting_position(server_node: GameServer, friendly: Array[Ship], current_destination: Vector3) -> Vector3:
	"""Common hunting behavior when no enemies are visible."""
	if server_node == null:
		return current_destination

	var params = get_hunting_params()
	var gun_range = _ship.artillery_controller.get_params()._range
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp

	var unspotted_enemies = server_node.get_unspotted_enemies(_ship.team.team_id)

	if unspotted_enemies.is_empty():
		#var avg_enemy = server_node.get_enemy_avg_position(_ship.team.team_id)
		#if avg_enemy != Vector3.ZERO:
			## Move toward the enemy average, stopping one gun range short
			#var to_enemy = (avg_enemy - _ship.global_position).normalized()
			#var standoff = gun_range * params.approach_multiplier
			#var hunt_pos = avg_enemy - to_enemy * standoff
			#hunt_pos.y = 0.0
			#return _get_valid_nav_point(hunt_pos)
		return current_destination

	# Find closest unspotted enemy
	var closest_pos: Vector3 = Vector3.ZERO
	var closest_dist: float = INF

	for ship in unspotted_enemies.keys():
		var last_known_pos: Vector3 = unspotted_enemies[ship]
		var dist = _ship.global_position.distance_to(last_known_pos)
		if dist < closest_dist:
			closest_dist = dist
			closest_pos = last_known_pos

	if closest_pos == Vector3.ZERO:
		return current_destination

	var to_target = (closest_pos - _ship.global_position).normalized()
	# Unspotted enemy positions are stale — the enemy has likely moved since
	# going dark.  Use a reduced standoff so we actually close to where we
	# can re-spot them instead of hovering at max range from a phantom.
	# Halve the approach_multiplier for unspotted targets so ships push in.
	var approach_mult = params.approach_multiplier * 0.5
	var standoff = gun_range * lerp(approach_mult, approach_mult * 1.5, 1.0 - hp_ratio)
	standoff = clamp(standoff, 0.0, gun_range * 0.6)
	var desired_pos = closest_pos - to_target * standoff
	desired_pos.y = 0.0

	# Apply spread
	var pos_params = get_positioning_params()
	desired_pos += _calculate_spread_offset(friendly, pos_params.spread_distance, pos_params.spread_multiplier)

	# Bias toward friendlies when low HP
	if hp_ratio < params.cautious_hp_threshold:
		var nearest_cluster = server_node.get_nearest_friendly_cluster(_ship.global_position, _ship.team.team_id)
		if not nearest_cluster.is_empty():
			var cluster_center: Vector3 = nearest_cluster.center
			var to_cluster = (cluster_center - _ship.global_position).normalized()
			desired_pos = closest_pos - (to_target * 0.6 + to_cluster * 0.4).normalized() * standoff

	return _get_valid_nav_point(desired_pos)



func can_hit_target(target: Ship) -> bool:
	"""Check if we can actually hit the target (not blocked by terrain/islands).
	Uses sim_can_shoot_over_terrain_static from ship center at deck height."""

	var gun_params = _ship.artillery_controller.get_params()
	if gun_params == null:
		return false
	if target.global_position.distance_to(_ship.global_position) > gun_params._range * 1.5:
		# Quick early-out for very distant targets to avoid expensive sim checks
		return false

	var shell_params = _ship.artillery_controller.get_shell_params()
	if shell_params == null:
		return false

	var adjusted_target_pos = target.global_position + target.global_basis * target_aim_offset(target)

	# Use leading calculation so the sim check matches what we'd actually fire
	var lead_result = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(
		_ship.global_position,
		adjusted_target_pos,
		target.linear_velocity / ProjectileManager.get_shell_time_multiplier(),
		shell_params
	)
	var lead_pos = lead_result[2]
	if lead_pos == null:
		return false

	# Fire from ship center at deck height (draft / 2 above waterline)
	var fire_pos = _ship.global_position
	fire_pos.y = _ship.movement_controller.ship_draft / 2.0

	var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(fire_pos, lead_pos, shell_params)
	if sol[0] == null:
		return false

	var can_shoot = Gun.sim_can_shoot_over_terrain_static(fire_pos, sol[0], sol[1], shell_params, _ship)
	return can_shoot.can_shoot_over_terrain

# ============================================================================
# TORPEDO SYSTEM
# ============================================================================

func update_torpedo_aim(target_ship: Ship):
	"""Update torpedo aiming solution. Call this for ships with torpedoes."""
	has_valid_torpedo_solution = false
	current_salvo_positions.clear()

	if !target_ship or !is_instance_valid(target_ship):
		return

	var torpedo_controller = _ship.torpedo_controller
	if !torpedo_controller:
		return

	var distance_to_target = _ship.global_position.distance_to(target_ship.global_position)
	var torpedo_range = torpedo_controller.get_params()._range

	if distance_to_target > torpedo_range * 0.9:
		return

	current_torpedo_range = distance_to_target

	var torpedo_speed = torpedo_controller.get_torp_params().speed * TorpedoManager.TORPEDO_SPEED_MULTIPLIER

	# --- Velocity prediction: blend current velocity with long-term average ---
	# Reset EMA when target changes so we don't carry over a different ship's history.
	if _torp_avg_target != target_ship:
		_torp_avg_target = target_ship
		_torp_vel_ema = target_ship.linear_velocity

	# EMA alpha: each frame nudges the average toward current velocity.
	# Time constant of 100s means the average reflects ~100s of position displacement,
	# naturally weighting recent frames more than old ones.
	var dt: float = 1.0 / Engine.physics_ticks_per_second
	var ema_alpha: float = clamp(dt / TORP_VEL_EMA_SECONDS, 0.0, 1.0)
	_torp_vel_ema = lerp(_torp_vel_ema, target_ship.linear_velocity, ema_alpha)

	# Short flight time: trust current velocity (target's exact heading matters).
	# Long flight time: trust the long average (best predictor of where they'll actually be).
	var rough_flight_time: float = distance_to_target / torpedo_speed
	var blend: float = clamp(rough_flight_time / TORP_BLEND_REFERENCE_TIME, 0.0, 1.0)
	var predicted_vel: Vector3 = lerp(target_ship.linear_velocity, _torp_vel_ema, blend)

	torpedo_target_position = calculate_interception_point(
		_ship.global_position,
		target_ship.global_position,
		predicted_vel,
		torpedo_speed
	)

	var interception_distance = _ship.global_position.distance_to(torpedo_target_position)
	if interception_distance > torpedo_range * 0.95:
		return

	var to_lead := torpedo_target_position - _ship.global_position
	var base_angle := atan2(to_lead.x, to_lead.z)

	var range_km = distance_to_target / 1000.0
	var spread_angle = SPREAD_ANGLE_BASE + SPREAD_ANGLE_PER_KM * range_km

	var spread_offsets = [-2, -1, 0, 1, 2]

	for offset in spread_offsets:
		var torpedo_angle = base_angle + (offset * spread_angle)
		var torpedo_direction = Vector3(sin(torpedo_angle), 0, cos(torpedo_angle))
		var torpedo_aim_point = _ship.global_position + torpedo_direction * interception_distance
		torpedo_aim_point.y = 0

		if is_land_blocking_torpedo_path(_ship.global_position, torpedo_aim_point):
			continue
		if would_hit_friendly_ship(_ship.global_position, torpedo_aim_point, torpedo_speed):
			continue

		current_salvo_positions.append(torpedo_aim_point)

	if current_salvo_positions.size() > 0:
		has_valid_torpedo_solution = true
		# True center of the surviving spread positions (not pre-filter size)
		var center_idx: int = int(current_salvo_positions.size() * 0.5)
		torpedo_controller.set_aim_input(current_salvo_positions[center_idx])

	var range_ratio = clamp(distance_to_target / RANGE_FOR_MAX_INTERVAL, 0.0, 1.0)
	torpedo_fire_interval = lerp(MIN_TORPEDO_INTERVAL, MAX_TORPEDO_INTERVAL, range_ratio)

func try_fire_torpedoes(_target_ship: Ship):
	"""Attempt to fire torpedoes at current solution."""
	if !has_valid_torpedo_solution:
		salvo_spread_index = 0
		return

	if current_salvo_positions.size() == 0:
		salvo_spread_index = 0
		return

	var torpedo_controller = _ship.torpedo_controller
	if !torpedo_controller:
		return

	var aim_index = salvo_spread_index % current_salvo_positions.size()
	var aim_position = current_salvo_positions[aim_index]

	torpedo_controller.set_aim_input(aim_position)

	for launcher in torpedo_controller.launchers:
		if launcher.reload >= 1.0 and launcher.can_fire and !launcher.disabled:
			torpedo_controller.fire_next_ready()
			salvo_spread_index += 1
			torpedoes_in_salvo += 1

			if salvo_spread_index >= current_salvo_positions.size():
				salvo_spread_index = 0
				torpedoes_in_salvo = 0
			return


func _get_max_torp_reload() -> float:
	"""Returns the highest reload progress (0–1) across all torpedo launchers.
	Returns 0.0 if this ship has no torpedo controller or no launchers."""
	var tc = _ship.torpedo_controller
	if tc == null:
		return 0.0
	var best: float = 0.0
	for launcher in tc.launchers:
		if launcher.reload > best:
			best = launcher.reload
	return best

func is_land_blocking_torpedo_path(from_pos: Vector3, to_pos: Vector3) -> bool:
	"""Check if land blocks the torpedo path."""
	var space_state = _ship.get_world_3d().direct_space_state
	var ray = PhysicsRayQueryParameters3D.new()
	ray.from = from_pos + (to_pos - from_pos).normalized() * 30.0
	ray.from.y = 1
	ray.to = to_pos
	ray.to.y = 1

	var collision = space_state.intersect_ray(ray)
	return !collision.is_empty()

func would_hit_friendly_ship(from_pos: Vector3, to_pos: Vector3, torpedo_speed: float) -> bool:
	"""Check if torpedo would hit a friendly ship."""
	if !_ship:
		return false

	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if !server_node:
		return false

	var torpedo_direction = (to_pos - from_pos).normalized()
	var torpedo_distance = from_pos.distance_to(to_pos)
	var time_to_target = torpedo_distance / torpedo_speed

	for other_ship in server_node.get_team_ships(_ship.team.team_id):
		if other_ship == _ship or !is_instance_valid(other_ship):
			continue
		if other_ship.team.team_id != _ship.team.team_id:
			continue
		if other_ship.health_controller.current_hp <= 0:
			continue

		var distance_to_ally = _ship.global_position.distance_to(other_ship.global_position)
		if distance_to_ally > friendly_fire_check_radius:
			continue

		var check_points = 10
		for i in range(check_points + 1):
			var t = float(i) / float(check_points) * time_to_target

			var torpedo_pos = from_pos + torpedo_direction * torpedo_speed * t
			torpedo_pos.y = 0

			var ally_pos = other_ship.global_position + other_ship.linear_velocity * t
			ally_pos.y = 0

			var distance_at_t = torpedo_pos.distance_to(ally_pos)

			if distance_at_t < friendly_fire_safety_margin:
				return true

	return false

func calculate_interception_point(shooter_pos: Vector3, target_pos: Vector3, target_vel: Vector3, projectile_speed: float) -> Vector3:
	"""Calculate interception point for a projectile to hit a moving target."""
	var to_target = target_pos - shooter_pos

	var a = target_vel.dot(target_vel) - projectile_speed * projectile_speed
	var b = 2.0 * to_target.dot(target_vel)
	var c = to_target.dot(to_target)

	if abs(a) < 0.0001:
		if abs(b) < 0.0001:
			return target_pos
		var t_linear = -c / b
		if t_linear > 0:
			return target_pos + target_vel * t_linear
		return target_pos

	var discriminant = b * b - 4.0 * a * c

	if discriminant < 0:
		return target_pos

	var sqrt_disc = sqrt(discriminant)
	var t1 = (-b - sqrt_disc) / (2.0 * a)
	var t2 = (-b + sqrt_disc) / (2.0 * a)

	var t = -1.0
	if t1 > 0 and t2 > 0:
		t = min(t1, t2)
	elif t1 > 0:
		t = t1
	elif t2 > 0:
		t = t2
	else:
		return target_pos

	return target_pos + target_vel * t

# ============================================================================
# ISLAND COVER SYSTEM — SDF-based cover position search
# ============================================================================

func _gather_threat_positions(ship: Ship) -> Array:
	"""All known enemy positions: currently visible + last-known unspotted."""
	var threats: Array = []
	var server_node: GameServer = ship.get_node_or_null("/root/Server")
	if server_node == null:
		return threats
	for enemy in server_node.get_valid_targets(ship.team.team_id):
		if is_instance_valid(enemy) and enemy.health_controller.is_alive():
			threats.append(enemy.global_position)
	var unspotted = server_node.get_unspotted_enemies(ship.team.team_id)
	for enemy_ship in unspotted.keys():
		threats.append(unspotted[enemy_ship])
	return threats

func get_navigator() -> ShipNavigator:
	"""Expose the owning BotControllerV4 navigator to skills via SkillContext."""
	var controller = get_parent()
	if controller and controller.navigator:
		# BotControllerV4 now stores a GDScript profiling wrapper.
		# Skills still expect the native ShipNavigator interface.
		if controller.navigator.has_method("get_raw"):
			return controller.navigator.get_raw()
		return controller.navigator
	return null

func _get_ship_clearance() -> float:
	"""Use the navigator's hard clearance — single source of truth."""
	var nav := get_navigator()
	if nav != null:
		return nav.get_clearance_radius()
	return 100.0

func _get_turning_radius() -> float:
	if _ship and _ship.movement_controller:
		return _ship.movement_controller.turning_circle_radius
	return 300.0

func _safe_validate(ship: Ship, pos: Vector3) -> Vector3:
	"""Push a position through safe_nav_point + validate_destination."""
	var clearance = _get_ship_clearance()
	var turning_radius = _get_turning_radius()
	if NavigationMapManager.is_map_ready():
		pos = NavigationMapManager.safe_nav_point(ship.global_position, pos, clearance, turning_radius)
		pos = NavigationMapManager.validate_destination(ship.global_position, pos, clearance, turning_radius)
	return pos

func _push_clear_of_threats(pos: Vector3, threat_positions: Array, min_dist: float) -> Vector3:
	"""Iteratively push pos away from every threat position until it is at least
	min_dist from all of them.  Runs up to 8 relaxation passes.  The result
	still needs to be fed through _get_valid_nav_point to clear land."""
	for _pass in range(8):
		var any_violation := false
		for tp in threat_positions:
			var tp3 := tp as Vector3
			var offset := pos - tp3
			offset.y = 0.0
			var dist := offset.length()
			if dist < min_dist:
				any_violation = true
				var push_dir: Vector3
				if dist > 0.1:
					push_dir = offset.normalized()
				else:
					push_dir = Vector3(randf() - 0.5, 0.0, randf() - 0.5).normalized()
				pos += push_dir * (min_dist - dist)
				pos.y = 0.0
		if not any_violation:
			break
	return pos

func _compute_safe_direction(ship: Ship, server: GameServer) -> Vector3:
	"""Determine the 'safe' direction: toward our spawn from the ship,
	or away from the nearest enemy cluster if spawn is unavailable."""
	_initialize_spawn_cache()
	if _cached_friendly_spawn != Vector3.ZERO:
		var dir = _cached_friendly_spawn - ship.global_position
		dir.y = 0.0
		if dir.length_squared() > 1.0:
			return dir.normalized()

	var cluster = server.get_nearest_enemy_cluster(ship.global_position, ship.team.team_id)
	if not cluster.is_empty():
		var away = ship.global_position - cluster.center
		away.y = 0.0
		if away.length_squared() > 1.0:
			return away.normalized()

	var danger = _get_spotted_danger_center()
	if danger != Vector3.ZERO:
		var away = ship.global_position - danger
		away.y = 0.0
		if away.length_squared() > 1.0:
			return away.normalized()

	var fwd = -ship.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() > 0.1:
		return fwd.normalized()
	return Vector3(0, 0, -1)

func _ensure_safe_dir(ship: Ship, server: GameServer) -> void:
	if not _safe_dir_initialized:
		_cached_safe_dir = _compute_safe_direction(ship, server)
		_safe_dir_initialized = true

func _compute_hide_heading(island_center: Vector3, threats: Array) -> float:
	"""Average the headings from island_center to each threat, then add PI
	to get the direction facing away from all enemies.  Uses circular mean
	so headings near ±PI don't cancel out."""
	if threats.is_empty():
		return 0.0
	var sum_sin = 0.0
	var sum_cos = 0.0
	for threat_pos in threats:
		var to_threat = threat_pos - island_center
		to_threat.y = 0.0
		if to_threat.length_squared() < 1.0:
			continue
		var h = atan2(to_threat.x, to_threat.z)
		sum_sin += sin(h)
		sum_cos += cos(h)
	if absf(sum_sin) < 0.001 and absf(sum_cos) < 0.001:
		return 0.0
	return atan2(sum_sin, sum_cos) + PI

func _sdf_walk_to_shore(island_center: Vector3, direction: Vector3, island_radius: float, clearance: float) -> Vector3:
	"""Sphere-trace from near the island edge until we reach a point with
	at least `clearance` SDF distance from land. Returns Vector3.ZERO on failure."""
	if not NavigationMapManager.is_map_ready():
		return Vector3.ZERO

	# Start close to expected shoreline instead of marching from island center.
	var dist = maxf(island_radius - clearance, 0.0)
	var min_step = maxf(clearance * 0.25, 8.0)
	var max_dist = island_radius + maxf(clearance * 6.0, 600.0)

	for _i in range(24):
		if dist > max_dist:
			break
		var test = island_center + direction * dist
		test.y = 0.0
		var sdf = NavigationMapManager.get_distance(test)
		var clearance_error = clearance - sdf
		if clearance_error <= 0.0:
			return test

		# Sphere-tracing step against an inflated (clearance) shoreline.
		dist += maxf(clearance_error, min_step)

	return Vector3.ZERO

func _is_los_blocked_with_clearance(from_pos: Vector3, to_pos: Vector3) -> bool:
	"""LOS check with clearance buffer — treats islands as slightly smaller than
	the raw SDF to account for imperfect island modelling (off by ~1 cell)."""
	if not NavigationMapManager.is_map_ready():
		return false
	var map = NavigationMapManager.get_map()
	if map == null:
		return false
	var search_params = get_cover_search_params()
	var result: Dictionary = map.raycast(
		Vector2(from_pos.x, from_pos.z),
		Vector2(to_pos.x, to_pos.z),
		search_params.los_clearance
	)
	return result["hit"]

func _find_cover_position_on_island(island_center: Vector3, island_radius: float, hide_heading: float, threats: Array, targets: Array, max_range: float, avoid_positions: Array = [], min_separation: float = 0.0) -> Dictionary:
	"""Search for a position around the island that is fully concealed from
	enemies (flat LOS blocked to ALL threats) and allows shooting over the
	island at targets (ballistic arc simulation).

	Generates two rings of candidate points — shore-line positions and offset
	positions pushed out by 2.5× clearance.  When sort_by_proximity is true,
	candidates are sorted by distance to the ship so the nearest viable point
	wins.  Otherwise the original angle-priority order is preserved (best hide
	heading first).
	Returns { "pos": Vector3, "can_shoot": bool } or empty dict."""
	var clearance = _get_ship_clearance()
	if not NavigationMapManager.is_map_ready():
		return {}
	if threats.is_empty() and targets.is_empty():
		return {}

	var search_params = get_cover_search_params()
	var angle_step: float = search_params.angle_step
	var angle_half_span: float = search_params.angle_half_span

	var shell_params = _ship.artillery_controller.get_shell_params()
	var gun_range = _ship.artillery_controller.get_params()._range
	var gun_range_sq = gun_range * gun_range
	var max_range_sq = max_range * max_range
	var threat_count = threats.size()
	var my_pos = _ship.global_position
	var enforce_spacing := min_separation > 0.0 and not avoid_positions.is_empty()
	var min_separation_sq = min_separation * min_separation

	# Evaluate candidates immediately in travel-friendly angular order:
	# start from the ship-facing side of the island, then expand left/right.
	var best_concealed_fallback: Vector3 = Vector3.ZERO
	var best_conflict_shootable: Vector3 = Vector3.ZERO
	var best_conflict_concealed: Vector3 = Vector3.ZERO
	var offset_clearance = clearance * 2.0
	var min_ring_separation_sq = (clearance * 0.5) * (clearance * 0.5)
	var ship_to_island_heading = atan2(my_pos.x - island_center.x, my_pos.z - island_center.z)
	var max_steps = int(ceil(angle_half_span / maxf(angle_step, 0.001)))

	for step_idx in range(max_steps + 1):
		var offset = float(step_idx) * angle_step
		for side in range(1 if step_idx == 0 else 2):
			var signed_offset = 0.0 if step_idx == 0 else (offset if side == 0 else -offset)
			var heading = ship_to_island_heading + signed_offset

			# Only keep headings inside the hide window around hide_heading.
			if absf(angle_difference(hide_heading, heading)) > angle_half_span + 0.001:
				continue

			var dir = Vector3(sin(heading), 0.0, cos(heading))
			var shore_pos = _sdf_walk_to_shore(island_center, dir, island_radius, clearance)
			var offset_pos = _sdf_walk_to_shore(island_center, dir, island_radius, offset_clearance)

			for ring in range(2):
				var pos = shore_pos if ring == 0 else offset_pos
				if pos == Vector3.ZERO:
					continue
				if ring == 1 and shore_pos != Vector3.ZERO and pos.distance_squared_to(shore_pos) <= min_ring_separation_sq:
					continue

				var any_in_range = false
				for threat_pos in threats:
					if pos.distance_squared_to(threat_pos) <= max_range_sq:
						any_in_range = true
						break
				if not any_in_range:
					continue

				var hidden_count: int = 0
				for threat_pos in threats:
					if _is_los_blocked_with_clearance(pos, threat_pos):
						hidden_count += 1
				if hidden_count < threat_count:
					continue

				var spacing_conflict := false
				if enforce_spacing:
					for avoid_pos in avoid_positions:
						if pos.distance_squared_to(avoid_pos) < min_separation_sq:
							spacing_conflict = true
							break

				var can_shoot_any: bool = false
				if shell_params != null:
					var gun_proxy_pos = pos + Vector3(0, _ship.movement_controller.ship_draft / 2.0, 0)
					for t_ship in targets:
						if not is_instance_valid(t_ship) or not t_ship.health_controller.is_alive():
							continue
						var target_pos = t_ship.global_position + t_ship.global_basis * target_aim_offset(t_ship)
						if pos.distance_squared_to(target_pos) > gun_range_sq:
							continue
						var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(gun_proxy_pos, target_pos, shell_params)
						if sol[0] == null:
							continue
						var shoot_result = Gun.sim_can_shoot_over_terrain_static(gun_proxy_pos, sol[0], sol[1], shell_params, _ship)
						if shoot_result.can_shoot_over_terrain:
							can_shoot_any = true
							break

				if can_shoot_any:
					if spacing_conflict:
						if best_conflict_shootable == Vector3.ZERO:
							best_conflict_shootable = pos
					else:
						return { "pos": pos, "can_shoot": true, "spacing_conflict": false }
				else:
					if spacing_conflict:
						if best_conflict_concealed == Vector3.ZERO:
							best_conflict_concealed = pos
					elif best_concealed_fallback == Vector3.ZERO:
						best_concealed_fallback = pos

	if best_concealed_fallback != Vector3.ZERO:
		return { "pos": best_concealed_fallback, "can_shoot": false, "spacing_conflict": false }

	if best_conflict_shootable != Vector3.ZERO:
		return { "pos": best_conflict_shootable, "can_shoot": true, "spacing_conflict": true }

	if best_conflict_concealed != Vector3.ZERO:
		return { "pos": best_conflict_concealed, "can_shoot": false, "spacing_conflict": true }

	return {}

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

func _tangential_heading(island_center: Vector3, from_pos: Vector3) -> float:
	"""Compute a heading tangential to the island center from from_pos.
	Picks whichever tangent (CW or CCW) is closest to the ship's current heading."""
	var to_island = island_center - from_pos
	to_island.y = 0.0
	if to_island.length() < 1.0:
		return _get_ship_heading()
	var radial = atan2(to_island.x, to_island.z)
	var cw = _normalize_angle(radial + PI * 0.5)
	var ccw = _normalize_angle(radial - PI * 0.5)
	var current = _get_ship_heading()
	if abs(_normalize_angle(cw - current)) <= abs(_normalize_angle(ccw - current)):
		return cw
	return ccw



# ============================================================================
# NAVINTENT — V4 bot controller interface
# ============================================================================
func get_threat_score(ctx: SkillContext) -> float:
	## Returns a normalized 0–1 threat score (0 = safe, 1 = maximum threat).
	## Each spotted enemy within its own gun range contributes a per-enemy threat
	## via an asymptotic function (1 − e^−x), so threat approaches 1 as the raw
	## pressure increases but never exceeds it. Raw pressure is
	##   enemy_hp / my_hp × range_pressure × class_w
	## Multiple enemies compound multiplicatively via raw_threat *= (1 − this_threat).
	## Subclasses override get_threat_class_weight() to tune per-class fear.
	var server: GameServer = ctx.server
	var frame := Engine.get_physics_frames()
	if frame == _threat_score_frame:
		return _threat_score_cache
	var my_hp  = _ship.health_controller.current_hp
	var max_hp = _ship.health_controller.max_hp
	var hp_ratio = my_hp / max_hp if max_hp > 0.0 else 0.0
	var hp_pressure = clampf(1.0 - hp_ratio, 0.0, 1.0)

	var spotted = server.get_valid_targets(_ship.team.team_id)
	var unspotted = server.get_unspotted_enemies(_ship.team.team_id)
	var enemies = spotted + unspotted.keys()
	if enemies.is_empty():
		_threat_score_cache = hp_pressure * 0.3 * threat_mod
		_threat_score_frame = frame
		return _threat_score_cache

	var raw_threat: float = 1.0
	var time_remaining: float = server.get_match_time_remaining()
	var t_norm: float = clampf(1.0 - time_remaining / server.MATCH_DURATION, 0.0, 1.0)
	var threat_scale: float = 1.0 - pow(t_norm, 4)

	for enemy in enemies:
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		var dist        = enemy.global_position.distance_to(_ship.global_position)
		var enemy_range = enemy.artillery_controller.get_params()._range
		var enemy_hp    = enemy.health_controller.current_hp
		# Only count enemies whose guns can plausibly reach us
		if enemy_range <= 0.0 or dist > enemy_range:
			continue
		# 0.0 at range edge → 1.0 at point-blank
		var range_pressure = clampf(1.0 - pow(dist / enemy_range, 4.0), 0.0, 1.0)
		# Class weight: each ship class has a different threat weight per subclass
		var class_w = get_threat_class_weight(enemy.ship_class)
		# raw_threat *= (1.0 - range_pressure * class_w)
		# Asymptotic: approaches 1 as raw pressure increases, never exceeds it.
		# 1 − e^(−x): x=0 → 0.0, x=1 → 0.63, x=2 → 0.86, x→∞ → 1.0
		var raw_val = enemy_hp / my_hp * range_pressure * class_w
		if !ctx.behavior.active_shooters_at_me.has(enemy):
			raw_val *= 0.5
		raw_val *= threat_scale
		raw_val *= threat_mod
		var this_threat = 1.0 - exp(-raw_val)
		if not enemy.visible_to_enemy:
			this_threat *= 0.7  # unspotted enemies can move while undetected, making their threat less certain # todo: consider a more sophisticated "uncertainty" model that decays over time since last spotted
		raw_threat *= (1.0 - this_threat)

	# var friendly = server.get_team_ships(_ship.team.team_id)
	# for mate in friendly:
	# 	var dist = mate.global_position.distance_to(_ship.global_position)
	# 	if mate != _ship and mate.health_controller.is_alive() and dist < 4000.0:
	# 		# Nearby allies reduce threat via their own HP ratio (more HP = more support they can provide)
	# 		var mate_hp_ratio = mate.health_controller.current_hp / mate.health_controller.max_hp if mate.health_controller.max_hp > 0.0 else 0.0
	# 		raw_threat *= lerpf(1.0, 2.0, mate_hp_ratio)

	# # Low HP amplifies perceived threat so damaged ships play more defensively
	# raw_threat *= lerpf(1.0, 2.0, hp_pressure)

	# # Normalize: 5 threat-weight units ≈ maximum threat
	# return clampf(raw_threat / 5.0, 0.0, 1.0)
	# raw_threat *= hp_ratio
	var base_threat = clampf(1 - raw_threat, 0.0, 1.0)

	# As the match timer runs out, reduce threat so bots play more aggressively.
	# Uses 1 - t^4: stays near 1.0 for most of the match, drops sharply near the end.
	# e.g. t=50% (10min) -> 0.94, t=75% (15min) -> 0.68, t=90% (18min) -> 0.34, t=100% -> 0.0


	_threat_score_cache = base_threat
	_threat_score_frame = frame
	return _threat_score_cache




# ============================================================================
# COMBAT
# ============================================================================

func _secondary_target_offset(target: Ship) -> Vector3:
	var super_idx = target.armor_parts.find_custom(func(part):
		return part.type == ArmorPart.Type.SUPERSTRUCTURE)
	assert(super_idx != -1, "Secondary target offset requires a superstructure armor part")
	var superstructure := target.armor_parts[super_idx] as ArmorPart
	return target.to_local(superstructure.global_position) + Vector3(0, 0.5, 0)

func update_secondary_priority_target(primary_target: Ship, server: GameServer) -> void:
	var sec := _ship.secondary_controller
	if sec == null or sec.sub_controllers.is_empty():
		return

	var max_range := sec.get_max_range()
	var selected: Ship = null
	if primary_target != null and is_instance_valid(primary_target) and primary_target.is_alive() and primary_target.visible_to_enemy:
		if primary_target.global_position.distance_to(_ship.global_position) <= max_range:
			selected = primary_target

	if selected == null:
		var best_dist := INF
		for enemy: Ship in server.get_valid_targets(_ship.team.team_id):
			if not enemy.is_alive():
				continue
			var dist := enemy.global_position.distance_to(_ship.global_position)
			if dist <= max_range and dist < best_dist:
				best_dist = dist
				selected = enemy

	sec.target = selected
	sec.target_offset = _secondary_target_offset(selected) if selected != null else Vector3.ZERO

func engage_target(target: Ship):
	"""Fire at target. Override for class-specific behavior."""
	if target.global_position.distance_to(_ship.global_position) > _ship.artillery_controller.get_params()._range:
		return

	#if not can_fire_guns():
		#_ship.artillery_controller.set_aim_input(target.global_position + target.global_basis * target_aim_offset(target))
		#return

	# Concealment probe: aim turrets but hold fire to let bloom decay
	if wants_to_be_concealed:
		_ship.artillery_controller.set_aim_input(target.global_position + target.global_basis * target_aim_offset(target))
		_ship.secondary_controller.enabled = false
		return
	_ship.secondary_controller.enabled = true

	var adjusted_target_pos = target.global_position + target.global_basis * target_aim_offset(target)
	var lead_result = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(
		_ship.global_position,
		adjusted_target_pos,
		target.linear_velocity / ProjectileManager.get_shell_time_multiplier(),
		_ship.artillery_controller.get_shell_params()
	)
	var target_lead = lead_result[2]

	if target_lead == null:
		return

	# Always update aim toward the target so turrets rotate correctly
	_ship.artillery_controller.set_aim_input(target_lead)

	var ammo = pick_ammo(target)
	_ship.artillery_controller.select_shell(ammo)

	# Only fire guns whose actual aim point is near the intended target AND
	# whose shell arc clears terrain. This prevents two bugs:
	#  1) Shooting at water/old aim — gun.can_fire is stale from previous
	#     frame when the turret was aimed at the navigation destination.
	#     We check that the gun's _aim_point is close to our target_lead
	#     so we never fire until the turret has actually rotated on-target.
	#  2) Shooting at targets behind cover — sim_can_shoot_over_terrain_static
	#     traces the full shell arc and rejects shots blocked by terrain.
	var shell_params = _ship.artillery_controller.get_shell_params()
	var fire_pos = _ship.global_position
	fire_pos.y = _ship.movement_controller.ship_draft / 2.0
	var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(fire_pos, target_lead, shell_params)
	var arc_clear := false
	if sol[0] != null:
		var can_shoot = Gun.sim_can_shoot_over_terrain_static(fire_pos, sol[0], sol[1], shell_params, _ship)
		arc_clear = can_shoot.can_shoot_over_terrain

	for gun in _ship.artillery_controller.guns:
		if gun.disabled or gun.reload < 1.0 or not gun.can_fire:
			continue
		# Verify the gun's actual aim point is reasonably close to our
		# intended lead position. If not, the turret hasn't caught up yet
		# and firing would send shells toward the old (wrong) aim point.
		var aim_error = gun._aim_point.distance_to(target_lead)
		if aim_error > 5.0:
			continue
		# Verify the shell arc actually clears terrain / islands
		if not arc_clear:
			continue
		# This gun is aimed correctly and has a clear arc — fire it
		gun.fire(_ship.artillery_controller.target_mod)
		return



# ============================================================================
# UTILITIES
# ============================================================================

# Heading error (radians) within which the hull is considered aligned with the
# bidirectional desired-heading line, allowing the ship to engage reverse.
const REVERSE_ALIGN_TOL: float = deg_to_rad(40.0)

func _get_ship_heading() -> float:
	"""Get ship's current heading. 0 = +Z, PI/2 = +X, etc."""
	var forward = -_ship.global_transform.basis.z
	return atan2(forward.x, forward.z)

## When shootable cover is reachable and lies along the engagement path to
## `nearest`, returns a FindCover intent and sets _active_skill_name.  Returns
## null otherwise so the caller can fall back to kite/push.
func _try_cover_on_the_way(ctx: SkillContext, nearest: Ship, cover_skill: SkillFindCover, cover_params: Dictionary) -> NavIntent:
	if nearest == null:
		return null
	var cover_intent := cover_skill.execute(ctx, cover_params, false)
	if cover_intent != null and cover_skill.is_cover_on_the_way(ctx, nearest):
		_active_skill_name = &"FindCover"
		return cover_intent
	return null

func _has_active_bb_shooter() -> bool:
	for shooter in active_shooters_at_me:
		if is_instance_valid(shooter) and shooter.ship_class == Ship.ShipClass.BB:
			return true
	return false

## Align hull with the bidirectional desired-heading line before engaging reverse,
## preventing broadside exposure during a turn-around.  Call after a skill sets
## intent.target_heading.  nearest_threat_dist gates activation against threshold.
func _apply_reverse_alignment(intent: NavIntent, nearest_threat_dist: float, threshold: float) -> NavIntent:
	if nearest_threat_dist >= threshold:
		return intent
	var ship_heading := _get_ship_heading()
	if absf(angle_difference(intent.target_heading, ship_heading)) > PI * 0.5:
		var rev_heading := wrapf(intent.target_heading + PI, -PI, PI)
		intent.target_heading = rev_heading
		if absf(angle_difference(rev_heading, ship_heading)) < REVERSE_ALIGN_TOL:
			intent.force_reverse = true
		else:
			intent.heading_weight = 1.0
	return intent

func _normalize_angle(angle: float) -> float:
	while angle > PI:
		angle -= TAU
	while angle < -PI:
		angle += TAU
	return angle

# ============================================================================
# DEBUG — Skill / tactical state info for the 3D world label
# ============================================================================

func get_debug_skill_info() -> Dictionary:
	var info: Dictionary = {}
	info["skill"] = String(_active_skill_name) if _active_skill_name != &"" else "None"
	info["visible"] = _ship.visible_to_enemy if _ship != null else false
	info["in_cover"] = is_in_cover
	info["concealment"] = wants_to_be_concealed
	if _ship != null:
		var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp
		info["hp_pct"] = int(hp_ratio * 100.0)
		if _ship.concealment != null:
			info["bloom"] = _ship.concealment.bloom_value
		var server_node: GameServer = _ship.get_node_or_null("/root/Server")
		if server_node != null:
			info["threat"] = _threat_score_cache
		if _ship.torpedo_controller != null:
			info["torp_reload"] = _get_max_torp_reload()
	return info

# ============================================================================
# CONSUMABLES
# ============================================================================

var repair = -1
var damage_control = -1
var hydroacoustic_search: int = -1
var radar: int = -1
var smoke_screen: int = -1

func try_use_consumable():
	var hp = _ship.health_controller.current_hp / _ship.health_controller.max_hp
	var max_hp = _ship.health_controller.max_hp
	var healable = _ship.health_controller.healable_damage

	if repair == -1:
		for c in _ship.consumable_manager.equipped_consumables:
			if c.type == ConsumableItem.ConsumableType.REPAIR_PARTY:
				repair = c.id
				break

	if damage_control == -1:
		for c in _ship.consumable_manager.equipped_consumables:
			if c.type == ConsumableItem.ConsumableType.DAMAGE_CONTROL:
				damage_control = c.id
				break
	var repair_party = (_ship.consumable_manager.equipped_consumables[repair] as RepairParty)
	repair_party = repair_party.p() as RepairParty
	var heal_percent_per_repair = repair_party.heal_per_sec * repair_party.duration if repair != -1 else 0
	var heal_per_repair = max_hp * heal_percent_per_repair
	# var effective_heal = min(healable, heal_per_repair)

	if healable > heal_per_repair or hp < 0.25:
		if repair != -1:
			_ship.consumable_manager.use_consumable(repair)

	if damage_control != -1:
		var fires = _ship.fire_manager.get_active_fires()
		if fires > 0:
			if (hp < 0.5 and fires >= 1) or fires >= 2:
				_ship.consumable_manager.use_consumable(damage_control)


	if damage_control != -1:
		var floods = _ship.flood_manager.get_active_floods()
		if floods > 0:
			if (hp < 0.5 and floods >= 1) or floods >= 2:
				_ship.consumable_manager.use_consumable(damage_control)

	# --- Hydroacoustic Search ---
	if hydroacoustic_search == -1:
		for c in _ship.consumable_manager.equipped_consumables:
			if c.type == ConsumableItem.ConsumableType.HYDROACOUSTIC_SEARCH:
				hydroacoustic_search = c.id
				break

	if hydroacoustic_search != -1:
		if _should_use_hydro():
			_ship.consumable_manager.use_consumable(hydroacoustic_search)

	# --- Radar ---
	if radar == -1:
		for c in _ship.consumable_manager.equipped_consumables:
			if c.type == ConsumableItem.ConsumableType.RADAR:
				radar = c.id
				break

	if radar != -1:
		if _should_use_radar():
			_ship.consumable_manager.use_consumable(radar)

	# --- Smoke Screen ---
	if smoke_screen == -1:
		for c in _ship.consumable_manager.equipped_consumables:
			if c.type == ConsumableItem.ConsumableType.SMOKE_SCREEN:
				smoke_screen = c.id
				break
	if smoke_screen != -1:
		if _should_use_smoke():
			_ship.consumable_manager.use_consumable(smoke_screen)

func _should_use_smoke() -> bool:
	# Simple heuristic: use smoke if we're low HP and have an active BB shooter targeting us.
	if _ship.health_controller.current_hp / _ship.health_controller.max_hp < 0.5 and active_shooters_at_me.size() > 0 and _ship.visible_to_enemy and not (_ship.radar_detected or _ship.hydro_detected):
		return true
	return false

func _should_use_hydro() -> bool:
	# Decides whether to activate Hydroacoustic Search without omniscient
	# knowledge.  Only information that is legitimately visible to this team
	# is considered, so bots cannot cheat.
	#
	# Triggers:
	#   1. Already-detected enemy torpedoes (visible_to_enemy == true) are
	#      within ~8 km and pointed generally toward this ship.
	#   2. A spotted enemy DD is within torpedo-threat range (~8 km).
	#   3. This ship is spotted but no visible enemy is close enough to
	#   account for it - a concealed ship must be nearby.
	#   4. An enemy DD was last seen at close range (<8 km) recently (<45 s).
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return false

	var my_team: int = _ship.team.team_id

	# --- Trigger 1: already-tracked incoming torpedo ---
	# BotControllerV4._register_torpedo_obstacles() already filters for armed,
	# visible (detected), enemy torpedoes within torpedo_track_range and keeps
	# a live count.  Re-scanning TorpedoManager here would be redundant.
	var controller = get_parent()
	if controller != null and controller.get("tracked_torpedo_count") != null:
		if (controller.tracked_torpedo_count as int) > 0:
			return true

	# --- Trigger 2: spotted enemy DD within torpedo-threat range ---
	var spotted := server_node.get_valid_targets(my_team)
	for enemy in spotted:
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		if enemy.ship_class == Ship.ShipClass.DD:
			var dist := enemy.global_position.distance_to(_ship.global_position)
			if dist < 8000.0:
				return true

	# --- Trigger 3: spotted by a ship we cannot see ---
	# If we are detected but no visible enemy is close enough to account for
	# our detection, a concealed ship must be within our concealment radius.
	# Using hydro here is a legitimate deduction, not omniscient knowledge.
	if _ship.visible_to_enemy and _ship.concealment != null:
		var my_concealment := _ship.concealment.get_concealment()
		var has_visible_spotter := false
		for enemy in spotted:
			if not is_instance_valid(enemy):
				continue
			var dist := enemy.global_position.distance_to(_ship.global_position)
			if dist <= my_concealment:
				has_visible_spotter = true
				break
		if not has_visible_spotter:
			return true

	# --- Trigger 4: unspotted enemy DD recently seen within hydro spotting range ---
	# The unspotted-enemies dict is also written by _refresh_hydro_lkp() every
	# HYDRO_LKP_INTERVAL seconds, which keeps the timestamp perpetually fresh for
	# any DD in another friendly's hydro cone.  Using 8 000 m here (double the
	# default 4 000 m hydro spotting range) caused trigger 4 to fire on DDs that
	# are well outside the range where this ship's hydro would actually help.
	# Fix: gate on the actual hydro spotting range (+ 1 km lead for movement).
	var hydro_threat_range := 5000.0  # conservative default if consumable not found
	if hydroacoustic_search != -1:
		for c in _ship.consumable_manager.equipped_consumables:
			if c.id == hydroacoustic_search and c is HydroacousticSearch:
				hydro_threat_range = c.spotting_range + 1000.0
				break
	var unspotted := server_node.get_unspotted_enemies(my_team)
	var unspotted_times := server_node.get_unspotted_enemy_times(my_team)
	var current_time := Time.get_ticks_msec() / 1000.0
	for enemy in unspotted.keys():
		if not is_instance_valid(enemy):
			continue
		if not (enemy.ship_class == Ship.ShipClass.DD):
			continue  # only DDs carry torps worth reacting to
		var elapsed: float = current_time - unspotted_times.get(enemy, 0.0)
		if elapsed > 45.0:
			continue  # last-known position too stale to act on
		var last_pos: Vector3 = unspotted[enemy]
		var dist := last_pos.distance_to(_ship.global_position)
		if dist < hydro_threat_range:
			return true

	return false


func _should_use_radar() -> bool:
	# Decides whether to activate Radar without omniscient knowledge.
	# Only information legitimately available to this bot is used.
	#
	# Triggers:
	#   1. This ship is detected but no visible enemy is within radar range
	#      (~8 km) to account for it — a concealed enemy must be nearby.
	#   2. An unspotted enemy has a recent LKP (< 30 s) within radar range —
	#      the LKP is already in the shared unspotted-enemies table so this is
	#      not omniscient; it capitalises on information the team already has.
	#   3. This ship's detection_type is HYDRO or RADAR — an enemy with active
	#      detection is within ~4–8 km.  If no enemy is currently visible,
	#      firing radar may flush out that concealed spotter.
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return false

	var my_team: int = _ship.team.team_id
	const RADAR_RANGE: float = 8000.0

	var spotted := server_node.get_valid_targets(my_team)

	# --- Trigger 1: detected but no visible enemy within radar range ---
	if _ship.visible_to_enemy and _ship.concealment != null:
		var has_close_visible := false
		for enemy in spotted:
			if not is_instance_valid(enemy):
				continue
			if enemy.global_position.distance_to(_ship.global_position) <= RADAR_RANGE:
				has_close_visible = true
				break
		if not has_close_visible:
			return true

	# --- Trigger 2: recent unspotted LKP within radar range ---
	var unspotted       := server_node.get_unspotted_enemies(my_team)
	var unspotted_times := server_node.get_unspotted_enemy_times(my_team)
	var current_time    := Time.get_ticks_msec() / 1000.0
	for enemy in unspotted.keys():
		if not is_instance_valid(enemy):
			continue
		var elapsed: float = current_time - unspotted_times.get(enemy, 0.0)
		if elapsed > 30.0:
			continue  # LKP too stale; enemy has likely moved away
		var dist := (unspotted[enemy] as Vector3).distance_to(_ship.global_position)
		if dist < RADAR_RANGE:
			return true

	# --- Trigger 3: being detected by active sonar/radar with no visible enemies ---
	# detection_type is server-authoritative state the bot legitimately reads.
	# HYDRO means an enemy pinger is within ~4 km; RADAR within ~8 km.
	# If no enemy is currently visible, the concealed pinger may be within radar range.
	if (_ship.detection_type == Ship.DetectionType.HYDRO or \
			_ship.detection_type == Ship.DetectionType.RADAR) and spotted.is_empty():
		return true

	return false
