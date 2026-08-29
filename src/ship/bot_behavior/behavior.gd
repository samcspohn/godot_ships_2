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
const TORP_BLEND_REFERENCE_TIME: float = 50.0 # flight time (s) at which the long average reaches full weight

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

## How good this bot is meant to be. Set at spawn (see
## GameServer._add_player); defaults to REGULAR so a bot created without one
## behaves exactly as every bot did before aptitude existed.
var aptitude: BotAptitude = BotAptitude.for_level(BotAptitude.Level.REGULAR)

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

# Skill instances. One set lives here rather than one set per behaviour
# subclass: the shared ladder in _nav_core() dispatches to them by name, and
# three private copies of the same eight skills was how BB ended up holding a
# SkillHunt it never called and DD a SkillRetreat only the CV used.
var _skill_hunt: SkillHunt = SkillHunt.new()
var _skill_chase: SkillChase = SkillChase.new()
var _skill_cover: SkillFindCover = SkillFindCover.new()
var _skill_kite: SkillKite = SkillKite.new()
var _skill_push: SkillPush = SkillPush.new()
var _skill_camp: SkillCamp = SkillCamp.new()
var _skill_flank: SkillFlank = SkillFlank.new()
var _skill_spot: SkillSpot = SkillSpot.new()
var _skill_retreat: SkillRetreat = SkillRetreat.new()
var _skill_broadside: SkillBroadside = SkillBroadside.new()
var _skill_spread: SkillSpread = SkillSpread.new()

# Skill instances (created in subclass _init or on first use)
var _skills: Dictionary = {}  # StringName -> BotSkill

## Doctrine — the numbers this bot fights by. Built once on first use from
## whatever doctrine() returns.
var _doctrine: BotDoctrine = null

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

func get_chase_max_threat() -> float:
	"""Highest threat score at which running down a last-known position is still
	worth it.  Above this the ship takes cover instead: chasing a contact nobody
	can see, at flank speed, into an unknown picture is how bots die."""
	return 0.5

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
	##      → If detected with active bloom, a concealed ship has LOS; record an
	##        inferred contact and suppress. Otherwise safe to fire.
	##   2. For each spotted enemy:
	##      a. LOS blocked by terrain → skip (terrain shields us from them).
	##      b. LOS unblocked + we are already detected + enemy inside base
	##         radius → suppression is useless (they see us regardless) → false.
	##      c. LOS unblocked → open water; firing will expose/keep us exposed
	##        → suppress_useful = true.
	##   3. All spotted enemies have blocked LOS:
	##      → If detected, a concealed ship must have LOS; record inferred contact + suppress.
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
		# visible_to_enemy, not is_detected(): the deduction is "somebody has eyes
		# on us", and a ping lights us with nobody in LOS at all.
		if _ship.visible_to_enemy and concealment_node.bloom_value > 0.0:
			_infer_concealed_spotter(server)
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
			if _ship.is_detected() and d < base_radius:
				# Already detected and enemy is inside base detection radius
				# with direct LOS — suppressing bloom won't make them lose us,
				# and neither will it shake a ping.
				return false
			# Open-water enemy: firing creates or sustains bloom that exposes us.
			suppress_useful = true

	if all_los_blocked:
		if _ship.visible_to_enemy:
			# Terrain covers every spotted enemy yet we are still detected —
			# a concealed ship must have direct LOS. visible_to_enemy only: a ping
			# is not evidence of a hidden ship in LOS.
			_infer_concealed_spotter(server)
			return true
		# Not detected and all enemies behind terrain — safe to fire.
		return false

	return suppress_useful


func _infer_concealed_spotter(server: GameServer) -> void:
	## Bloom with nothing in sight means a concealed ship has line of sight to
	## us. That is real information, and the navigation and threat systems should
	## act on it - but it is a deduction, not a sighting, so it goes into the
	## inferred-contact table rather than the LKP tables. Nothing that aims a gun
	## reads it (see get_contact_solution): a bot may back off, take cover, or go
	## looking for a ship it has worked out is nearby, and may not shell it.
	##
	## What bloom establishes is a maximum RANGE, not a bearing: whoever it is has
	## us inside our own detection radius with clear LOS. So the bearing has to
	## come from somewhere else - the spotter's last-known position if there is
	## one, otherwise wherever the presumption model already has it - and the
	## contact is placed along that bearing, pulled in to the range bound.
	##
	## It is never anchored on our own position. A contact recorded on top of the
	## ship that deduced it publishes a threat zone onto that ship (see
	## GameServer._publish_team_threats), which reads as an enemy sitting on a
	## friendly and poisons every cover and standoff decision made around it. If
	## no bearing can be had, nothing is recorded: the presumption model's own
	## spawn-line estimate is already a better answer than a point on ourselves.
	var concealment_node = _ship.concealment
	if concealment_node == null:
		return
	var spotter: Ship = concealment_node.spotted_by
	if not is_instance_valid(spotter):
		return
	if not spotter.health_controller.is_alive():
		return
	# Nothing to deduce about a ship we can already see.
	var my_team: int = _ship.team.team_id
	if spotter in server.get_valid_targets(my_team):
		return

	var detect_radius: float = (concealment_node.params.p() as ConcealmentParams).radius
	var my_pos: Vector3 = _ship.global_position

	# Where to take the bearing from. A last-known position is preferred: if it
	# still has clear LOS to us the spotter may simply not have moved, and that
	# real observation already says everything this deduction would, so we leave
	# it alone rather than talking over it with something vaguer.
	var unspotted: Dictionary = server.get_unspotted_enemies(my_team)
	var bearing_from: Vector3 = Vector3.ZERO
	var have_bearing: bool = false
	if unspotted.has(spotter):
		var last_known: Vector3 = unspotted[spotter]
		if not NavigationMapManager.is_los_blocked(last_known, my_pos):
			return
		bearing_from = last_known
		have_bearing = true
	else:
		# Never seen. The presumption model still has an opinion about which
		# flank it is on, built from the spawns and the clock, and that opinion
		# is the only direction anyone has earned.
		for guess in get_presumed_contacts():
			if guess.ship == spotter:
				bearing_from = guess.position
				have_bearing = true
				break
	if not have_bearing:
		return

	var to_contact: Vector3 = bearing_from - my_pos
	to_contact.y = 0.0
	var d: float = to_contact.length()
	if d < 1.0:
		# Degenerate bearing - the only anchor available would be on top of us.
		return
	# Keep the direction, give up the range: bloom says it is no further off than
	# our detection radius, and says nothing at all about how much closer.
	var anchor: Vector3 = my_pos + to_contact / d * minf(d, detect_radius)

	server.record_inferred_contact(
		my_team,
		spotter,
		anchor,
		Time.get_ticks_msec() / 1000.0,
		detect_radius,
		"bloom")

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

# ============================================================================
# CONTACT SOLUTIONS
# What a bot legitimately knows about an enemy's position and motion. Spotted
# ships are read live; ships held only on a last-known position are read from the
# server's frozen LKP record and dead-reckoned forward, so nothing here ever
# tracks a ship nobody can see.
# ============================================================================

# Dead reckoning past this age is fiction - a ship unseen for this long has
# almost certainly changed course, so the extrapolation stops growing rather than
# flinging the solution kilometres down a heading nobody has confirmed. Matches
# the staleness horizon _should_use_radar() already applies to an LKP.
const LKP_MAX_LEAD_AGE: float = 30.0
# Priority multiplier applied to a target held only on an LKP. Shooting at a
# dead-reckoned contact is a real option when everything has gone dark, but it
# should always lose to a ship someone can actually see.
const LKP_TARGET_PRIORITY_MULT: float = 0.4
## Fallback for the staleness limit below when a bot somehow has no aptitude.
## Equal to BotAptitude REGULAR, which is what this was as a flat constant.
const LKP_TARGET_MAX_AGE_DEFAULT: float = 5.0
## Fallback for the muzzle-flash window. Zero, not REGULAR-equal by accident:
## REGULAR does not shoot at a flash contact either, and a bot with no aptitude
## at all should take the more conservative of the two readings.
const GUNFIRE_LKP_MAX_AGE_DEFAULT: float = 0.0

## How stale a last-known position may be and still be offered to the guns - see
## pick_target. Deliberately much shorter than LKP_MAX_LEAD_AGE: dead reckoning
## stays useful for half a minute when the question is "roughly where is that
## fleet", but a gun is a point solution. Within a few seconds a ship has had
## time to turn, and shells walked onto a heading nobody has confirmed since are
## wasted salvos that also give away the firing ship for nothing.
##
## Per-bot rather than fixed: holding a dead-reckoned solution together while a
## ship is dark is a gunnery skill, and it is the right place to express "better
## shot" - unlike intel, which the tiers must not differ on in any way a gun can
## read (see BotAptitude).
func lkp_target_max_age() -> float:
	return aptitude.lkp_target_max_age if aptitude != null else LKP_TARGET_MAX_AGE_DEFAULT

## The same limit for a contact located only by the flash of a salvo, where 0
## means the bot will not shoot at one at all. Far shorter than the sensor-held
## case for every tier that takes the shot, because there is nothing behind it:
## a flash is recorded stationary, so the "solution" is simply the point the
## ship was standing at one instant, and it walks out from under the shells as
## soon as it moves. See BotAptitude.gunfire_lkp_max_age.
func gunfire_lkp_max_age() -> float:
	return aptitude.gunfire_lkp_max_age if aptitude != null else GUNFIRE_LKP_MAX_AGE_DEFAULT

## Returns what this bot believes about `target`:
##   position - live, or the LKP dead-reckoned forward by the age of the contact
##   velocity - live, or the velocity frozen when it was last observed
##   basis    - live, or a basis built from the heading frozen at that instant
##   age      - 0 for a spotted ship, else how long ago the contact was observed
##   is_lkp   - true when this is a last-known position rather than a live one
##   source   - which kind of intel the LKP came from (GameServer.LKP_SOURCE_*)
##   valid    - false when the bot has no idea where the ship is at all
## `valid` deliberately does not consider age: callers apply whatever staleness
## policy suits them (the guns use lkp_target_max_age(); aviation will attack an
## older contact, since flying out to look costs it nothing).
func get_contact_solution(target: Ship) -> Dictionary:
	if target.visible_to_enemy:
		return {
			position = target.global_position,
			velocity = target.linear_velocity,
			basis = target.global_transform.basis,
			age = 0.0,
			is_lkp = false,
			source = GameServer.LKP_SOURCE_OBSERVED,
			valid = true,
		}
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return {valid = false}
	var team_id: int = _ship.team.team_id
	var unspotted := server_node.get_unspotted_enemies(team_id)
	var times := server_node.get_unspotted_enemy_times(team_id)
	if not unspotted.has(target) or not times.has(target):
		return {valid = false}
	var age: float = Time.get_ticks_msec() / 1000.0 - float(times[target])
	var frozen_vel: Vector3 = server_node.get_unspotted_enemy_velocities(team_id).get(target, Vector3.ZERO)
	var frozen_rot: float = float(server_node.get_unspotted_enemy_rotations(team_id).get(target, 0.0))
	var lkp: Vector3 = unspotted[target]
	var source: String = String(server_node.get_unspotted_enemy_sources(team_id).get(
		target, GameServer.LKP_SOURCE_OBSERVED))
	return {
		position = lkp + frozen_vel * clampf(age, 0.0, LKP_MAX_LEAD_AGE),
		velocity = frozen_vel,
		basis = Basis.from_euler(Vector3(0.0, frozen_rot, 0.0)),
		age = maxf(age, 0.0),
		is_lkp = true,
		source = source,
		valid = true,
	}

# ============================================================================
# AIM SOLUTION
# How this bot leads a target, and how wrong it gets it. Two separate things are
# modelled here, and they are separate on purpose:
#
#   Whether the bot leads along the target's ARC or along its instantaneous
#   heading. A ship under helm travels a circle; over a fifteen-second shell
#   flight that is hundreds of metres away from where its heading pointed, and
#   a bot that ignores it misses consistently to the OUTSIDE of the turn. The
#   arithmetic lives in ProjectilePhysicsWithDragV2 rather than here, since it
#   is ballistics and not judgement.
#
#   How badly the bot misreads the numbers it feeds that solver - how fast the
#   target is going, and how hard it is turning. This is judgement, so it lives
#   here, and it is the difference between the tiers.
# ============================================================================

## How long a bot stays committed to one wrong reading of a target before taking
## another look. Re-rolling every frame would average out to a perfect solution
## across a salvo and read as dispersion rather than as misjudgement; a gunner
## who has a ship's speed wrong stays wrong about it for a bit, then corrects.
const AIM_ERROR_HOLD_MS: int = 6000
## Bounds on the misreadings, so a bad roll is a bad shot and never a shot at
## something going backwards or turning the other way.
const AIM_SPEED_MULT_MIN: float = 0.35
const AIM_SPEED_MULT_MAX: float = 1.65
const AIM_TURN_MULT_MIN: float = 0.0
const AIM_TURN_MULT_MAX: float = 2.0

var _aim_error: Dictionary = {}   # Ship -> {speed_mult, turn_mult, until_ms}
var _aim_rng := RandomNumberGenerator.new()

## This bot's current reading of `target`, as multipliers on the truth. Held for
## AIM_ERROR_HOLD_MS, then re-rolled - so a bot's shots stay coherently wrong for
## a while rather than jittering around the right answer.
func _target_aim_error(target: Ship) -> Dictionary:
	var now_ms: int = Time.get_ticks_msec()
	var held: Dictionary = _aim_error.get(target, {})
	if not held.is_empty() and now_ms < int(held.get("until_ms", 0)):
		return held
	var speed_sd: float = aptitude.lead_speed_jitter if aptitude != null else 0.0
	var turn_sd: float = aptitude.turn_rate_jitter if aptitude != null else 0.0
	var rolled := {
		speed_mult = clampf(1.0 + _aim_rng.randfn(0.0, speed_sd),
			AIM_SPEED_MULT_MIN, AIM_SPEED_MULT_MAX) if speed_sd > 0.0 else 1.0,
		turn_mult = clampf(1.0 + _aim_rng.randfn(0.0, turn_sd),
			AIM_TURN_MULT_MIN, AIM_TURN_MULT_MAX) if turn_sd > 0.0 else 1.0,
		until_ms = now_ms + AIM_ERROR_HOLD_MS,
	}
	_aim_error[target] = rolled
	# Cheap housekeeping: drop readings of ships that are gone.
	if _aim_error.size() > 24:
		for k in _aim_error.keys():
			if not is_instance_valid(k) or not k.is_alive():
				_aim_error.erase(k)
	return rolled

## The rate `target` is believed to be turning at, radians/sec about +Y.
##
## Zero unless this bot reckons turns at all, and zero for anything it cannot
## actually see: a rate of turn is something you read off a ship by watching it,
## and a contact held on a last-known position is not being watched. Concealment
## is not negotiable just because the bot is a good shot.
func _believed_yaw_rate(target: Ship, contact: Dictionary) -> float:
	if aptitude == null or not aptitude.turn_reckoning:
		return 0.0
	if contact.get("is_lkp", true):
		return 0.0
	if not is_instance_valid(target):
		return 0.0
	return target.angular_velocity.y * float(_target_aim_error(target).turn_mult)

## Where to put the shells for `target`: the full firing solution, arc-aware and
## with this bot's misreadings baked in. Returns null when there is no solution.
##
## `aim_point` is the point being led (already offset by target_aim_offset).
func aim_lead_point(target: Ship, contact: Dictionary, aim_point: Vector3) -> Variant:
	var shell_params = _ship.artillery_controller.get_shell_params()
	if shell_params == null:
		return null
	var err := _target_aim_error(target)
	var believed_vel: Vector3 = contact.velocity * float(err.speed_mult) \
		/ ProjectileManager.get_shell_time_multiplier()
	var yaw_rate: float = _believed_yaw_rate(target, contact)
	var lead_result: Array
	if absf(yaw_rate) > 0.0:
		lead_result = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector_turning(
			_ship.global_position, aim_point, believed_vel, yaw_rate, shell_params)
	else:
		lead_result = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(
			_ship.global_position, aim_point, believed_vel, shell_params)
	return lead_result[2]

## Whether the guns should be offered this contact at all: a live spot always, an
## LKP only while it is fresh enough that dead reckoning still means something.
##
## Which window applies depends on where the contact came from. A ship held by
## hydro, radar or air - or one that went dark in front of somebody - is real
## enough to shoot at for a few seconds. A ship known only from the flash of a
## salvo is not: most bots leave it alone entirely, and the ones that do take
## the shot get a much shorter window (see gunfire_lkp_max_age).
func is_engageable_contact(sol: Dictionary) -> bool:
	if not sol.get("valid", false):
		return false
	if not sol.is_lkp:
		return true
	if String(sol.get("source", GameServer.LKP_SOURCE_OBSERVED)) == GameServer.LKP_SOURCE_GUNFIRE:
		var window: float = gunfire_lkp_max_age()
		return window > 0.0 and sol.age <= window
	return sol.age <= lkp_target_max_age()

## Where the turrets should point for `target` given what the bot believes about
## it, aim offset included. Returns null when there is no usable solution, which
## is the caller's cue to hold rather than swing onto a ship it has lost.
func contact_aim_point(target: Ship) -> Variant:
	var contact := get_contact_solution(target)
	if not is_engageable_contact(contact):
		return null
	return contact.position + contact.basis * target_aim_offset(target)

var potential_target_weight_cache: Dictionary = {}  # Ship -> float
func get_potential_target_weight(target: Ship) -> float:
	if potential_target_weight_cache.has(target):
		return potential_target_weight_cache[target]
	var my_range = _ship.artillery_controller.get_params()._range
	var hp_ratio = target.health_controller.current_hp / target.health_controller.max_hp
	# Score the position the bot believes in, not the one it cannot see
	var sol := get_contact_solution(target)
	var sol_pos: Vector3 = sol.get("position", target.global_position)
	var sol_basis: Basis = sol.get("basis", target.global_transform.basis)

	# Prefer close targets; falls off exponentially beyond gun range
	var weight = exp(-sol_pos.distance_to(_ship.global_position) / (my_range / 3))

	# Prefer targets presenting a large side profile (easier to hit)
	var target_heading = sol_basis.z.normalized()
	var to_target = (sol_pos - _ship.global_position).normalized()
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
	weight += side_profile * 0.01

	# Prefer damaged targets (finish them off), but keep full-health targets at 10% weight floor
	weight += maxf(pow(1.0 - hp_ratio, 2.0), 0.5)


	# # Prefer high-threat targets
	# weight += target.stats.total_damage * (1.0 / 150_000.0)

	# A contact held only on a last-known position is worth shooting at, but only
	# once nothing visible outranks it
	if sol.get("is_lkp", false):
		weight *= LKP_TARGET_PRIORITY_MULT

	potential_target_weight_cache[target] = weight
	return weight

func pick_target(targets: Array[Ship], last_target: Ship) -> Ship:
	potential_target_weight_cache.clear()
	# Ships held only on a fresh last-known position are candidates too, at
	# reduced priority (see get_potential_target_weight). Without them the guns
	# sit idle the moment every enemy goes dark, even with a contact well inside
	# gun range that was observed seconds ago.
	var candidates: Array[Ship] = targets.duplicate()
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node != null:
		for enemy: Ship in server_node.get_unspotted_enemies(_ship.team.team_id).keys():
			if not is_instance_valid(enemy) or not enemy.is_alive():
				continue
			if enemy.visible_to_enemy or candidates.has(enemy):
				continue
			candidates.append(enemy)
	candidates.sort_custom(func(a: Ship, b: Ship) -> bool:
		return get_potential_target_weight(a) > get_potential_target_weight(b)
	)

	# Find the highest-weight target we have a usable solution for and can shoot at
	var best: Ship = null
	for potential in candidates:
		if is_engageable_contact(get_contact_solution(potential)) and can_hit_target(potential):
			best = potential
			break

	if best == null:
		return null

	# # Keep the current target unless a significantly better one exists (25% threshold)
	# if last_target != null and last_target.is_alive() \
	# 		and last_target.visible_to_enemy and can_hit_target(last_target):
	# 	var last_weight = get_potential_target_weight(last_target)
	# 	var best_weight = get_potential_target_weight(best)
	# 	if best_weight <= last_weight * 1.1:
	# 		return last_target

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
	if not _ship.is_detected():
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
				weight *= 100.0  # Boost weight for enemies actively shooting at us
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
				weight *= 100.0  # Boost weight for enemies actively shooting at us
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

## Where the enemy is for the purpose of deciding which SIDE of something to sit
## on. Falls back to the presumption model when nothing is spotted or held.
##
## Deliberately separate from _get_spotted_danger_center(), which several callers
## rely on returning ZERO to mean "nothing confirmed" - one of them points the
## turrets at it, and turrets must never swing onto a guess. Choosing a side is
## the opposite case: there is always a side, and before first contact the honest
## answer is "away from where their fleet must be coming from", not "no opinion".
## Without this, hide-side geometry silently switched off for the whole opening
## of a match - exactly when a bot is picking the island it will fight from.
func _get_positioning_danger_center() -> Vector3:
	var confirmed := _get_spotted_danger_center()
	if confirmed != Vector3.ZERO:
		return confirmed
	var weighted := Vector3.ZERO
	var total := 0.0
	for guess in get_presumed_contacts():
		var w: float = maxf(EnemyPresumption.certainty(guess), 0.05)
		weighted += (guess.position as Vector3) * w
		total += w
	if total > 0.00001:
		var out: Vector3 = weighted / total
		if not (is_nan(out.x) or is_nan(out.z)):
			return out
	# Nothing believed at all: the enemy spawn is still a fact of the map.
	_initialize_spawn_cache()
	return _cached_enemy_spawn

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

	## Bias toward friendlies when low HP
	#if hp_ratio < params.cautious_hp_threshold:
		##var nearest_cluster = server_node.get_nearest_friendly_cluster(_ship.global_position, _ship.team.team_id)
		#if not nearest_cluster.is_empty():
			#var cluster_center: Vector3 = nearest_cluster.center
			#var to_cluster = (cluster_center - _ship.global_position).normalized()
			#desired_pos = closest_pos - (to_target * 0.6 + to_cluster * 0.4).normalized() * standoff

	return _get_valid_nav_point(desired_pos)



func can_hit_target(target: Ship) -> bool:
	"""Check if we can actually hit the target (not blocked by terrain/islands).
	Uses sim_can_shoot_over_terrain_static from ship center at deck height."""

	var gun_params = _ship.artillery_controller.get_params()
	if gun_params == null:
		return false
	# Check the shot the bot would actually take, which for an unspotted contact
	# is at its dead-reckoned last-known position rather than where it really is
	var contact := get_contact_solution(target)
	if not contact.get("valid", false):
		return false
	var sol_pos: Vector3 = contact.position
	if sol_pos.distance_to(_ship.global_position) > gun_params._range * 1.5:
		# Quick early-out for very distant targets to avoid expensive sim checks
		return false

	var shell_params = _ship.artillery_controller.get_shell_params()
	if shell_params == null:
		return false

	var adjusted_target_pos = sol_pos + contact.basis * target_aim_offset(target)

	# Lead exactly the way this bot would actually fire - same arc reckoning,
	# same misjudgement - so the terrain check answers the question about the
	# shot being taken rather than about an idealised one.
	var lead_pos = aim_lead_point(target, contact, adjusted_target_pos)
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

# A contact nobody has seen for this long is no longer treated as a hard threat
# for cover geometry. The server seeds an LKP for the whole enemy team on first
# contact and never ages them out, so without this filter a cover position would
# have to occlude flat LOS to every enemy on the map simultaneously — which no
# island can do, and cover is then never found at all.
const THREAT_LKP_MAX_AGE: float = LKP_MAX_LEAD_AGE

## Where the enemy probably is, for the ships nobody is holding - see
## EnemyPresumption, which builds it from the spawns, the clock and the team
## list rather than from anything it is not entitled to see. Positioning only:
## a guess never becomes a target.
var _presumption := EnemyPresumption.new()

func get_presumed_contacts(lead: float = 0.0) -> Array[Dictionary]:
	if _ship == null or _ship.team == null:
		return []
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if aptitude != null:
		_refresh_intuition(server_node)
		_presumption.configure(aptitude.use_spawn_line, aptitude.radius_growth_mult,
			aptitude.kinematic_reckoning, _intuition)
	return _presumption.contacts(_ship.team.team_id, server_node, lead)

## How far ahead this bot solves for when choosing where to sit. See
## BotAptitude.lead_horizon: zero is "where is everyone now", which is how a ship
## ends up behind an island that masks it this instant and leaves it in the open
## by the time the push it could see coming actually arrives.
func lead_horizon() -> float:
	return aptitude.lead_horizon if aptitude != null else 0.0

# ---------------------------------------------------------------------------
# INTUITION - the sanctioned cheat
# ---------------------------------------------------------------------------
## Ground-truth fixes on enemy ships, Ship -> {position, velocity, rotation,
## time}, taken every BotAptitude.intuition_interval seconds and never in
## between. This is the one place a bot is handed something it did not earn, so
## it is worth being exact about what it is and is not.
##
## It is a periodic FIX, not a feed: between refreshes the error bar opens like
## any other anchor's, so what an ace plays like is somebody who checks the
## minimap and reasons well from it, not somebody seeing through islands.
##
## And it is walled off. This table is read by EnemyPresumption and by nothing
## else - get_contact_solution() reads the LKP tables, so an intuition fix is
## structurally incapable of producing an aim point, exactly like a deduction.
## An ace positions better. It does not shoot at what it cannot see.
var _intuition: Dictionary = {}
var _intuition_last_refresh: float = -INF

func _refresh_intuition(server_node: GameServer) -> void:
	if server_node == null or aptitude == null or _ship == null or _ship.team == null:
		return
	var interval: float = aptitude.intuition_interval
	if interval <= 0.0:
		if not _intuition.is_empty():
			_intuition.clear()
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _intuition_last_refresh < interval:
		# Drop anyone who died since the last fix so a sunk ship cannot go on
		# steering this bot around a patch of empty water.
		for enemy in _intuition.keys():
			if not is_instance_valid(enemy) or not enemy.is_alive():
				_intuition.erase(enemy)
		return
	_intuition_last_refresh = now
	_intuition.clear()
	var enemy_team: int = 1 - _ship.team.team_id
	for enemy in server_node.get_team_ships(enemy_team):
		if not is_instance_valid(enemy) or not enemy.is_alive():
			continue
		_intuition[enemy] = {
			position = Vector3(enemy.global_position.x, 0.0, enemy.global_position.z),
			velocity = enemy.linear_velocity,
			rotation = enemy.rotation.y,
			time = now,
		}

## How close a presumed enemy has to be before it constrains where this ship
## hides - about the range from which something could actually shoot back.
const PRESUMED_THREAT_REACH: float = 18000.0
## How much of an enemy's threat survives not knowing exactly where it is,
## across the full range of the presumption's own confidence (see
## EnemyPresumption.certainty). Never the full weight of a ship in plain sight,
## and never nothing at all.
const PRESUMED_CERTAINTY_MAX: float = 0.85
const PRESUMED_CERTAINTY_MIN: float = 0.25

## At most this many guesses may constrain one decision. Every threat added is
## another line a cover position has to be masked from, and a position masked
## from everything on the map generally does not exist. The nearest few are the
## ones that would actually be shooting.
const PRESUMED_THREAT_LIMIT: int = 3
## And only guesses still worth calling a position. Once the uncertainty is
## this wide the guess says "somewhere over there", which is not something a
## cover position can be masked from - letting it veto cover anyway would leave
## a ship refusing every island on the map on the strength of a shrug.
const PRESUMED_THREAT_MAX_RADIUS: float = 6000.0

func _gather_threat_positions(ship: Ship, lead: float = 0.0) -> Array:
	"""Threat positions the bot legitimately knows about: currently visible
	enemies, plus last-known positions still fresh enough to mean something
	(dead-reckoned forward). Stale contacts are dropped — see THREAT_LKP_MAX_AGE.
	Made up to a full picture with the nearest presumed contacts, so a position
	is judged against the enemies that are probably there and not only against
	the ones that happen to be visible from it.

	`lead` asks the whole question `lead` seconds from now instead of this
	instant, for deciding where to BE rather than where to have been. Cover is
	the case that needs it: an island that masks a ship from where the enemy
	stands right now is worth nothing if the enemy will have rounded it by the
	time the ship arrives. Every source is carried forward, not just the guesses
	— a future picture with half its contacts left in the present is not a
	picture of anything."""
	var threats: Array = []
	var server_node: GameServer = ship.get_node_or_null("/root/Server")
	if server_node == null:
		return threats
	var held: Dictionary = {}
	for enemy in server_node.get_valid_targets(ship.team.team_id):
		if is_instance_valid(enemy) and enemy.health_controller.is_alive():
			held[enemy] = true
			threats.append(_led_position(enemy.global_position, enemy.linear_velocity, lead))
	var unspotted = server_node.get_unspotted_enemies(ship.team.team_id)
	for enemy_ship in unspotted.keys():
		if not is_instance_valid(enemy_ship):
			continue
		var sol := get_contact_solution(enemy_ship)
		if not sol.get("valid", false):
			continue
		if float(sol.age) > THREAT_LKP_MAX_AGE:
			continue
		held[enemy_ship] = true
		threats.append(_led_position(sol.position, sol.velocity, lead))
	# Everything else the enemy owns is somewhere too, and the whole point of
	# taking cover is to not be shot by it. Without this a cruiser tucks itself
	# behind an island from the one contact it can see and parks broadside to
	# the flank nobody has looked at all game.
	var guesses: Array[Dictionary] = []
	for guess in get_presumed_contacts(lead):
		if held.has(guess.ship):
			continue
		if float(guess.radius) > PRESUMED_THREAT_MAX_RADIUS:
			continue
		var guess_pos: Vector3 = guess.position
		var d: float = ship.global_position.distance_to(guess_pos)
		if d > PRESUMED_THREAT_REACH:
			continue
		guesses.append({dist = d, position = guess_pos})
	guesses.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.dist < b.dist)
	for k in range(mini(guesses.size(), PRESUMED_THREAT_LIMIT)):
		threats.append(guesses[k].position)
	return threats

## Runs an observed position forward on its observed course. Held to the same
## horizon the presumption model trusts a course over, so a lead never turns into
## a confident claim about a ship that has had time to do something else.
func _led_position(pos: Vector3, vel: Vector3, lead: float) -> Vector3:
	if lead <= 0.0:
		return pos
	var flat := Vector3(vel.x, 0.0, vel.z)
	var speed := flat.length()
	if speed < 1.0:
		return pos
	if speed > EnemyPresumption.KINEMATIC_SPEED_CAP:
		flat = flat / speed * EnemyPresumption.KINEMATIC_SPEED_CAP
	var trust: float = clampf(1.0 - lead / EnemyPresumption.KINEMATIC_TRUST_HORIZON, 0.0, 1.0)
	return pos + flat * lead * trust

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

## How far from our own spawn a ship has to be before "back toward the spawn" is
## a meaningful direction. Sitting on it, that vector is noise pointing nowhere.
const SAFE_DIR_SPAWN_MIN_DIST: float = 2000.0

func _compute_safe_direction(ship: Ship, server: GameServer) -> Vector3:
	"""Determine the 'safe' direction: toward our own lines.

	The spawn AXIS is the primary source, not the bearing from the ship to its
	own spawn. At the start of a match a ship is sitting on its spawn, so that
	bearing is a near-zero vector - it used to fail the length check, fall all
	the way through to the ship's forward vector, and freeze there. Ships spawn
	facing the enemy, so every bot began the match believing safety lay straight
	up the map, and took cover on the enemy side of every island it picked.
	The axis is well defined everywhere, including at the spawn itself."""
	_initialize_spawn_cache()
	if _cached_friendly_spawn != Vector3.ZERO:
		var dir = _cached_friendly_spawn - ship.global_position
		dir.y = 0.0
		# Only once the ship is properly off its spawn does its own bearing back
		# to it beat the axis - by then it carries real lateral information.
		if dir.length_squared() > SAFE_DIR_SPAWN_MIN_DIST * SAFE_DIR_SPAWN_MIN_DIST:
			return dir.normalized()
		if _cached_enemy_spawn != Vector3.ZERO:
			var axis = _cached_friendly_spawn - _cached_enemy_spawn
			axis.y = 0.0
			if axis.length_squared() > 1.0:
				return axis.normalized()
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

## Safe direction goes stale: it is derived from where the ship is and what it
## can see, and both change. Computing it once and keeping it for the whole match
## is how a value picked in the first frame - before the spawn cache was even
## populated - went on steering cover selection twenty minutes later.
const SAFE_DIR_REFRESH_MS: int = 2000
var _safe_dir_next_refresh_ms: int = -1

func _ensure_safe_dir(ship: Ship, server: GameServer) -> void:
	var now_ms: int = Time.get_ticks_msec()
	if _safe_dir_initialized and now_ms < _safe_dir_next_refresh_ms:
		return
	var fresh := _compute_safe_direction(ship, server)
	if fresh.length_squared() > 0.01:
		_cached_safe_dir = fresh
		_safe_dir_initialized = true
	_safe_dir_next_refresh_ms = now_ms + SAFE_DIR_REFRESH_MS

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

# ============================================================================
# COVER PRIORITY TARGETS
# ============================================================================
## How many enemies a cover search will try to build a position around before
## settling for one it can merely shoot something from. Each one costs another
## sweep of the island's candidate points, which is why the priority search only
## runs when the ship is already ON an island (see SkillFindCover) - choosing a
## new island stays on the cheap any-target path.
const COVER_PRIORITY_MAX: int = 3
## Weight multiplier for a contact closing on us at flank speed. Being shot at is
## a fact; being approached is an intention, and the whole point of this list is
## to notice a battleship deciding to come and dig us out before it arrives.
const COVER_CLOSING_WEIGHT: float = 2.5
## Weight multiplier for an enemy confirmed to be shooting at us right now.
const COVER_SHOOTER_WEIGHT: float = 3.0

## Enemies worth building a firing position around, most valuable first.
##
## Deliberately NOT pick_target(). That answers "what can I shoot right now",
## and filters out anything terrain currently blocks - which is exactly the
## enemy a better position would let us engage. Filtering by present
## shootability while searching for a place to shoot FROM is circular: it can
## only ever confirm the spot we are already in.
##
## Ranked by danger to this ship rather than by ease of killing: hull class fear
## (a cruiser is right to weigh a battleship heavily), whether it is closing, and
## whether it is shooting at us. That is what makes a CA build its position
## around the battleship pushing onto its island instead of around whichever
## destroyer happened to be in the arc first.
func cover_priority_targets(max_count: int = COVER_PRIORITY_MAX) -> Array:
	var out: Array = []
	if _ship == null or _ship.team == null:
		return out
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return out
	var my_pos: Vector3 = _ship.global_position

	var scored: Array[Dictionary] = []
	var seen: Dictionary = {}
	var pools: Array = [server_node.get_valid_targets(_ship.team.team_id),
		server_node.get_unspotted_enemies(_ship.team.team_id).keys()]
	for pool in pools:
		for enemy in pool:
			if not is_instance_valid(enemy) or not enemy.is_alive() or seen.has(enemy):
				continue
			seen[enemy] = true
			# Read through the contact solution so a contact held only on a
			# last-known position is placed where the bot believes it is, never
			# where it actually is.
			var sol := get_contact_solution(enemy)
			if not sol.get("valid", false):
				continue
			var weight: float = get_potential_target_weight(enemy)
			weight *= get_threat_class_weight(enemy.ship_class)

			var to_enemy: Vector3 = (sol.position as Vector3) - my_pos
			to_enemy.y = 0.0
			if to_enemy.length_squared() > 1.0:
				var closing: float = -(sol.velocity as Vector3).dot(to_enemy.normalized())
				if closing > 0.0:
					weight *= 1.0 + clampf(closing / EnemyPresumption.NOMINAL_FLANK_SPEED,
						0.0, 1.0) * COVER_CLOSING_WEIGHT
			if active_shooters_at_me.has(enemy):
				weight *= COVER_SHOOTER_WEIGHT

			scored.append({ship = enemy, weight = weight})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.weight) > float(b.weight))
	for i in range(mini(scored.size(), maxi(max_count, 0))):
		out.append(scored[i].ship)
	return out

## Where to aim a shootability test at `enemy`, using only what the bot is
## entitled to know. Null when it has no idea where the ship is.
func cover_test_position(enemy: Ship) -> Variant:
	var sol := get_contact_solution(enemy)
	if not sol.get("valid", false):
		return null
	return (sol.position as Vector3) + (sol.basis as Basis) * target_aim_offset(enemy)

## Can a ship standing at `from_pos` put a shell on `target_pos`, terrain and all?
func _can_shoot_point_from(from_pos: Vector3, target_pos: Vector3, shell_params, gun_range_sq: float) -> bool:
	if shell_params == null:
		return false
	if from_pos.distance_squared_to(target_pos) > gun_range_sq:
		return false
	var gun_proxy_pos = from_pos + Vector3(0, _ship.movement_controller.ship_draft / 2.0, 0)
	var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(gun_proxy_pos, target_pos, shell_params)
	if sol[0] == null:
		return false
	return Gun.sim_can_shoot_over_terrain_static(gun_proxy_pos, sol[0], sol[1], shell_params, _ship).can_shoot_over_terrain

## Whether anything at all in `targets` can be engaged from `from_pos`.
func _can_shoot_at_any_from(from_pos: Vector3, targets: Array, shell_params, gun_range_sq: float) -> bool:
	if shell_params == null:
		return false
	for t_ship in targets:
		if not is_instance_valid(t_ship) or not t_ship.health_controller.is_alive():
			continue
		var target_pos = t_ship.global_position + t_ship.global_basis * target_aim_offset(t_ship)
		if _can_shoot_point_from(from_pos, target_pos, shell_params, gun_range_sq):
			return true
	return false

func _find_cover_position_on_island(island_center: Vector3, island_radius: float, hide_heading: float, threats: Array, targets: Array, max_range: float, avoid_positions: Array = [], min_separation: float = 0.0, priority_targets: Array = [], anchor_heading: float = NAN) -> Dictionary:
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
	# Only populated on the priority path; see the sweep below.
	var concealed_candidates: Array[Dictionary] = []
	var offset_clearance = clearance * 2.0
	var min_ring_separation_sq = (clearance * 0.5) * (clearance * 0.5)
	# Sweep the hide window centred on hide_heading, so the island's actual
	# hidden face is always sampled.  (Sweeping outward from the ship-facing side
	# instead only overlapped the hide window in two narrow slivers whenever the
	# ship approached from the threat side, so nearby islands were rejected and
	# the search ran on to a distant one.)  Ties inside the window are broken
	# toward whichever side the ship is already approaching from.
	#
	# An anchor_heading overrides that centre with the bearing the ship already
	# holds around THIS island.  A re-search of the island a ship is already
	# using is not a fresh question: sweeping outward from hide_heading picks
	# whichever face the window happens to sample first, so a few degrees of
	# drift in the threat picture flips the answer to the far side and the ship
	# sails around the island to reach it, then back again next tick.  Starting
	# at the bearing already held returns the nearest viable point to where the
	# ship stands, which is usually the point it is already on.  The window is
	# widened by the gap to hide_heading so the hidden face is still reached
	# when the held side stops concealing, just later in the order.
	var ship_to_island_heading = atan2(my_pos.x - island_center.x, my_pos.z - island_center.z)
	var sweep_center := hide_heading
	var sweep_half_span := angle_half_span
	var ship_side: float
	if is_finite(anchor_heading):
		var to_hide := angle_difference(anchor_heading, hide_heading)
		sweep_center = anchor_heading
		sweep_half_span = minf(angle_half_span + absf(to_hide), PI)
		ship_side = signf(to_hide)
	else:
		ship_side = signf(angle_difference(hide_heading, ship_to_island_heading))
	if ship_side == 0.0:
		ship_side = 1.0
	var max_steps = int(ceil(sweep_half_span / maxf(angle_step, 0.001)))

	for step_idx in range(max_steps + 1):
		var offset = minf(float(step_idx) * angle_step, sweep_half_span)
		for side in range(1 if step_idx == 0 else 2):
			var signed_offset = 0.0 if step_idx == 0 else (offset * ship_side if side == 0 else -offset * ship_side)
			var heading = sweep_center + signed_offset

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

				# With a priority list the whole candidate set has to be swept
				# before anything is chosen - the first point that can shoot
				# SOMETHING is exactly the wrong answer when what we need is a
				# point that can shoot the ship coming for us. Bank the candidate
				# and decide once the sweep is done.
				if not priority_targets.is_empty():
					concealed_candidates.append({pos = pos, conflict = spacing_conflict})
					continue

				var can_shoot_any: bool = _can_shoot_at_any_from(pos, targets, shell_params, gun_range_sq)

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

	# ── Priority resolution ─────────────────────────────────────────────────
	# Every concealed point on the island is now known. Offer the whole set to
	# the most dangerous enemy first; only if no point on the island can reach
	# it does the next one get a turn. A position that can engage the ship
	# pushing onto us beats one that can engage something harmless, even when
	# the harmless one was found first and is closer to hand.
	if not priority_targets.is_empty():
		for pri in priority_targets:
			if not is_instance_valid(pri) or not pri.is_alive():
				continue
			var pri_pos = cover_test_position(pri)
			if pri_pos == null:
				continue
			var conflicted: Vector3 = Vector3.ZERO
			for cand in concealed_candidates:
				var cpos: Vector3 = cand.pos
				if not _can_shoot_point_from(cpos, pri_pos, shell_params, gun_range_sq):
					continue
				if not bool(cand.conflict):
					return { "pos": cpos, "can_shoot": true, "spacing_conflict": false }
				if conflicted == Vector3.ZERO:
					conflicted = cpos
			if conflicted != Vector3.ZERO:
				return { "pos": conflicted, "can_shoot": true, "spacing_conflict": true }
		# None of the priority enemies can be reached from anywhere on this
		# island. Fall back to the ordinary question - can we shoot anything at
		# all from here - so the island is not thrown away over it.
		for cand in concealed_candidates:
			var cpos2: Vector3 = cand.pos
			var shootable: bool = _can_shoot_at_any_from(cpos2, targets, shell_params, gun_range_sq)
			if shootable:
				if not bool(cand.conflict):
					return { "pos": cpos2, "can_shoot": true, "spacing_conflict": false }
				if best_conflict_shootable == Vector3.ZERO:
					best_conflict_shootable = cpos2
			elif bool(cand.conflict):
				if best_conflict_concealed == Vector3.ZERO:
					best_conflict_concealed = cpos2
			elif best_concealed_fallback == Vector3.ZERO:
				best_concealed_fallback = cpos2

	# A shootable position always outranks a merely concealed one, even when it
	# conflicts with a team-mate's reservation: callers that require shootability
	# discard the whole island on can_shoot == false, so returning the concealed
	# spot first threw away islands that could in fact be fought from.
	if best_conflict_shootable != Vector3.ZERO:
		return { "pos": best_conflict_shootable, "can_shoot": true, "spacing_conflict": true }

	if best_concealed_fallback != Vector3.ZERO:
		return { "pos": best_concealed_fallback, "can_shoot": false, "spacing_conflict": false }

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
# NAV CORE — the one decision ladder every behaviour runs
# ============================================================================
#
# BB, CA and DD used to each own a copy of this function. They agreed on the
# shape and disagreed on about a dozen numbers, so the copies drifted: the
# nearest-threat scan and the reverse-alignment band were character-identical
# between BB and CA, while BB carried a SkillHunt it never called and CA a whole
# island-state block that only called itself.
#
# The ladder now lives here once and reads its numbers off a BotDoctrine. Four
# arms, in order:
#
#   idle     — nothing is known to exist anywhere
#   dark     — enemies exist, none are spotted
#   close    — something is spotted, it is near, and we are detected
#   engaged  — everything else
#
# The first three are fully shared. Only `engaged` still differs per class, and
# only because BB fights down a threat ladder, CA splits on its own detection
# state, and DD is deciding between torpedoes and spotting. Those three are the
# genuine behavioural difference and stay as _select_engaged_skill() overrides.

func doctrine() -> BotDoctrine:
	## Override per class to supply a different row of the table.
	return BotDoctrine.new()

func _doc() -> BotDoctrine:
	if _doctrine == null:
		_doctrine = doctrine()
	return _doctrine

## How close this bot wants to fight, in metres, read off the ship it is driving.
##
## This is what replaced threat-mod. That number asked a human to score every
## hull's appetite for a brawl by hand, in a config file, and then bent the
## threat score by it — so a ship that wanted to fight close did it by being
## bad at being afraid. The appetite is already in the ship, and it is a
## distance rather than a mood: a hull whose secondaries reach most of the way
## to its main-battery range has a second battery worth crossing water for, and
## one whose secondaries are a short-range afterthought does not.
##
## Reading it live means the BUILD counts, which is the part a static number
## could never do. Long Range Secondary Training, Basic Secondary Training and
## the secondary range upgrades all multiply the same `_range` that
## get_max_range() reports, so the same hull specced for secondaries fights
## closer than it does specced for main-battery work, with nothing to configure
## and nothing to keep in sync.
##
## `threat` is this tick's threat score. Above the doctrine's yield point the
## secondaries stop being an argument for closing: a fight already going badly
## does not get better by walking into it to use a shorter gun.
func engagement_range(ship: Ship, threat: float) -> float:
	var d := _doc()
	var gun_range: float = ship.artillery_controller.get_params()._range
	var gun_dist: float = gun_range * d.gun_engage_ratio
	if threat >= d.secondary_yield_threat:
		return gun_dist
	if not is_instance_valid(ship.secondary_controller):
		return gun_dist
	var sec_range: float = ship.secondary_controller.get_max_range()
	if sec_range < gun_range * d.secondary_commit_ratio:
		return gun_dist
	# minf(): the secondaries may only ever pull the ship CLOSER. A hull that
	# already wanted to fight inside its own secondary range has nothing to
	# close for, and this must not push it back out to arm's length.
	return minf(sec_range * d.secondary_engage_ratio, gun_dist)

## Extra params handed to SkillFindCover. CA scales its cover standoff by its
## positioning params; everything else takes the skill's defaults.
func _cover_params() -> Dictionary:
	return {}

## Dispatch a skill by name and record it as active. Returns null when the skill
## declines the situation, so callers can walk a fallback chain.
func _run_skill(skill_name: StringName, ctx: SkillContext, params: Dictionary = {}) -> NavIntent:
	var intent: NavIntent = null
	match skill_name:
		&"Hunt":        intent = _skill_hunt.execute(ctx, params)
		&"Chase":       intent = _skill_chase.execute(ctx, params)
		&"FindCover":   intent = _skill_cover.execute(ctx, params, bool(params.get("prioritize_cover", false)))
		&"Kite":        intent = _skill_kite.execute(ctx, params)
		&"Push":        intent = _skill_push.execute(ctx, params)
		&"Camp":        intent = _skill_camp.execute(ctx, params)
		&"Flank":       intent = _skill_flank.execute(ctx, params)
		&"Spot":        intent = _skill_spot.execute(ctx, params)
		&"Retreat":     intent = _skill_retreat.execute(ctx, params)
		&"SailForward": intent = _intent_sail_forward(ctx.ship)
	if intent != null:
		_active_skill_name = skill_name
	return intent

## Walk a chain of skill names, returning the first that accepts.
func _run_chain(chain: Array[StringName], ctx: SkillContext, params: Dictionary = {}) -> NavIntent:
	for skill_name in chain:
		var intent := _run_skill(skill_name, ctx, params)
		if intent != null:
			return intent
	return null

## Everything the ladder reads about the current moment, gathered once.
func _build_situation(ctx: SkillContext) -> Dictionary:
	var ship := ctx.ship
	var d := _doc()
	var spotted := ctx.server.get_valid_targets(ship.team.team_id)
	var unspotted := ctx.server.get_unspotted_enemies(ship.team.team_id)

	var nearest: Ship = null
	var nearest_dist: float = INF
	for e in spotted:
		if not is_instance_valid(e) or not e.health_controller.is_alive():
			continue
		var dist := ship.global_position.distance_to(e.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = e

	# Distance to the nearest thing carrying real guns. DDs are excluded on
	# purpose: a destroyer close aboard is a torpedo problem, not a reason to
	# back a battleship out of a turn.
	var nearest_threat_dist: float = INF
	for s in unspotted:
		if (s as Ship).ship_class != Ship.ShipClass.DD:
			var dist := ship.global_position.distance_to(unspotted[s])
			if dist < nearest_threat_dist:
				nearest_threat_dist = dist
	for s in spotted:
		if s.ship_class != Ship.ShipClass.DD:
			var dist := ship.global_position.distance_to(s.global_position)
			if dist < nearest_threat_dist:
				nearest_threat_dist = dist

	var hp_ratio: float = ship.health_controller.current_hp / ship.health_controller.max_hp
	var threat: float = get_threat_score(ctx)
	var ra_threshold := d.ra_base
	if _has_active_bb_shooter():
		ra_threshold = d.ra_bb_shooter
		if hp_ratio < d.ra_hurt_hp_ratio:
			ra_threshold = d.ra_bb_shooter_hurt

	return {
		spotted = spotted,
		unspotted = unspotted,
		has_spotted = spotted.size() > 0,
		has_enemies = spotted.size() > 0 or not unspotted.is_empty(),
		nearest = nearest,
		nearest_dist = nearest_dist,
		nearest_threat_dist = nearest_threat_dist,
		hp_ratio = hp_ratio,
		gun_range = ship.artillery_controller.get_params()._range,
		threat = threat,
		# How close this ship wants to be, from its build. Computed once here so
		# every arm that has to decide a distance reads the same answer.
		engagement_range = engagement_range(ship, threat),
		ra_threshold = ra_threshold,
		arm = &"engaged",
		forced = false,
	}

## Common tail for any intent a behaviour returns, whether or not it came out of
## the shared ladder (CVBehavior runs its own tree over the same skills).
##
## A cover destination that was computed but not adopted must not stay reserved:
## the skill claims a spot team-wide on every execute(), including the probes
## made from the camp and kite paths, and a claim nobody is using pushes
## team-mates onto islands further away.
func _finish_intent(intent: NavIntent, previous_skill: StringName) -> NavIntent:
	if _active_skill_name != &"FindCover":
		_skill_cover.release_claim()
		if previous_skill == &"FindCover":
			_skill_cover.reset()
	return intent

## The ladder. Subclasses call this from get_nav_intent() after setting up ctx.
func _nav_core(ctx: SkillContext) -> NavIntent:
	var d := _doc()
	var sit := _build_situation(ctx)
	var prev_skill := _active_skill_name
	var intent: NavIntent = null

	# Cornered: at this much threat the way out is concealment, not gunnery.
	# Whether that is even on offer is _probe_concealment()'s question, so ask it
	# rather than reading is_detected(). It returns false when a spotted enemy
	# has clear line of sight from inside our own detection radius — nothing we
	# stop doing will shake that ship, so the guns keep working even though we
	# are threatened — and true when holding fire would let the bloom decay and
	# drop us. Being detected is therefore no longer a veto: where going dark is
	# still reachable, breaking contact beats one more salvo.
	if sit.threat > 0.95 and _probe_concealment(ctx.server):
		wants_stealth = true
		wants_to_be_concealed = true

	if not sit.has_enemies:
		sit["arm"] = &"idle"
		intent = _run_chain(d.idle_chain, ctx, _cover_params())
	elif not sit.has_spotted and not d.dark_chain.is_empty():
		sit["arm"] = &"dark"
		# Everything has gone dark. Running down the nearest last-known position
		# at flank speed is only reasonable while the picture is quiet; under
		# pressure, get behind an island instead. Cover is asked for with
		# prioritize_cover because with nothing spotted there is nothing to shoot
		# at, so it must not be rejected for being unshootable.
		if d.dark_takes_cover and sit.threat >= get_chase_max_threat():
			var cp := _cover_params()
			cp["prioritize_cover"] = true
			intent = _run_skill(&"FindCover", ctx, cp)
		if intent == null:
			intent = _run_chain(d.dark_chain, ctx)
	else:
		intent = _select_nav_skill(ctx, sit)

	if intent == null and d.universal_sail_forward_fallback:
		intent = _run_skill(&"SailForward", ctx)

	_apply_gun_policy(ctx, sit)
	return _finish_nav(intent, ctx, sit, prev_skill)

## Arms 3 and 4. The close arm is shared; the engaged arm is the hook.
func _select_nav_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	var d := _doc()

	# CA decides on threat before it decides on distance: a cruiser that likes
	# its odds pushes whether or not the enemy is close aboard.
	if d.low_threat_arm_first and sit.threat < d.push_threat:
		sit["arm"] = &"low_threat"
		return _select_low_threat_skill(ctx, sit)

	var close := ctx.ship.is_detected()
	if d.close_arm_range_gated:
		close = close and sit.nearest_threat_dist < float(sit.ra_threshold)
	if not close:
		return _select_engaged_skill(ctx, sit)

	sit["arm"] = &"close"
	var intent: NavIntent = null
	if sit.threat < d.push_threat:
		intent = _run_skill(&"Push", ctx, {"desired_range": sit.engagement_range})
	else:
		# High threat. If concealing cover lies along the way, hide behind it;
		# otherwise kite away with the guns still on the target.
		if d.close_arm_uses_cover:
			intent = _try_cover_on_the_way(ctx, sit.nearest, _skill_cover, _cover_params())
		if intent == null:
			intent = _run_skill(&"Kite", ctx)
	if intent != null:
		_shape_close_intent(intent, ctx, sit)
		if d.close_arm_reverse_align:
			_apply_reverse_alignment(intent, sit.nearest_threat_dist, sit.ra_threshold)
	# Do not let the post-processors steer a committed push or a committed kite.
	if sit.threat < d.force_below or sit.threat >= d.force_above:
		sit["forced"] = true
	return intent

## What to do when the odds look good. Base pushes; CA prefers to run down a
## closer unseen contact rather than cross the map to a distant visible one.
func _select_low_threat_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	return _run_skill(&"Push", ctx, {"desired_range": sit.engagement_range})

## Per-class hook: the engaged arm. Base falls back to pushing.
func _select_engaged_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	return _run_skill(&"Push", ctx, {"desired_range": sit.engagement_range})

## Per-class hook: adjust an intent produced by the close arm. CA uses it to
## hand heading authority to the navigator near terrain.
func _shape_close_intent(_intent: NavIntent, _ctx: SkillContext, _sit: Dictionary) -> void:
	pass

## Per-class hook: concealment and gun suppression policy for this tick.
func _apply_gun_policy(_ctx: SkillContext, _sit: Dictionary) -> void:
	pass

## Common tail. Releases skill state that was claimed but not adopted, then runs
## the heading and anti-clump post-processors.
func _finish_nav(intent: NavIntent, ctx: SkillContext, sit: Dictionary, prev_skill: StringName) -> NavIntent:
	var d := _doc()

	# Camp holds a position lock; switching away has to drop it or the next
	# activation reuses a stale spot.
	if prev_skill == &"Camp" and _active_skill_name != &"Camp":
		_skill_camp.reset()

	intent = _finish_intent(intent, prev_skill)
	if intent == null:
		return null
	if sit.arm != &"engaged" and sit.arm != &"close" and sit.arm != &"low_threat" \
			and not d.post_process_idle_arms:
		return intent

	var forced: bool = bool(sit.forced)

	if d.use_broadside and not forced and _active_skill_name not in d.broadside_exclude:
		intent = _skill_broadside.apply(intent, ctx, d.broadside_params)

	if not forced and _active_skill_name not in d.spread_exclude:
		var sp: Dictionary = d.spread_overrides.get(_active_skill_name, {
			"spread_distance": d.spread_distance,
			"spread_multiplier": d.spread_multiplier,
		})
		intent = _skill_spread.apply(intent, ctx, sp)

	return intent


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

	# What is out there and how sure we are of it. A spotted enemy is where it
	# is seen to be; everything else the enemy owns is at its believed position
	# with a certainty to match (see EnemyPresumption). Two things change here
	# from reading the contact tables directly: a ship nobody has ever seen now
	# counts at all - it still shoots, and a bot that only fears what it can see
	# will happily hold a position that is only safe from what it can see - and
	# an unspotted one is judged on where the team thinks it is rather than on
	# its live position, which is not something this bot is entitled to know.
	var contacts: Array[Dictionary] = []
	for enemy in server.get_valid_targets(_ship.team.team_id):
		contacts.append({ship = enemy, position = enemy.global_position, certainty = 1.0})
	for guess in get_presumed_contacts():
		contacts.append({
			ship = guess.ship,
			position = guess.position,
			certainty = lerpf(PRESUMED_CERTAINTY_MIN, PRESUMED_CERTAINTY_MAX,
				EnemyPresumption.certainty(guess)),
		})
	if contacts.is_empty():
		_threat_score_cache = hp_pressure * 0.3
		_threat_score_frame = frame
		return _threat_score_cache

	var raw_threat: float = 1.0
	var time_remaining: float = server.get_match_time_remaining()
	var t_norm: float = clampf(1.0 - time_remaining / server.MATCH_DURATION, 0.0, 1.0)
	var threat_scale: float = 1.0 - pow(t_norm, 4)

	for contact in contacts:
		var enemy: Ship = contact.ship
		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
			continue
		if enemy.artillery_controller == null:
			continue
		var believed: Vector3 = contact.position
		var dist        = believed.distance_to(_ship.global_position)
		var enemy_range = enemy.artillery_controller.get_params()._range
		var enemy_hp    = enemy.health_controller.current_hp
		# Only count enemies whose guns can plausibly reach us
		if enemy_range <= 0.0 or dist > enemy_range:
			continue
		# 0.0 at range edge → 1.0 at point-blank
		var range_pressure = clampf(0.5 + (0.5 - 0.5 * pow(dist / enemy_range, 2.0)), 0.0, 1.0)
		# Class weight: each ship class has a different threat weight per subclass
		var class_w = get_threat_class_weight(enemy.ship_class)
		# raw_threat *= (1.0 - range_pressure * class_w)
		# Asymptotic: approaches 1 as raw pressure increases, never exceeds it.
		# 1 − e^(−x): x=0 → 0.0, x=1 → 0.63, x=2 → 0.86, x→∞ → 1.0
		var raw_val = enemy_hp / my_hp * range_pressure * class_w
		if !ctx.behavior.active_shooters_at_me.has(enemy):
			raw_val *= 0.5
		raw_val *= threat_scale
		var this_threat = 1.0 - exp(-raw_val)
		# Not knowing exactly where something is makes it less frightening, but
		# on a sliding scale: a contact that went dark seconds ago is nearly as
		# dangerous as one in plain sight, while a ship placed by nothing but the
		# clock and a spawn line is a rumour. This used to be a flat discount on
		# everything unspotted, which made a fresh loss of contact and a
		# ten-minute-old guess equally worrying.
		this_threat *= float(contact.certainty)
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
	# Aim at the position the bot actually knows about: live for a spotted ship,
	# the dead-reckoned last-known position for one that has gone dark.
	var contact := get_contact_solution(target)
	if not is_engageable_contact(contact):
		return
	var adjusted_target_pos: Vector3 = contact.position + contact.basis * target_aim_offset(target)
	if contact.position.distance_to(_ship.global_position) > _ship.artillery_controller.get_params()._range:
		return

	#if not can_fire_guns():
		#_ship.artillery_controller.set_aim_input(adjusted_target_pos)
		#return

	# Concealment probe: aim turrets but hold fire to let bloom decay
	if wants_to_be_concealed:
		_ship.artillery_controller.set_aim_input(adjusted_target_pos)
		_ship.secondary_controller.enabled = false
		return
	_ship.secondary_controller.enabled = true

	# Arc-aware, and wrong in whatever way this bot's aptitude is wrong.
	var target_lead = aim_lead_point(target, contact, adjusted_target_pos)

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
# AVIATION (shared by all ship classes; driven directly via the Squadron API,
# never the player RPC path, whose shell_indices multi-select is empty for bots)
# ============================================================================
var _aviation_spot_issued: Dictionary = {}  # int (squadron index) -> Vector2
const AVIATION_SPOT_REISSUE_DIST: float = 500.0
var _aviation_shadow_issued: Dictionary = {}  # int (squadron index) -> Vector2
const AVIATION_SHADOW_REISSUE_DIST: float = 500.0
var _aviation_strike_target: Dictionary = {}  # int (squadron index) -> Ship it was sent after

# Ordnance is only committed against a contact somebody is actually holding: a
# live spot, or a last-known position still being refreshed. LKPs stop refreshing
# the moment nothing can see the ship, so a contact older than this is one that
# has been gone a while, and a run against it puts ordnance in the water.
const LKP_STRIKE_MAX_AGE: float = 40.0
# A run already under way is given a little more rope before being broken off:
# LKPs refresh on GameServer.HYDRO_LKP_INTERVAL, which is itself 4s, so testing a
# run against a strict 4s would have it flicker against its own refresh cadence.
const LKP_STRIKE_ABORT_AGE: float = 6.0

## Whether a squadron may be sent in to drop on this contact at all.
func _contact_is_strikeable(sol: Dictionary) -> bool:
	if not sol.get("valid", false):
		return false
	return not sol.is_lkp or sol.age <= LKP_STRIKE_MAX_AGE

## Whether a run already committed should be broken off - the contact has gone
## cold with the squadron still inbound.
func _contact_strike_lost(sol: Dictionary) -> bool:
	if not sol.get("valid", false):
		return true
	return sol.is_lkp and sol.age > LKP_STRIKE_ABORT_AGE

## Same question for the run squadron `index` is actually flying. The contact
## judged is the ship it was sent after, not whatever the bot happens to be
## looking at this tick - the two diverge the moment a fresher enemy turns up
## nearby, and a squadron committed against a ship that has since gone dark would
## otherwise ride that fresh contact's coat-tails all the way onto empty water.
func _strike_contact_lost(index: int, current_ship: Ship, current_sol: Dictionary) -> bool:
	var committed_to = _aviation_strike_target.get(index, null)
	if committed_to == null or committed_to == current_ship:
		return _contact_strike_lost(current_sol)
	if not is_instance_valid(committed_to) or not committed_to.is_alive():
		return true
	return _contact_strike_lost(get_contact_solution(committed_to))

## The contact a squadron is actually running in on: the one it was released
## against, not whatever the bot happens to be looking at this tick. Re-aiming a
## run at a ship somebody has just spotted is how a strike ends up attacking
## nothing at all - it swings onto the new contact, that contact goes dark, the
## run breaks off, and the squadron dissolves back into a rally it should never
## have been able to return to. Returns {ship, sol}; a null ship means the
## committed contact is gone for good.
func _committed_contact(index: int, current_ship: Ship, current_sol: Dictionary) -> Dictionary:
	var committed = _aviation_strike_target.get(index, null)
	if committed == null or committed == current_ship:
		return {ship = current_ship, sol = current_sol}
	if not is_instance_valid(committed) or not committed.is_alive():
		return {ship = null, sol = {valid = false}}
	return {ship = committed, sol = get_contact_solution(committed)}

## Whether terrain between `point` and this carrier breaks a squadron's run-in,
## so ordnance cannot be put there at all (see DropShadow). Bots are held to the
## same rule the player is - AviationController refuses the order either way, and
## a squadron sent at a mark in the dead zone flies the whole sortie for nothing.
func _drop_blocked(point: Vector2) -> bool:
	return DropShadow.is_blocked(point,
		Vector2(_ship.global_position.x, _ship.global_position.z))

## Points a squadron's run at `contact`: approach side, lead, drop point. Called
## every tick until the approach commits, so the aim tracks the contact right up
## to the point the run freezes. Returns false without ordering anything when the
## lead has walked the drop point into a dead zone - the contact has got itself
## behind cover, and the caller has to find the squadron something else to do.
func _aim_run(index: int, squad: Squadron, contact: Ship, contact_sol: Dictionary) -> bool:
	var pos: Vector3 = contact_sol.position if contact_sol.get("valid", false) else contact.global_position
	var at := Vector2(pos.x, pos.z)
	var dir := _attack_direction(index, squad, contact, at, contact_sol)
	var drop := _lead_attack_point(squad, contact, at, dir, contact_sol)
	if _drop_blocked(drop):
		return false
	squad.set_attack(drop, dir)
	return true

## The best contact for a squadron that has just lost the one it was sent after:
## strikeable right now, inside the reach it is tasked on, and nearest to where
## the squadron already IS rather than to the carrier - a replacement behind it
## costs the whole transit over again. Returns {ship, sol}, empty if there is
## nothing worth turning onto.
func _replacement_contact(squad: Squadron, server: GameServer, lost: Ship) -> Dictionary:
	if server == null or _ship.team == null:
		return {}
	var from := Vector2(squad.node.global_position.x, squad.node.global_position.z)
	var carrier := Vector2(_ship.global_position.x, _ship.global_position.z)
	var reach := _squadron_operating_radius(squad) * AVIATION_RANGE_HYSTERESIS
	# Untyped on purpose: the two sources are a typed array and a dictionary's
	# keys, and a typed array will not take the second.
	var candidates: Array = []
	candidates.append_array(server.get_valid_targets(_ship.team.team_id))
	candidates.append_array(server.get_unspotted_enemies(_ship.team.team_id).keys())
	var best: Dictionary = {}
	var best_dist: float = INF
	for enemy: Ship in candidates:
		if enemy == lost or not is_instance_valid(enemy) or not enemy.is_alive():
			continue
		if not _is_hostile(enemy):
			continue
		var enemy_sol := get_contact_solution(enemy)
		if not _contact_is_strikeable(enemy_sol):
			continue
		var enemy_pos: Vector3 = enemy_sol.position
		var at := Vector2(enemy_pos.x, enemy_pos.z)
		if carrier.distance_to(at) > reach:
			continue
		if _drop_blocked(at):
			continue
		var d := from.distance_to(at)
		if d < best_dist:
			best_dist = d
			best = {ship = enemy, sol = enemy_sol}
	return best

## What a squadron does when the contact it was committed against is gone. It
## does not fly home to start over - that spends the transit twice and a rearm on
## top - it turns onto the nearest thing it can still reach from where it is. Only
## with nothing left to strike does it hold, out of AA, ready for the next
## contact to firm up.
func _retarget_or_hold(index: int, squad: Squadron, server: GameServer, lost: Ship,
		hold_point: Vector2) -> void:
	var swap := _replacement_contact(squad, server, lost)
	if swap.is_empty():
		_shadow_contact(index, squad, hold_point)
		return
	# A new contact means a new approach: which side it was going to attack the
	# old one from says nothing about this one.
	_aviation_attack_dir.erase(index)
	_aviation_shadow_issued.erase(index)
	if not _aim_run(index, squad, swap.ship, swap.sol):
		_shadow_contact(index, squad, hold_point)
		return
	_aviation_strike_target[index] = swap.ship

## Squadrons currently part of a forming strike group, kept between ticks purely
## so the reach test below can be hysteretic - see where it is read.
var _aviation_in_group: Dictionary = {}  # int (squadron index) -> true
const AVIATION_RANGE_HYSTERESIS: float = 1.1

## Sends a squadron to loiter over a contact it is not allowed to strike, so it is
## already overhead the moment that contact firms up again. Routing it by waypoint
## rather than attack point is the whole point: set_waypoint() clears attack_point,
## which drops the formation out of its attack run, and a run that reaches its mark
## drops ordnance whether or not anything is still there to drop it on.
func _shadow_contact(index: int, squad: Squadron, point: Vector2) -> void:
	if squad.returning or squad.attack_fired:
		return
	_aviation_strike_target.erase(index)
	# Loitering is what a squadron does when it has nothing to strike yet. Below
	# the reserve there is no longer time for that to turn into a run, so it goes
	# home instead and starts its rearm a cycle sooner.
	if squad.active and squad.fuel_remaining <= AVIATION_RTB_FUEL_RESERVE:
		_aviation_shadow_issued.erase(index)
		squad.abort_sortie()
		return
	# Clear of every AA envelope known or remembered. Loitering used to mean
	# orbiting the contact itself, which was free when a shot-down plane was
	# back on the next launch; now it is a squadron parked inside an AA envelope
	# for a whole sortie, losing a plane every few seconds and a build time with
	# each one.
	var station := _clamp_to_squadron_range(squad, _clear_of_threats(point))
	# Always issue when there is a run to break off; otherwise only when the
	# loiter point has actually moved, so the squadron is left to orbit in peace
	# instead of being handed the same waypoint every tick.
	if squad.attack_point == null:
		var prev = _aviation_shadow_issued.get(index, null)
		if prev != null and (station - prev).length() < AVIATION_SHADOW_REISSUE_DIST:
			return
	squad.set_waypoint(station, false)
	_aviation_shadow_issued[index] = station

## Pulls a loiter station back inside the squadron's reach of the carrier.
## Squadron._process_waypoints() clamps the waypoint itself, but set_waypoint()
## also stores the raw point as idle_pos, and idle_pos is what the squadron
## orbits once that waypoint is consumed - so handing it an out-of-reach point
## parks the orbit outside the tether. Clamping here keeps both in agreement.
func _clamp_to_squadron_range(squad: Squadron, point: Vector2) -> Vector2:
	var carrier := Vector2(_ship.global_position.x, _ship.global_position.z)
	var offset := point - carrier
	var reach := _squadron_operating_radius(squad)
	if reach <= 0.0 or offset.length_squared() <= reach * reach:
		return point
	return carrier + offset.normalized() * reach

func _squadron_is_spotter(squad: Squadron) -> bool:
	return squad.aircraft[0] is SpottingAircraft

func _squadron_range(squad: Squadron) -> float:
	return (squad.params.p() as AircraftParams)._range


# ── air group economics ─────────────────────────────────────────────────────
# Everything in this block exists because sorties and losses now cost real time.
# A lost plane is AircraftParams.plane_regen_time to replace and they rebuild one
# at a time; nothing leaves the deck until AviationParams.min_takeoff_interval
# has passed since the last launch; and a sortie ends when fuel_time runs out
# whether or not it achieved anything.

# Share of a squadron's endurance it may spend flying out. The rest has to cover
# forming up, the approach and the drop. The flight home is free - fuel only
# counts until the squadron turns for base (see Squadron.update_flight).
const AVIATION_TRANSIT_FUEL_FRACTION: float = 0.5
# A squadron under this share of its roster stays on deck: a two-plane strike
# achieves little, and every plane it loses is another full build time.
const AVIATION_MIN_LAUNCH_STRENGTH: float = 0.6
# An airborne squadron that has lost this share of what it launched with breaks
# off instead of pressing on. The run's value is already gone; the survivors'
# build time has not been spent yet.
const AVIATION_ABORT_STRENGTH: float = 0.5
# A squadron with nothing left to do and less fuel than this goes home rather
# than orbiting - it starts rearming sooner and stops standing in AA fire.
const AVIATION_RTB_FUEL_RESERVE: float = 25.0
# Fuel held back for the run itself when deciding how long a group may keep
# forming up: the approach, the drop, and being wrong about the target's course.
const AVIATION_STRIKE_FUEL_RESERVE: float = 20.0
# How long a strike group will hold for a squadron still on the deck. Longer than
# a takeoff interval so the next launch is always worth waiting for, far short of
# a rearm (which is a whole cycle away) or a rebuild.
const AVIATION_JOIN_WAIT_MAX: float = 25.0
# Clearance kept between an orbiting squadron and the edge of the AA envelope.
const AVIATION_AA_MARGIN: float = 500.0

# Furthest from the carrier a squadron can usefully be tasked: its tether, or as
# far as it can fly on its transit share of a tank, whichever binds first. The
# fuel bound is what usually binds for spotters - an 18km reach at 200 m/s is 90s
# of a 120s tank, so a station at the tether edge is one the squadron arrives at
# on fumes and turns straight around from.
func _squadron_operating_radius(squad: Squadron) -> float:
	var p := squad.params.p() as AircraftParams
	return minf(p._range, p.speed * p.fuel_time * AVIATION_TRANSIT_FUEL_FRACTION)

# Seconds from now until this squadron's ordnance is actually in the water, as
# opposed to how long it takes to get near the target. The difference matters,
# and it is not small: a run is flown to an entry point attack_descent_radius
# out along the attack direction and only then down the run-in, so a beam-on
# attack ordered from a rally that sits off the beam flies a dog-leg rather than
# a straight line. Torpedo squadrons then drop short of the mark and the fish
# swim the rest (process_attack_point), and the swim counts too.
#
# This is the figure the release deadline is measured against - see
# _run_strike_group. A group that waits for a broadside using a straight-line
# ETA is a group that runs its tanks dry on the dog-leg it forgot about, turns
# for home with its ordnance still aboard, and pays a full cycle for nothing.
func _strike_eta(squad: Squadron, point: Vector2, dir: Vector2) -> float:
	var speed := _squadron_speed(squad)
	if speed <= 0.0:
		return INF
	var from := Vector2(_ship.global_position.x, _ship.global_position.z)
	if squad.active:
		from = Vector2(squad.node.global_position.x, squad.node.global_position.z)
	var run := dir
	if run.length_squared() < 0.0001:
		run = Vector2(0.0, 1.0)
	else:
		run = run.normalized()
	var p := squad.params.p() as AircraftParams
	var plane: Aircraft = squad.aircraft[0]
	var drop := plane.process_attack_point(point, run)
	var entry := drop - run * (p.attack_descent_radius as float)
	var eta: float = (from.distance_to(entry) + entry.distance_to(drop)) / speed
	# Swinging from the transit heading onto the run-in is flown, not teleported:
	# at the turning radius the squadron actually has, a 90-degree hook onto the
	# beam is a real slice of the tank.
	var approach := entry - from
	if approach.length_squared() > 1.0:
		eta += p.turning_radius * absf(approach.normalized().angle_to(run)) / speed
	return eta + plane.ordnance_flight_time()

# Share of its roster the squadron has on strength right now.
func _squadron_strength(av: AviationController, index: int, squad: Squadron) -> float:
	if squad.aircraft.is_empty():
		return 0.0
	return float(av.get_alive_count(index)) / float(squad.aircraft.size())

# Planes the squadron actually took off with this sortie, so attrition is judged
# against what was committed rather than against a roster it never had.
var _aviation_launch_strength: Dictionary = {}  # int (squadron index) -> int

# True once a squadron has lost enough of what it launched with that pressing on
# costs more replacement time than the run is still worth.
func _sortie_gutted(av: AviationController, index: int) -> bool:
	var launched: int = _aviation_launch_strength.get(index, 0)
	if launched <= 1:
		return false
	return float(av.get_alive_count(index)) < float(launched) * AVIATION_ABORT_STRENGTH

# Per-squadron tasking state, dropped when a squadron stops being available for
# whatever the air group is currently doing.
func _forget_squadron(index: int) -> void:
	_aviation_in_group.erase(index)
	_aviation_attack_dir.erase(index)
	_aviation_shadow_issued.erase(index)
	_aviation_strike_target.erase(index)

# Longest AA reach among the enemies we know of, live contacts and last-known
# positions alike. This is the radius the whole air group is planned around:
# inside it planes are under fire every second, outside it they are untouchable.
func _enemy_aa_reach(server: GameServer) -> float:
	var reach: float = 0.0
	if server == null or _ship.team == null:
		return reach
	for enemy in server.get_valid_targets(_ship.team.team_id):
		reach = maxf(reach, _ship_aa_reach(enemy))
	# Ships nobody is holding shoot at aircraft too, and what they are armed
	# with is public. Only their POSITION is guesswork (see _aviation_threats).
	for guess in get_presumed_contacts():
		reach = maxf(reach, _ship_aa_reach(guess.ship))
	return reach

static func _ship_aa_reach(other: Ship) -> float:
	if other == null or not is_instance_valid(other) or not other.is_alive():
		return 0.0
	if other.aaa_controller == null or other.aaa_controller.get_params() == null:
		return 0.0
	return other.aaa_controller.get_params()._range

# Damage that same ship does inside that reach, per second. Reach and dps are
# read separately and per-ship rather than rolled into one "threat" number,
# because they answer different questions: reach says where the air group may
# not go, dps says which of two targets it costs less to attack. A short-ranged
# ship with heavy mounts and a long-ranged one with light mounts are opposite
# answers to those two questions, and ships will carry different mounts.
static func _ship_aa_dps(other: Ship) -> float:
	if other == null or not is_instance_valid(other) or not other.is_alive():
		return 0.0
	if other.aaa_controller == null or other.aaa_controller.get_params() == null:
		return 0.0
	return other.aaa_controller.get_params().dps


# ── AA exposure ─────────────────────────────────────────────────────────────
# What attacking a given ship actually costs, in aircraft. AA fires on whatever
# is inside its envelope (see AAAController), so the price of a run is the time
# the squadron spends inside every envelope that covers the approach, times what
# each of those ships does per second. That is a number in hit points, which is
# the only form in which "this target is defended and that one is not" can be
# compared against "this target is worth more than that one".
#
# The whole final leg is priced, not just the drop point: a squadron flies in
# along the attack direction from attack_descent_radius out and overflies the
# mark afterwards, and most of the fire it takes is on those legs rather than at
# the instant of release.

## Length of `segment` (from -> to) that lies inside the circle (centre, radius).
## Standard ray/circle clip, kept explicit because it runs per threat per
## candidate target every tick.
static func _segment_in_circle(from: Vector2, to: Vector2, centre: Vector2, radius: float) -> float:
	var d := to - from
	var len_sq := d.length_squared()
	if len_sq < 0.0001 or radius <= 0.0:
		return 0.0
	var f := from - centre
	var b := 2.0 * f.dot(d)
	var c := f.length_squared() - radius * radius
	var disc := b * b - 4.0 * len_sq * c
	if disc <= 0.0:
		return 0.0
	var root := sqrt(disc)
	var t0 := clampf((-b - root) / (2.0 * len_sq), 0.0, 1.0)
	var t1 := clampf((-b + root) / (2.0 * len_sq), 0.0, 1.0)
	if t1 <= t0:
		return 0.0
	return (t1 - t0) * sqrt(len_sq)

## Hit points a squadron expects to lose flying a run at `point` along `dir`,
## given the threat picture built this tick.
##
## Three legs are priced, because the fire is taken on all three and mostly not
## at the moment of release: the approach from the carrier's side in to the
## entry point, the run-in itself, and the overfly afterwards. Modelling the
## approach as a straight leg off the carrier rather than off the rally is
## deliberate - the rally is chosen to be clear of everything, so from there on
## the whole point is that the squadron has to cross whatever lies between. It
## also makes the figure sensitive to which SIDE the target is attacked from: a
## run threaded in past an escort is charged for that escort and the same run
## from the open flank is not.
##
## Threats include the presumed positions of ships nobody is holding and the
## remembered hot spots, exactly as the rally does - a target ringed by escorts
## that have never been spotted is not a soft one.
func _aa_exposure(point: Vector2, dir: Vector2, squad: Squadron) -> float:
	var threats := _aviation_threat_cache
	if threats.is_empty():
		return 0.0
	var speed := _squadron_speed(squad)
	if speed <= 0.0:
		return 0.0
	var run := dir
	if run.length_squared() < 0.0001:
		return 0.0
	run = run.normalized()
	var p := squad.params.p() as AircraftParams
	var carrier := Vector2(_ship.global_position.x, _ship.global_position.z)
	var entry := point - run * (p.attack_descent_radius as float)
	var egress := point + run * (p.attack_descent_radius as float)
	var planes: float = maxf(float(squad.alive_count()), 1.0)
	var damage: float = 0.0
	for threat in threats:
		var dps: float = threat.get("dps", 0.0)
		if dps <= 0.0:
			continue
		# The envelope itself, not the margin the rally keeps clear of it: this
		# is a run, and a run is meant to go inside. AVIATION_AA_MARGIN is
		# standoff policy for loitering, not where the guns actually start.
		var radius: float = maxf(float(threat.radius) - AVIATION_AA_MARGIN, 0.0)
		var at: Vector2 = threat.position
		var inside := _segment_in_circle(carrier, entry, at, radius) \
				+ _segment_in_circle(entry, point, at, radius) \
				+ _segment_in_circle(point, egress, at, radius)
		if inside <= 0.0:
			continue
		# AAAController fires once a second at ONE plane in range, so a ship's
		# dps is shared across whatever the squadron brings - the same reason
		# the group forms up before going in (see _run_strike_group).
		damage += dps * (inside / speed) / planes
	return damage

## The same figure as a share of one aircraft's hit points, so it can be
## compared across squadrons carrying different airframes.
func _aa_exposure_ratio(point: Vector2, dir: Vector2, squad: Squadron) -> float:
	var p := squad.params.p() as AircraftParams
	if p.hp <= 0.0:
		return 0.0
	return _aa_exposure(point, dir, squad) / p.hp


# ── broadside presentation ──────────────────────────────────────────────────
# A run is aimed along the target's beam so the abreast formation spreads across
# the ship's length - torpedoes run over the broadside, bombs fall along the
# keel (see _attack_direction). How much of that length the run actually crosses
# is the sine of the angle between the run and the target's heading: beam-on is
# the whole ship, bow-on is its width. That number is a direct multiplier on
# what the drop is worth, so it belongs in target selection and in the decision
# to release, not only in the aiming.
#
# It is not free to choose, either: set_attack() clamps the run into
# MAX_ATTACK_ANGLE around the carrier-to-target line, so a beam-on drop is only
# available when the carrier is already off the target's beam. Which is why this
# is measured through the same clamp rather than assuming the beam is reachable.

## Run the squadron would actually fly against the contact believed to be at
## `point`, clamped into the approach cone. Side is chosen the way
## _attack_direction chooses it - the beam nearer the approach, so the formation
## never has to turn around.
func _beam_run_direction(point: Vector2, sol: Dictionary) -> Vector2:
	var carrier := Vector2(_ship.global_position.x, _ship.global_position.z)
	var bearing := point - carrier
	if bearing.length_squared() < 0.0001:
		return Vector2(0.0, 1.0)
	bearing = bearing.normalized()
	# With no solution there is no heading to lie across, so the run is simply
	# the direct approach - which is also what the cone would clamp it to.
	if not sol.get("valid", false):
		return bearing
	var basis: Basis = sol.get("basis", Basis.IDENTITY)
	var right := Vector2(basis.x.x, basis.x.z)
	if right.length_squared() < 0.0001:
		return bearing
	right = right.normalized()
	var beam: Vector2 = right if bearing.dot(right) >= 0.0 else -right
	return Squadron.clamp_attack_direction(beam, point, carrier)

## Share of the target's length the achievable run crosses: 1.0 fully beam-on,
## falling to 0 bow-on. Contacts with no usable solution score 0.5 - unknown
## heading, so neither rewarded nor waited for.
func _broadside_quality(point: Vector2, sol: Dictionary) -> float:
	if not sol.get("valid", false):
		return 0.5
	var basis: Basis = sol.get("basis", Basis.IDENTITY)
	var forward := Vector2(-basis.z.x, -basis.z.z)
	if forward.length_squared() < 0.0001:
		return 0.5
	forward = forward.normalized()
	var dir := _beam_run_direction(point, sol)
	if dir.length_squared() < 0.0001:
		return 0.5
	return clampf(absf(dir.normalized().cross(forward)), 0.0, 1.0)

# Where a strike group forms up: on the carrier's side of the contact and clear
# of the AA envelope, so squadrons waiting for the rest of the group can orbit
# without being shot at. Derived rather than tuned - it moves with the contact and
# with whatever AA the enemy actually brings. Never placed further out than the
# carrier itself, which would have squadrons forming up behind their own deck.
const AVIATION_RALLY_MARGIN: float = 1500.0
const AVIATION_RALLY_ARRIVE_DIST: float = 1500.0

func _strike_rally_point(point: Vector2, aa_reach: float) -> Vector2:
	var carrier := Vector2(_ship.global_position.x, _ship.global_position.z)
	var away := carrier - point
	if away.length_squared() < 1.0:
		return carrier
	return point + away.normalized() * minf(aa_reach + AVIATION_RALLY_MARGIN, away.length())


# ── rally threat memory ─────────────────────────────────────────────────────
# A rally derived from the aimed contact alone is not safe and is not stable.
# Not safe, because any other ship can be sitting on it - and a ship whose AA
# outranges its own air-detection radius shoots squadrons that never see it, so
# nothing about it ever reaches the contact tables. Not stable, because the
# contact the rally is measured from flips the moment such a ship is spotted:
# the rally is recomputed against a much nearer ship and pulls back, the
# squadron leaves, the ship goes dark again, the rally springs forward onto the
# same spot, and the group cycles in and out of the same AA envelope.
#
# So the rally is cleared of every threat that is known OR remembered, and,
# while a group is forming, is allowed to be pulled back but never pushed
# forward again - the cycle cannot start if the return leg does not exist.

## How long a place where planes got hurt keeps being avoided. Long, because the
## ship that did it is by assumption one nothing can see: there will be no second
## piece of evidence until another squadron flies into it.
const AVIATION_HOT_SPOT_MEMORY_MS: int = 120000
## Radius kept clear around one. Sized to cover a typical AA envelope from
## wherever inside it the damage happened to be noticed.
const AVIATION_HOT_SPOT_RADIUS: float = 4000.0
## Passes of threat separation. The rally usually clears everything on the
## first; the rest are for the case where backing away from one envelope walks
## it into another.
const AVIATION_RALLY_CLEAR_PASSES: int = 3

var _aviation_hot_spots: Array[Dictionary] = []  # {position: Vector2, until_ms: int}
var _aviation_squadron_hp: Dictionary = {}       # int (squadron index) -> float, last total
# Distance from the carrier the rally has been pulled back to for the group
# currently forming up. Reset once that group goes in or disperses.
var _rally_hold_dist: float = INF

## Watches a squadron's total health for damage taken while it is NOT on an
## attack run. Over the target, being shot at is the point; anywhere else it is
## the only evidence that something is out there shooting, and it arrives whether
## or not the shooter was ever detected.
func _sample_loiter_damage(index: int, squad: Squadron) -> void:
	var total: float = 0.0
	for plane in squad.aircraft:
		if not plane.dead:
			total += plane.hp
	var previous: float = _aviation_squadron_hp.get(index, total)
	_aviation_squadron_hp[index] = total
	if not squad.active or squad.returning or squad.attack_point != null:
		return
	if total >= previous - 0.01:
		return
	_mark_hot_spot(Vector2(squad.node.global_position.x, squad.node.global_position.z))

## Records where planes are being hurt, merging into a nearby record rather than
## accumulating one per tick - and letting that record drift toward the new
## damage, so it follows the ship that is doing it.
func _mark_hot_spot(pos: Vector2) -> void:
	var now: int = Time.get_ticks_msec()
	for spot in _aviation_hot_spots:
		var at: Vector2 = spot.position
		if at.distance_to(pos) < AVIATION_HOT_SPOT_RADIUS:
			spot.position = at.lerp(pos, 0.25)
			spot.until_ms = now + AVIATION_HOT_SPOT_MEMORY_MS
			return
	_aviation_hot_spots.append({position = pos, until_ms = now + AVIATION_HOT_SPOT_MEMORY_MS})

func _live_hot_spots() -> Array[Dictionary]:
	var now: int = Time.get_ticks_msec()
	var live: Array[Dictionary] = []
	for spot in _aviation_hot_spots:
		if int(spot.until_ms) > now:
			live.append(spot)
	_aviation_hot_spots = live
	return live

## Every position the air group should keep its distance from, as
## {position, radius}: enemies at their believed position out to their AA reach,
## and remembered hot spots. Believed covers everything - held, last seen a while
## ago, or never seen at all - because the ship this exists for is precisely the
## one nobody has laid eyes on.
func _aviation_threats(server: GameServer) -> Array[Dictionary]:
	var threats: Array[Dictionary] = []
	# Heaviest AA known anywhere, used to price the hot spots below.
	var worst_dps: float = 0.0
	if server != null and _ship.team != null:
		for enemy in server.get_valid_targets(_ship.team.team_id):
			var reach := _ship_aa_reach(enemy)
			worst_dps = maxf(worst_dps, _ship_aa_dps(enemy))
			if reach > 0.0:
				threats.append({
					position = Vector2(enemy.global_position.x, enemy.global_position.z),
					radius = reach + AVIATION_AA_MARGIN,
					dps = _ship_aa_dps(enemy)})
		# Everything not currently held, at wherever it is believed to be: a
		# last-known position while that is what there is, and otherwise the
		# presumption built from the spawns and the clock (see
		# EnemyPresumption). Without this the air group plans its rally around
		# the handful of ships that happen to be visible and forms up on top of
		# the rest of the fleet.
		for guess in get_presumed_contacts():
			if float(guess.radius) > PRESUMED_THREAT_MAX_RADIUS:
				continue
			var reach := _ship_aa_reach(guess.ship)
			worst_dps = maxf(worst_dps, _ship_aa_dps(guess.ship))
			if reach <= 0.0:
				continue
			var at: Vector3 = guess.position
			threats.append({
				position = Vector2(at.x, at.z),
				radius = reach + AVIATION_AA_MARGIN,
				dps = _ship_aa_dps(guess.ship)})
	# A hot spot is a place planes got hurt by something nobody has ever seen,
	# so there is no ship to read a dps off. Priced at the heaviest AA on the
	# board: the unknown is the one thing that could be anything, and the cost of
	# under-rating it is a squadron routed back through whatever made the mark.
	for spot in _live_hot_spots():
		threats.append({
			position = spot.position,
			radius = AVIATION_HOT_SPOT_RADIUS,
			dps = worst_dps})
	return threats

## This tick's threat picture, built once in aviation_engage() and read by every
## station the air group is sent to.
var _aviation_threat_cache: Array[Dictionary] = []

## The AA reach that actually bears on `point`: the widest envelope among the
## threats that reach it, or come within a rally margin of doing so.
##
## _enemy_aa_reach() answers the same question with the maximum over the whole
## board, which is only the same answer while every ship carries the same mounts.
## Once they do not, the single longest-ranged ship on the map dictates the
## stand-off of every squadron everywhere, including groups forming up against a
## contact twenty kilometres away from it - the rally is shoved out, transit
## grows, and the extra distance buys nothing because the ship that justified it
## was never going to reach them.
##
## Falls back to `fallback` when nothing is known to bear on the point at all,
## so a station worked out against a contact nobody is holding is still placed
## with the board-wide figure rather than with none.
func _aa_reach_near(point: Vector2, fallback: float) -> float:
	var reach: float = 0.0
	for threat in _aviation_threat_cache:
		var radius: float = maxf(float(threat.radius) - AVIATION_AA_MARGIN, 0.0)
		if radius <= 0.0:
			continue
		var at: Vector2 = threat.position
		if at.distance_to(point) - radius > AVIATION_RALLY_MARGIN:
			continue
		reach = maxf(reach, radius)
	return reach if reach > 0.0 else fallback

## Pushes a point out of every threat envelope it sits inside, straight away from
## whatever it is too close to.
func _clear_of_threats(point: Vector2) -> Vector2:
	var threats := _aviation_threat_cache
	if threats.is_empty():
		return point
	var out := point
	for _pass in range(AVIATION_RALLY_CLEAR_PASSES):
		var moved := false
		for threat in threats:
			var at: Vector2 = threat.position
			var radius: float = threat.radius
			var offset := out - at
			var d := offset.length()
			if d >= radius:
				continue
			out = at + (offset / d if d > 0.001 else Vector2(0.0, 1.0)) * radius
			moved = true
		if not moved:
			break
	return out

## Caps how far forward the rally may sit while a group is forming up. The
## bearing stays live so the group still waits on the right side of the carrier,
## but the distance only ever ratchets inward - a rally that was pulled back
## because squadrons were being shot at there does not drift out again the moment
## whatever shot them stops being visible.
func _hold_rally(rally: Vector2) -> Vector2:
	var carrier := Vector2(_ship.global_position.x, _ship.global_position.z)
	var offset := rally - carrier
	var d := offset.length()
	if d <= _rally_hold_dist:
		_rally_hold_dist = d
		return rally
	if d < 0.001:
		return carrier
	return carrier + offset / d * _rally_hold_dist

# Where a spotter sits to watch a contact. Both bounds are measured on the edges
# of the orbit rather than its centre, since the squadron circles the station at
# circle_range: far enough out that the near edge clears the AA envelope, close
# enough in that the far edge still holds the ship inside `detect` - the range at
# which this squadron actually sees THIS ship (see _air_detect_radius), which is
# usually the ship's own air_radius rather than anything the squadron brings.
# When both bounds cannot be met the spotting one wins and the squadron sits in
# the AA: a spotter that cannot see the ship is doing nothing at all, and holding
# a contact is worth being shot at for. It still stands as far off as it can.
func _spot_station(squad: Squadron, contact: Vector2, aa_reach: float, detect: float) -> Vector2:
	var p := squad.params.p() as AircraftParams
	var nearest_safe: float = aa_reach + p.circle_range + AVIATION_AA_MARGIN
	var furthest_seen: float = detect - p.circle_range
	var standoff: float = maxf(minf(nearest_safe, furthest_seen), 0.0)
	var carrier := Vector2(_ship.global_position.x, _ship.global_position.z)
	var away := carrier - contact
	if away.length_squared() < 1.0:
		return contact
	return contact + away.normalized() * minf(standoff, away.length())


# ── deck scheduling ─────────────────────────────────────────────────────────
# Only one squadron leaves the deck per AviationParams.min_takeoff_interval, and
# AviationController.ensure_launched() simply refuses when the slot is not free -
# so left alone, array order decides who flies. Squadrons ask for the slot
# instead and the best request each tick is the one actually put up.
const LAUNCH_PRIORITY_STRIKE: float = 100.0
const LAUNCH_PRIORITY_SPOT: float = 50.0
# A strike sent after a contact nobody is holding, to be overhead when it is
# found. Bottom of the pile: it is worth doing with a slot nothing else wants,
# and never worth taking one off a squadron that has something to drop on now or
# off the spotter that is going to give it something to drop on.
const LAUNCH_PRIORITY_SEARCH: float = 25.0
# A spotter outranks a strike squadron when there is nothing to strike: the air
# group cannot work a contact nobody is holding, and the deck slot spent finding
# one buys every squadron behind it a target.
const LAUNCH_PRIORITY_BLIND_SPOT: float = 200.0

var _launch_request_index: int = -1
var _launch_request_priority: float = -INF

func _request_launch(index: int, priority: float) -> void:
	if priority <= _launch_request_priority:
		return
	_launch_request_priority = priority
	_launch_request_index = index

func _grant_launch(av: AviationController) -> void:
	if _launch_request_index >= 0:
		av.ensure_launched(_launch_request_index)
	_launch_request_index = -1
	_launch_request_priority = -INF

# beyond this multiple of attack_descent_radius the drop point is still
# re-aimed each tick to track a moving target; inside it the squadron is
# committed to its final run and the drop point freezes - a committed squadron
# can be dodged, which is deliberate, so the aim is never refreshed past here
const ATTACK_COMMIT_RADIUS_MULT: float = 1.2

# Squadron may (re)take an attack order while on deck, airborne uncommitted,
# or mid-approach - until it enters the commit radius around its processed
# attack point (the point update_flight() actually flies to, which for
# torpedo runs is offset behind the ordered point).
func _squadron_should_take_attack(squad: Squadron, p: AircraftParams) -> bool:
	if squad.returning or squad.holding_attack:
		return false
	if squad.attack_point == null:
		return true
	var pos = Vector2(squad.node.global_position.x, squad.node.global_position.z)
	var processed: Vector2 = squad.aircraft[0].process_attack_point(squad.attack_point, squad.attack_direction)
	return pos.distance_to(processed) > ATTACK_COMMIT_RADIUS_MULT * p.attack_descent_radius

func _squadron_speed(squad: Squadron) -> float:
	return (squad.params.p() as AircraftParams).speed

# Furthest ahead of the last actual observation a contact's motion is worth
# extrapolating. A squadron launched at max range is 1-2 minutes out, and a ship
# doing 30+ knots covers 3-6 km in that time - projecting a frozen course that
# far throws the drop point clean across the map, typically into the middle of
# the enemy's own formation, and the run then breaks off on arrival having
# achieved nothing. Nothing about a warship's course is worth trusting that far
# out; it will have turned several times.
#
# Cutting the horizon short is safe in a way that overshooting is not: the drop
# point is re-aimed every tick right up to the commit radius, so a lead that
# starts too short is corrected continuously as the squadron closes, while one
# that starts too long sends it somewhere absurd first.
const MAX_LEAD_HORIZON: float = LKP_MAX_LEAD_AGE

# Leads the mark so the ordnance meets the target where it will be: how stale
# the position being aimed at already is (the contact's age, zero for a live one)
# plus the plane's flight time to the actual drop point (via the entry point
# update_flight() enforces) plus the ordnance's own travel time after release
# (bomb fall, torpedo run), all measured from the last observation and capped at
# MAX_LEAD_HORIZON. The drop point moves with the lead, so iterate.
# The velocity comes from the contact solution, so an unspotted target is led on
# the course it was last seen holding rather than the one it is secretly flying.
func _lead_attack_point(squad: Squadron, air_ship: Ship, point: Vector2, direction: Vector2, sol: Dictionary) -> Vector2:
	if not is_instance_valid(air_ship) or not sol.get("valid", false):
		return point
	var sol_vel: Vector3 = sol.velocity
	var vel = Vector2(sol_vel.x, sol_vel.z)
	if vel.length_squared() < 1.0:
		return point
	var lkp_age: float = minf(sol.age, LKP_MAX_LEAD_AGE)
	var origin := Vector2(squad.node.global_position.x, squad.node.global_position.z)
	var speed := _squadron_speed(squad)
	var plane: Aircraft = squad.aircraft[0]
	var t_weapon := plane.ordnance_flight_time()
	var p = squad.params.p() as AircraftParams
	var dir := direction
	if dir.length_squared() < 0.001:
		dir = Vector2(0.0, 1.0)
	else:
		dir = dir.normalized()
	var ordered := point
	for i in range(3):
		var drop := plane.process_attack_point(ordered, dir)
		var entry := drop - dir * (p.attack_descent_radius as float)
		var path := origin.distance_to(entry) + entry.distance_to(drop)
		ordered = point + vel * minf(lkp_age + path / speed + t_weapon, MAX_LEAD_HORIZON)
	return ordered

# Attack run direction: aligned with the target's beam, so the abreast
# formation line spreads along the ship's length - torpedoes run across the
# broadside, bombs land along the keel. Whichever side (right/left) the
# squadron is already approaching from is taken, so it never has to turn
# around mid-run. While it sits near the bow/stern axis the previously chosen
# side is kept to stop the entry point flip-flopping side to side. The result is
# then clamped into the same approach cone the player is held to, so a beam-on
# run is only available when the carrier is already positioned off the target's
# beam - which side was picked above decides which edge of the cone it settles
# on, preserving the no-turn-around property.
const ATTACK_DIR_HYSTERESIS: float = 0.25
var _aviation_attack_dir: Dictionary = {}  # int (squadron index) -> Vector2

func _attack_direction(index: int, squad: Squadron, air_ship: Ship, point: Vector2, sol: Dictionary) -> Vector2:
	var origin := Vector2(squad.node.global_position.x, squad.node.global_position.z)
	var travel := point - origin
	if travel.length_squared() < 0.001:
		travel = Vector2(0.0, 1.0)
	else:
		travel = travel.normalized()
	if not is_instance_valid(air_ship):
		return travel
	# The contact solution's basis, not the ship's live one: for a contact held
	# on an LKP the live heading is something nobody has observed, so lining the
	# run up on it both leaks concealment and aims the formation at a beam the
	# target has since turned off of. Falls back to live only when there is no
	# solution at all, in which case the ship is visible anyway.
	var contact_basis: Basis = sol.get("basis", air_ship.global_transform.basis)
	var right := Vector2(contact_basis.x.x, contact_basis.x.z)
	if right.length_squared() < 0.001:
		return travel
	right = right.normalized()
	var preference := travel.dot(right)
	var dir: Vector2 = right if preference >= 0.0 else -right
	var prev: Vector2 = _aviation_attack_dir.get(index, Vector2.ZERO)
	if absf(preference) < ATTACK_DIR_HYSTERESIS and prev.length_squared() > 0.001:
		dir = prev.normalized()
	# set_attack() enforces the approach cone anyway, but the lead solution in
	# _lead_attack_point() measures its flight path off this direction - hand it
	# the run that will actually be flown, not the beam-on one that gets clamped
	# away, or the entry point and ETA it derives are both wrong.
	dir = Squadron.clamp_attack_direction(dir, point,
		Vector2(_ship.global_position.x, _ship.global_position.z))
	_aviation_attack_dir[index] = dir
	return dir

## Last line of defence before a strike is committed. Every list aviation draws
## from is already team-filtered at the server, so this should never be able to
## fire - it exists because the cost of being wrong is a squadron putting
## torpedoes into a friendly, and one comparison is cheaper than that outcome.
## The push_error is the point: if this ever trips, it names the ship and the
## table it leaked through instead of leaving a silent friendly-fire run.
var _friendly_contact_reported: Dictionary = {}  # Ship -> true, first report only

func _is_hostile(other: Ship) -> bool:
	if other == null or not is_instance_valid(other):
		return false
	if other.team == null or _ship.team == null:
		return false
	if other.team.team_id == _ship.team.team_id:
		# Reported once per offending ship - this is evaluated every tick, and a
		# leak that repeats would otherwise bury the rest of the log.
		if not _friendly_contact_reported.has(other):
			_friendly_contact_reported[other] = true
			push_error("aviation: %s (team %d) offered friendly %s as a strike contact" % [
				_ship.name, _ship.team.team_id, other.name])
		return false
	return true


# ── air target selection ────────────────────────────────────────────────────
# The air group does not attack whatever the guns are shooting at, and it does
# not attack whatever is nearest. Those were both stand-ins for a choice nobody
# was making, and they are the wrong choice for aviation specifically, because a
# strike's value is decided almost entirely by two things the gun target says
# nothing about:
#
#   * how the target is lying. A run crosses the target's length only when it
#     comes in on the beam (see _broadside_quality); against a ship bow-on to
#     the carrier the same squadron, the same ordnance and the same losses buy a
#     fraction of the damage. This is a multiplier on the whole sortie.
#   * what is defending it. AA is per-ship in reach AND in damage, and a ship
#     sitting alone is a different proposition from the identical ship inside
#     two escorts' envelopes - the second costs aircraft, and every aircraft is
#     a full plane_regen_time to replace.
#
# Both are scored here, against everything the bot legitimately believes in, and
# the result is what the hull stations off as well (see CVBehavior).
# Deliberately sticky: the chosen contact is what the rally is measured from and
# what the group is forming up against, so a target that changes every time two
# candidates trade places by a percent is a group that never goes in at all.

## How much better a rival has to score before the group swings onto it.
const AIR_TARGET_STICK_MARGIN: float = 1.3
## Worth of a run that crosses none of the target's length, relative to one that
## crosses all of it. Not zero: a bow-on ship is still worth bombing, it is just
## worth much less, and a floor here is what stops the group refusing every
## target on the board because none of them happens to be beam-on right now.
const AIR_TARGET_BROADSIDE_FLOOR: float = 0.35
## Extra weight on a target that is already hurt - the same drop is likelier to
## finish it, and a sunk ship stops shooting at everything.
const AIR_TARGET_DAMAGE_BONUS: float = 0.5
## What a contact nobody is holding is worth relative to the same ship on a live
## spot, at the two ends of how findable it still is.
##
## A carrier is not restricted to what its team can already see, and charging a
## flat discount for that pretended it was: a contact that went dark on our own
## flank a moment ago lost to a live one clean across the map, when the air group
## could simply have flown over and looked. Every aircraft carries eyes
## (AircraftParams.spotting_range), so being unspotted costs the group a search on
## arrival, not the target's worth - and how much of a search depends entirely on
## how far the ship can have wandered off its dead reckoning by the time the
## squadron gets there, against how wide a swathe the squadron sees on the way in
## (see _refind_odds). Only a position vague enough that the sweep would genuinely
## miss it falls back to the old flat discount.
const AIR_TARGET_REFIND_BEST: float = 0.95
const AIR_TARGET_REFIND_FLOOR: float = 0.35
## Odds of re-finding the contact below which the deck is not committed to it: a
## squadron sent after a position this vague arrives with nothing to drop on and
## spends a whole cycle finding that out.
const AIR_TARGET_SEARCH_MIN_ODDS: float = 0.5
## Share of the score given up at the very edge of the group's reach. Transit is
## cycle time and cycle time is the carrier's real DPM, so a near target beats an
## equal far one - gently, since this must not overrule the two big terms above.
const AIR_TARGET_TRANSIT_PENALTY: float = 0.25

## The contact the whole air group is currently working. Read by the hull so it
## stations off the ship its own squadrons are attacking (see
## CVBehavior._strike_anchor) - a carrier stationed off some other contact puts
## the target outside the approach cone and the beam-on run stops being
## available at all.
var _air_target: Ship = null

func get_air_target() -> Ship:
	if _air_target != null and (not is_instance_valid(_air_target) or not _air_target.is_alive()):
		_air_target = null
	return _air_target

## Squadrons that could fly this strike: attack squadrons with planes on
## strength, airborne or on deck. Used as the yardstick for reach and for what a
## run costs, so selection is judged against the group that would actually go.
func _strike_squadrons(av: AviationController) -> Array[int]:
	var out: Array[int] = []
	for i in range(av.squadrons.size()):
		var squad: Squadron = av.squadrons[i]
		if squad.aircraft.is_empty() or _squadron_is_spotter(squad):
			continue
		if av.get_alive_count(i) <= 0:
			continue
		out.append(i)
	return out

## Mean share of an aircraft the group expects to lose per plane running in on
## `point` from the beam. Averaged over the squadrons rather than taken from one,
## since they differ in speed, descent radius and toughness.
func _group_aa_cost(av: AviationController, strike: Array[int], point: Vector2,
		dir: Vector2) -> float:
	if strike.is_empty():
		return 0.0
	var total: float = 0.0
	for i in strike:
		total += _aa_exposure_ratio(point, dir, av.squadrons[i])
	return total / float(strike.size())

## Furthest the group can usefully be tasked - the longest reach among the
## squadrons that could fly. A contact only one long-legged bomber squadron can
## get to is still a contact worth choosing over nothing.
func _group_reach(av: AviationController, strike: Array[int]) -> float:
	var reach: float = 0.0
	for i in strike:
		reach = maxf(reach, _squadron_operating_radius(av.squadrons[i]))
	return reach

## What a class is worth to a STRIKE, which is not what it is worth to the guns -
## get_threat_class_weight() answers "how much does this thing hurt me", and a
## carrier scores low there precisely because it has no guns worth fearing. From
## the air the ordering is close to reversed: what matters is how easy the ship
## is to hit with a spread, how little it survives, and how much it is still
## going to do if it is left alone.
static func _air_target_class_value(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		# Big, slow, thin-skinned, and every minute it stays afloat is another
		# strike arriving over our own fleet. Nothing else on the board pays
		# back a sortie like this.
		Ship.ShipClass.CV: return 1.4
		# The fleet's damage, and a target a torpedo spread can hardly miss -
		# deck armour is an argument about bombs, not about torpedoes.
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 0.7
		# Small, fast and turning hard: most of a spread misses, and what does
		# connect kills something cheap. Worth striking when it is what there is.
		Ship.ShipClass.DD: return 0.5
	return 1.0

## What one strike on `enemy` is worth, all in. Zero means do not attack it.
func _air_target_score(av: AviationController, strike: Array[int], enemy: Ship,
		sol: Dictionary, reach: float) -> float:
	if not sol.get("valid", false):
		return 0.0
	var pos: Vector3 = sol.position
	var at := Vector2(pos.x, pos.z)
	var carrier := Vector2(_ship.global_position.x, _ship.global_position.z)
	var dist := carrier.distance_to(at)

	# Behind terrain, as far as the air group is concerned: no squadron off this
	# carrier can get down onto it, so it is worth nothing to the deck no matter
	# what it is. Judged from where the ship is BELIEVED to be, same as the rest
	# of the score - a contact whose last known position is sheltered is one the
	# group would fly out to and then be unable to attack.
	if _drop_blocked(at):
		return 0.0

	var score := _air_target_class_value(enemy.ship_class)
	if score <= 0.0:
		return 0.0

	var hc := enemy.health_controller
	if hc != null and hc.max_hp > 0.0:
		var hp_ratio: float = clampf(hc.current_hp / hc.max_hp, 0.0, 1.0)
		score *= 1.0 + AIR_TARGET_DAMAGE_BONUS * (1.0 - hp_ratio)

	# How the target is lying, through the approach cone the run is actually
	# held to - so this is what the drop would achieve from where the carrier
	# is standing, not what it would achieve in the abstract.
	var quality := _broadside_quality(at, sol)
	score *= AIR_TARGET_BROADSIDE_FLOOR + (1.0 - AIR_TARGET_BROADSIDE_FLOOR) * quality

	# What delivering it costs, in aircraft. Priced along the run the group would
	# actually fly, so escorts sitting off the approach side are charged for and
	# ones on the far side are not.
	score /= 1.0 + _group_aa_cost(av, strike, at, _beam_run_direction(at, sol))

	# Transit. Inside the group's reach this is a mild preference for the nearer
	# of two equals; outside it the contact is one no squadron can be sent to
	# yet, and only wins when there is nothing else at all.
	if reach > 0.0:
		if dist <= reach:
			score *= 1.0 - AIR_TARGET_TRANSIT_PENALTY * (dist / reach)
		else:
			score *= (1.0 - AIR_TARGET_TRANSIT_PENALTY) * reach / dist

	# Nobody is holding it. What that costs is the search on arrival, priced by
	# how well the group can expect that search to go - not a flat haircut on
	# what the ship is worth.
	if not _contact_is_strikeable(sol):
		score *= lerpf(AIR_TARGET_REFIND_FLOOR, AIR_TARGET_REFIND_BEST,
			_refind_odds(av, enemy, sol, dist))
	return score

## How well the air group can expect to find `enemy` again where it believes it
## is, 1 for a mark it cannot plausibly have left and 0 for one it could be
## anywhere in. This is the whole difference between a carrier and a gun ship:
## the guns can only shoot what the team is holding, while the air group goes and
## re-acquires the contact itself, so an unspotted ship is a search problem
## rather than a target it does not have.
##
## Two quantities decide it. The searcher is the squadron with the best eyes on
## THIS ship (see _air_detect_radius - a long-sighted spotter buys nothing
## against a ship that has to be closed right up on), and its detection radius is
## the swathe it sweeps on the way in. Against that, how far the ship can have
## come off its dead reckoning by the time that squadron is overhead: the course
## it was last seen holding, run out over the time already elapsed PLUS the
## transit still to fly. Coupling the drift to the transit is what makes this
## discriminate at all - a contact that went dark on the flank is all but certain
## to still be in the sweep, and the identical contact across the map has had two
## more minutes to be somewhere else by the time anyone gets there.
##
## Floored at the rate the presumption model already ages a position at, so a
## contact last seen stopped is not treated as nailed to the water forever.
func _refind_odds(av: AviationController, enemy: Ship, sol: Dictionary, dist: float) -> float:
	if not sol.get("valid", false):
		return 0.0
	var sweep: float = 0.0
	var speed: float = 0.0
	for i in range(av.squadrons.size()):
		var squad: Squadron = av.squadrons[i]
		if squad.aircraft.is_empty() or av.get_alive_count(i) <= 0:
			continue
		if dist > _squadron_operating_radius(squad):
			continue  # cannot get there, so it is not the one doing the finding
		var detect := _air_detect_radius(squad, enemy)
		if detect > sweep:
			sweep = detect
			speed = _squadron_speed(squad)
	if sweep <= 0.0:
		return 0.0
	var eta: float = dist / speed if speed > 0.0 else 0.0
	var vel: Vector3 = sol.velocity
	var rate: float = maxf(Vector2(vel.x, vel.z).length(), EnemyPresumption.RADIUS_GROWTH)
	var drift: float = rate * (float(sol.age) + eta)
	return sweep / (sweep + drift)

## Picks the contact the air group works this tick. Returns
## {ship, sol, point, distance}, empty when there is nothing anywhere.
## `gun_target` is only a candidate like any other - it is included so the ship
## the hull is already shooting at is never overlooked, not so it wins.
func _select_air_target(av: AviationController, server: GameServer, gun_target: Ship) -> Dictionary:
	if server == null or _ship.team == null:
		return {}
	var strike := _strike_squadrons(av)
	var reach := _group_reach(av, strike)

	# Untyped on purpose: the two sources are a typed array and a dictionary's
	# keys, and a typed array will not take the second.
	var candidates: Array = []
	candidates.append_array(server.get_valid_targets(_ship.team.team_id))
	candidates.append_array(server.get_unspotted_enemies(_ship.team.team_id).keys())
	if gun_target != null and not candidates.has(gun_target):
		candidates.append(gun_target)

	var held := get_air_target()
	var best: Ship = null
	var best_sol: Dictionary = {valid = false}
	var best_score: float = 0.0
	var held_score: float = 0.0
	var seen: Dictionary = {}
	for enemy: Ship in candidates:
		if enemy == null or not is_instance_valid(enemy) or not enemy.is_alive():
			continue
		if seen.has(enemy) or not _is_hostile(enemy):
			continue
		seen[enemy] = true
		var sol := get_contact_solution(enemy)
		var score := _air_target_score(av, strike, enemy, sol, reach)
		if score <= 0.0:
			continue
		if enemy == held:
			held_score = score
		if score > best_score:
			best_score = score
			best = enemy
			best_sol = sol
	if best == null:
		_air_target = null
		return {}
	# Hold the current contact unless something is clearly better. The rally, the
	# whole group's stand-off and the hull's own station are all measured from
	# this ship; swapping it on a hair's difference resets all three.
	if held != null and held != best and held_score > 0.0 \
			and best_score < held_score * AIR_TARGET_STICK_MARGIN:
		best = held
		best_sol = get_contact_solution(held)
	_air_target = best
	var pos: Vector3 = best_sol.position if best_sol.get("valid", false) else best.global_position
	var at := Vector2(pos.x, pos.z)
	return {
		ship = best,
		sol = best_sol,
		point = at,
		distance = Vector2(_ship.global_position.x, _ship.global_position.z).distance_to(at),
	}


# Per-tick aviation control. Attack squadrons (bombers/torpedo planes) full-launch
# and re-aim their drop point on the air target every tick - the gun target if
# valid, otherwise the nearest known enemy (visible or unspotted last-known
# position) - until they enter their attack-descent commit radius, then let
# them commit to the run. A run is only ever committed against a contact somebody
# is actually holding; against anything staler the squadron is routed by waypoint
# to loiter over the contact instead, and a run whose contact goes cold before
# release is broken off the same way rather than dropping on open water. The drop point leads a moving target by the squadron's
# ETA plus the ordnance's own flight time, and by however stale the aimed-at
# position already was when it came from a last-known position rather than a live
# one. Spotter squadrons take one known contact each, nearest first, and any left
# over fan out across a search front centred on where the enemy is expected to be.
func aviation_engage(target: Ship, server: GameServer) -> void:
	var av: AviationController = _ship.aviation_controller
	if av == null:
		return
	# Watch for planes being hurt where they are not supposed to be, before any
	# tasking decision is made off the result (see _sample_loiter_damage).
	for i in range(av.squadrons.size()):
		_sample_loiter_damage(i, av.squadrons[i])
	_aviation_threat_cache = _aviation_threats(server)
	var has_air_target := false
	var point := Vector2.ZERO
	var dist := INF
	var air_ship: Ship = null
	# what the bot believes about the ship in `point`: live while it is spotted,
	# its frozen last-known contact once it is not
	var sol: Dictionary = {valid = false}
	# The contact worth striking, not the one the guns happen to be on: how it is
	# lying and what is defending it decide the sortie (see _select_air_target).
	# `point` is the believed position throughout, so a contact held only on an
	# LKP is worked where it has probably got to rather than where it went dark.
	var pick := _select_air_target(av, server, target)
	if not pick.is_empty():
		air_ship = pick.ship
		sol = pick.sol
		point = pick.point
		dist = pick.distance
		has_air_target = true
	else:
		# Nothing scoreable - no solution on anything, or nothing hostile alive.
		# _get_nearest_enemy() draws from both the spotted ships and the
		# last-known positions of unspotted ones, so whether `point` is live or
		# stale depends on which it picked - the contact solution sorts that out.
		var info = _get_nearest_enemy()
		if not info.is_empty():
			air_ship = info.get("ship")
			if air_ship == null or _is_hostile(air_ship):
				point = Vector2(info.position.x, info.position.z)
				dist = info.distance
				if air_ship != null:
					sol = get_contact_solution(air_ship)
				has_air_target = true
			else:
				air_ship = null
	# Where a squadron shadows the contact from when it may not strike it: the
	# believed position, so it loiters where the ship has probably got to.
	var loiter_point := point
	if sol.get("valid", false):
		var sol_pos: Vector3 = sol.position
		loiter_point = Vector2(sol_pos.x, sol_pos.z)
	# Whether a contact nobody is holding is worth sending the deck after anyway.
	# Only consulted while it is unstrikeable; a held contact is not a search.
	var refind: float = 1.0
	if has_air_target and air_ship != null and not _contact_is_strikeable(sol):
		refind = _refind_odds(av, air_ship, sol, dist)
	var aa_reach := _enemy_aa_reach(server)
	if has_air_target:
		# Squadrons airborne, in reach and willing to work this contact, waiting
		# out of AA reach for the rest of the group (see _run_strike_group).
		var group: Array[int] = []
		# Set while a squadron still on the deck could join the group soon enough
		# to be worth holding it for.
		var waiting_for_more := false
		for i in range(av.squadrons.size()):
			var squad: Squadron = av.squadrons[i]
			if squad.aircraft.is_empty():
				continue
			if _squadron_is_spotter(squad):
				continue
			# What it took off with, recorded once per sortie so attrition is
			# measured against what was committed (see _sortie_gutted).
			if squad.active:
				if not _aviation_launch_strength.has(i):
					_aviation_launch_strength[i] = av.get_alive_count(i)
			else:
				_aviation_launch_strength.erase(i)
			if squad.returning:
				_forget_squadron(i)
				continue
			if av.get_alive_count(i) <= 0:
				# Nothing to put up until the next replacement is built.
				_forget_squadron(i)
				continue
			var p = squad.params.p() as AircraftParams
			# Mauled on the way in: what is left will not achieve much, and every
			# survivor still costs a full build time if it is thrown away too.
			if squad.active and _sortie_gutted(av, i):
				_forget_squadron(i)
				squad.abort_sortie()
				continue
			if not _squadron_should_take_attack(squad, p):
				# On the final run: the drop point is frozen from here by design,
				# so a contact that goes cold now leaves the squadron aimed at
				# open water. Turn it onto something else instead.
				if _strike_contact_lost(i, air_ship, sol):
					_retarget_or_hold(i, squad, server,
						_aviation_strike_target.get(i, null), loiter_point)
				continue
			# ── released and running in ──────────────────────────────────────
			# Judged entirely on the contact it was sent after. Nothing about the
			# rest of the picture reaches a squadron that is already inbound: it
			# does not swing onto a ship somebody just spotted, and it does not
			# fall back into the forming group when one goes dark. Either it
			# presses the attack it was committed to, or the run is over.
			if squad.active and squad.attack_point != null:
				var run := _committed_contact(i, air_ship, sol)
				if run.ship == null or _contact_strike_lost(run.sol):
					_retarget_or_hold(i, squad, server, run.ship, loiter_point)
					continue
				# The lead is re-solved every tick, so a target steaming in behind
				# an island walks its own drop point into the dead zone. The run
				# is over the moment that happens - pressing on only spends the
				# ordnance on water the squadron is not allowed to drop on.
				if not _aim_run(i, squad, run.ship, run.sol):
					_retarget_or_hold(i, squad, server, run.ship, loiter_point)
				continue
			# ── still forming up ─────────────────────────────────────────────
			# The reach a squadron is judged against widens slightly once it is
			# part of the group. A contact sitting on the boundary would otherwise
			# flick a squadron in and out of the strike from one tick to the next,
			# and the tick it happens to be out is the tick the group goes in
			# without it - leaving it loitering while the others attack.
			var reach := _squadron_operating_radius(squad)
			if _aviation_in_group.has(i):
				reach *= AVIATION_RANGE_HYSTERESIS
			if dist > reach:
				# Contact is beyond this squadron's useful reach from the carrier
				# - its tether, or as far as its fuel takes it. Skipping the rest
				# of the loop here abandoned the squadron outright: an airborne
				# one went on flying whatever order it last had, with no re-aim
				# and no break-off, and orbited its last loiter point
				# indefinitely. That is why this only ever bit torpedo squadrons
				# - their range is short enough that a carrier sitting at its
				# standoff distance straddles the boundary, so the gate flickers,
				# while longer-ranged bombers stay inside it and keep being
				# re-tasked. Shadow instead, so the squadron holds at the edge of
				# its reach ready to strike the moment the carrier closes. One
				# still on deck is left there.
				_aviation_in_group.erase(i)
				if squad.active:
					_shadow_contact(i, squad, loiter_point)
				continue
			if not _contact_is_strikeable(sol):
				# Nothing solid to drop on yet - wait it out on station rather
				# than committing a run that would release on empty water.
				_aviation_in_group.erase(i)
				if squad.active:
					_shadow_contact(i, squad, loiter_point)
					continue
				# Still on deck. Go anyway when the contact is one the group can
				# expect to FIND on arrival (see _refind_odds): the whole point
				# of choosing an unspotted contact is that the air group goes and
				# re-acquires it, and a deck that waits for somebody else to spot
				# it first pays the transit twice - once for the spotter, then
				# again from the deck afterwards. Ranked below a strike on a held
				# contact and below the spotter that is going to do the finding,
				# so this only ever takes a slot nothing better wanted.
				if refind >= AIR_TARGET_SEARCH_MIN_ODDS:
					var search_strength := _squadron_strength(av, i, squad)
					if search_strength >= AVIATION_MIN_LAUNCH_STRENGTH:
						_request_launch(i, LAUNCH_PRIORITY_SEARCH + search_strength)
				continue
			if not squad.active:
				# On deck and willing. Ask for the next takeoff slot, and hold the
				# group for it if it can realistically make that launch.
				var strength := _squadron_strength(av, i, squad)
				if strength >= AVIATION_MIN_LAUNCH_STRENGTH:
					_request_launch(i, LAUNCH_PRIORITY_STRIKE + strength)
					if av.get_cooldown_remaining(i) <= AVIATION_JOIN_WAIT_MAX:
						waiting_for_more = true
				continue
			_aviation_in_group[i] = true
			group.append(i)
		# No group forming means no stand-off to preserve: the next one starts
		# from whatever the picture says rather than inheriting the last one's
		# pull-back.
		if group.is_empty():
			_rally_hold_dist = INF
		# Cap how far forward it may sit first, then clear it of threats: the
		# other order lets the cap drag the rally back into an envelope the
		# clearance had just pushed it out of. Only the capped distance is
		# remembered, so backing away from a threat never becomes licence to
		# creep forward again next tick.
		# Seeded from the AA that actually bears on the contact rather than the
		# heaviest on the board (see _aa_reach_near); _clear_of_threats below is
		# what handles everything else the rally would otherwise sit inside.
		var rally := _clear_of_threats(_hold_rally(
			_strike_rally_point(point, _aa_reach_near(point, aa_reach))))
		_run_strike_group(av, group, rally, waiting_for_more, point, air_ship, sol)
	else:
		# Not one contact anywhere, live or remembered - the tables have to be
		# completely empty for this, so there is nothing to turn onto either. A
		# run still in progress is aimed at open water, so it breaks off and
		# holds where it already is, ready for whatever turns up next; only once
		# it is too low on fuel for that to lead anywhere does it go home (see
		# _shadow_contact). Nothing is forming up, so there is no stand-off to
		# preserve.
		_rally_hold_dist = INF
		for i in range(av.squadrons.size()):
			var squad: Squadron = av.squadrons[i]
			if squad.aircraft.is_empty() or _squadron_is_spotter(squad):
				continue
			if not squad.active:
				_aviation_launch_strength.erase(i)
				continue
			if squad.attack_point != null:
				_shadow_contact(i, squad, squad.attack_point)
			elif not squad.returning and squad.fuel_remaining <= AVIATION_RTB_FUEL_RESERVE:
				_forget_squadron(i)
				squad.abort_sortie()
	# Gather the spotters first: each needs to know how many there are and which
	# slice of the search front is its own
	var spotters: Array[int] = []
	for i in range(av.squadrons.size()):
		var squad: Squadron = av.squadrons[i]
		if squad.aircraft.is_empty() or not _squadron_is_spotter(squad):
			continue
		if av.get_alive_count(i) <= 0:
			continue
		spotters.append(i)
	# With nothing to strike, finding something is the most valuable thing the
	# deck can do, so a spotter takes the takeoff slot ahead of any strike
	# squadron - which would otherwise spend it flying at a contact nobody holds.
	# A contact chosen but not held counts as nothing to strike for this: the
	# group is going after it either way, and the sortie that turns it into a
	# target the group may actually drop on is this one.
	var spot_priority: float = LAUNCH_PRIORITY_SPOT if _contact_is_strikeable(sol) \
		else LAUNCH_PRIORITY_BLIND_SPOT
	for slot in range(spotters.size()):
		var idx: int = spotters[slot]
		_spot_squadron(idx, av.squadrons[idx], server, slot, spotters.size(),
			aa_reach, spot_priority, air_ship)
	# One deck slot, awarded to the best of this tick's requests.
	_grant_launch(av)


## Holds a forming strike group clear of the target and sends the whole group in
## at once. Concentration is the entire point: a ship's AA fires once a second at
## ONE plane inside its envelope (see AAAController), so its damage is divided
## among every plane over the target at that moment, and damage that does not
## finish a plane heals as soon as it lands (see Squadron.recall). Squadrons that
## trickle in one at a time each face that fire alone and are shot down for good;
## squadrons that arrive together mostly come home dented. The deck can only put
## one squadron up per takeoff interval, so the concentration the old
## launch-everything behaviour got for free now has to be rebuilt in the air.
##
## The rally is also where the group waits for its shot. A run only crosses the
## target's length when it comes in on the beam (see _broadside_quality), and
## which way a ship is lying is not something the carrier controls - it is
## something that comes round if you wait for it, because ships turn. So a
## formed group holding on a target that is bow-on holds a little longer rather
## than spending its ordnance on the narrowest profile the ship has. What stops
## that becoming a group that waits forever is the fuel deadline below: the
## squadrons go in on whatever presentation they have got the moment waiting any
## longer would leave them unable to fly the run at all.
func _run_strike_group(av: AviationController, group: Array[int], rally: Vector2,
		waiting_for_more: bool, point: Vector2, air_ship: Ship, sol: Dictionary) -> void:
	if group.is_empty():
		return
	# Direction the group would attack from if it went in now - the run the fuel
	# deadline has to cover, and the one whose beam presentation is judged.
	var run_dir := _beam_run_direction(point, sol)
	# The group cannot wait longer than its most fuel-critical member can afford
	# and still fly the run: a 15s takeoff interval across a five-squadron deck is
	# a minute of forming up, which at the edge of the tether is most of a tank.
	# Costed on the run actually flown, dog-leg onto the beam included, so the
	# deadline is the real one rather than a straight-line optimism (_strike_eta).
	#
	# The reserve held back is the larger of the strike reserve and the loiter
	# path's own give-up point: _shadow_contact() sends a squadron home once it
	# drops under AVIATION_RTB_FUEL_RESERVE, and a group told to keep holding
	# past that point is a group that flies its whole sortie to the rally and
	# then turns for base still loaded.
	var reserve: float = maxf(AVIATION_STRIKE_FUEL_RESERVE, AVIATION_RTB_FUEL_RESERVE)
	var slack: float = INF
	var formed := true
	for i in group:
		var squad: Squadron = av.squadrons[i]
		slack = minf(slack,
			squad.fuel_remaining - _strike_eta(squad, point, run_dir) - reserve)
		var pos := Vector2(squad.node.global_position.x, squad.node.global_position.z)
		if pos.distance_to(rally) > AVIATION_RALLY_ARRIVE_DIST:
			formed = false
	# Out of time: go in now, on whatever beam the target is showing. Ordnance
	# dropped at a bad angle still beats ordnance flown home - that is a whole
	# cycle (transit, rearm, transit) thrown away for nothing.
	var out_of_time: bool = slack <= 0.0
	# A lone squadron has nobody to form up with, so it goes in as soon as there
	# is nothing left to wait for rather than flying to a rally point first.
	var ready: bool = not waiting_for_more and (formed or group.size() <= 1)
	var release: bool = out_of_time or (ready and not _wait_for_broadside(point, sol))
	if release:
		# This group is on its way in; the next one works out its own stand-off.
		_rally_hold_dist = INF
	for i in group:
		var squad: Squadron = av.squadrons[i]
		if not release:
			_shadow_contact(i, squad, rally)
			continue
		var dir := _attack_direction(i, squad, air_ship, point, sol)
		var drop := _lead_attack_point(squad, air_ship, point, dir, sol)
		if _drop_blocked(drop):
			# Scoring already rejects targets in a dead zone, so reaching this
			# means the lead has pushed the mark into one since. Keep the
			# squadron at the rally rather than releasing it onto a run that
			# cannot be flown.
			_shadow_contact(i, squad, rally)
			continue
		_aviation_in_group.erase(i)
		_aviation_shadow_issued.erase(i)
		_aviation_strike_target[i] = air_ship
		squad.set_attack(drop, dir)


## Beam presentation below which a formed group would rather keep waiting at the
## rally than go in. 0.8 is roughly 53 degrees off the target's bow: past that
## the run still crosses most of the hull, and holding out for a perfect beam
## costs more in fuel and in the target simply steaming out of reach than the
## last few per cent of length is worth.
const BROADSIDE_RELEASE_QUALITY: float = 0.8

## Whether the group should keep holding for a better angle. Only ever true
## against a contact somebody is actually looking at: the heading on a
## last-known position is one nobody has watched since it was frozen, so waiting
## for it to come round is waiting on a number that cannot change. Against those
## the group goes in on what it has.
func _wait_for_broadside(point: Vector2, sol: Dictionary) -> bool:
	if not sol.get("valid", false) or bool(sol.get("is_lkp", true)):
		return false
	return _broadside_quality(point, sol) < BROADSIDE_RELEASE_QUALITY

## Whether putting a spotter up is worth what it costs. Launching reveals the
## ship for a few seconds (see AviationController.launch_squadron), so a plane
## sent up on spawn to sweep empty water buys nothing and tells the enemy where
## its ship is - which is the entire information exchange, in their favour.
##
## Decided the same way the bot decides to fire radar (see _should_use_radar):
## only from what the team legitimately holds, never from omniscience.
##
## Triggers:
##   1. Already detected, or already being shot at - the launch gives away
##      nothing that is not given away, so anything the spotter turns up is free.
##   2. A ship held right now within the squadron's useful reach: worth having
##      eyes over it before it goes dark, and worth extending gun range onto.
##   3. A ship the team has lost recently enough that it is probably still
##      somewhere a plane could find it, within that same reach.
## Nothing anywhere means nothing to look at: the plane stays on the deck.
const SPOTTER_LKP_MAX_AGE: float = 60.0

func _should_launch_spotter(squad: Squadron, server: GameServer) -> bool:
	if server == null or _ship.team == null:
		return false
	if _ship.is_detected() or not active_shooters_at_me.is_empty():
		return true
	# How far out a contact can be and still be findable: as far as the squadron
	# can fly, plus however close it then has to get to actually see it.
	var fly_reach := _squadron_operating_radius(squad)
	var my_team: int = _ship.team.team_id
	for enemy in server.get_valid_targets(my_team):
		if not is_instance_valid(enemy):
			continue
		var reach := fly_reach + _air_detect_radius(squad, enemy)
		if enemy.global_position.distance_to(_ship.global_position) <= reach:
			return true
	var unspotted := server.get_unspotted_enemies(my_team)
	var times := server.get_unspotted_enemy_times(my_team)
	var now: float = Time.get_ticks_msec() / 1000.0
	for enemy in unspotted.keys():
		if not is_instance_valid(enemy):
			continue
		if now - float(times.get(enemy, 0.0)) > SPOTTER_LKP_MAX_AGE:
			continue  # lost too long ago to still be where the plane would look
		var lkp: Vector3 = unspotted[enemy]
		if lkp.distance_to(_ship.global_position) <= fly_reach + _air_detect_radius(squad, enemy):
			return true
	# Nothing observed, but the clock still says something: a fleet that left
	# its spawn some minutes ago has come far enough by now to be worth flying
	# out to meet. This is what keeps the plane on the deck at the start of a
	# battle - the presumed enemy is still on their spawn line, well out of
	# reach - and puts it up once that stops being true (see EnemyPresumption).
	for guess in get_presumed_contacts():
		var search_reach := fly_reach + _air_detect_radius(squad, guess.ship)
		if (guess.position as Vector3).distance_to(_ship.global_position) <= search_reach:
			return true
	return false


# Total angle the leftover spotters are fanned across, centred on the bearing to
# where the enemy is expected to be, so a carrier with several spotter squadrons
# sweeps a front instead of stacking them all onto one point.
const SPOTTER_FAN_ANGLE_DEG: float = 80.0

# Where the enemy is expected to be. Anything actually known wins; failing that
# the enemy spawn, which is the one bearing that does not depend on what this
# ship happens to be doing. The ship's own heading is a last resort only - using
# it as the primary source sent spotters sideways or backwards the moment a
# carrier turned to put an island between itself and the enemy, which is exactly
# when it turns and exactly when it needs the spotters pointed the other way.
func _expected_enemy_center() -> Vector3:
	var info = _get_nearest_enemy()
	if not info.is_empty():
		return info.position
	# Nothing held anywhere: fall back on where the enemy line has presumably
	# got to rather than on the spawn it left, which stops being the right
	# bearing within the first couple of minutes.
	var guesses := get_presumed_contacts()
	if not guesses.is_empty():
		var center := Vector3.ZERO
		for guess in guesses:
			center += guess.position as Vector3
		return center / float(guesses.size())
	_initialize_spawn_cache()
	if _spawn_cache_initialized:
		return _cached_enemy_spawn
	return _ship.global_position - _ship.global_transform.basis.z * 10000.0

# Keeps a search point inside the playable area - a spotter sent past the map
# edge burns its whole sortie over empty water.
func _clamp_to_map(p: Vector2) -> Vector2:
	return Vector2(
		clampf(p.x, -Ship.MAP_BOUNDARY, Ship.MAP_BOUNDARY),
		clampf(p.y, -Ship.MAP_BOUNDARY, Ship.MAP_BOUNDARY))

# Search station for a spotter with nothing specific to look at: max range out
# along the bearing to the expected enemy, offset into its own slice of the fan
# so `fan_count` squadrons cover a front rather than one point.
func _sweep_point(squad: Squadron, fan_slot: int, fan_count: int) -> Vector2:
	var ship_pos := Vector2(_ship.global_position.x, _ship.global_position.z)
	var center := _expected_enemy_center()
	var bearing := Vector2(center.x - ship_pos.x, center.z - ship_pos.y)
	if bearing.length_squared() < 1.0:
		bearing = Vector2(-_ship.global_transform.basis.z.x, -_ship.global_transform.basis.z.z)
	if bearing.length_squared() < 0.001:
		bearing = Vector2(0.0, 1.0)
	bearing = bearing.normalized()
	var offset := 0.0
	if fan_count > 1:
		var t: float = float(fan_slot) / float(fan_count - 1) - 0.5
		offset = t * deg_to_rad(SPOTTER_FAN_ANGLE_DEG)
	return _clamp_to_map(ship_pos + bearing.rotated(offset) * _squadron_operating_radius(squad))

# Last-known positions worth flying a spotter out to, nearest first, with `watch`
# - the contact the air group is working - ahead of the lot. Read through the
# contact solution, so a spotter is sent where the ship has probably got to by
# now rather than where it was standing when it went dark.
func _unspotted_contacts_in_range(server: GameServer, squad: Squadron,
		watch: Ship = null) -> Array[Dictionary]:
	var points: Array[Dictionary] = []
	if server == null:
		return points
	# A plane does not have to reach the ship, only get within sight of it - but
	# only as far within sight as that particular ship allows, which for most is
	# a good deal less than the squadron can see (see _air_detect_radius).
	var fly_reach := _squadron_operating_radius(squad)
	var speed := _squadron_speed(squad)
	var ranked: Array[Dictionary] = []
	for guess in get_presumed_contacts():
		var pos: Vector3 = guess.position
		var detect := _air_detect_radius(squad, guess.ship)
		# Led by the flight out: a spotter sent where a ship is believed to be
		# NOW arrives to find nothing, while one sent where it will be by the
		# time the plane gets there arrives with the ship inside detection
		# range. This is what lets a carrier put eyes on an enemy that has
		# never been seen at all - by the time the squadron is at the edge of
		# its reach, the enemy has closed the rest of the way itself.
		if speed > 0.0:
			pos = _presumption.project(guess, _ship.global_position.distance_to(pos) / speed)
		var d := _ship.global_position.distance_to(pos)
		if d - detect > fly_reach:
			continue  # the squadron cannot get close enough to see it
		ranked.append({dist = d, point = Vector2(pos.x, pos.z), detect = detect, ship = guess.ship})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if (a.ship == watch) != (b.ship == watch):
			return a.ship == watch
		return a.dist < b.dist)
	for r in ranked:
		points.append({point = r.point, detect = r.detect})
	return points

# How far this squadron's aircraft can see at all - only half of what decides a
# sighting (see _air_detect_radius).
func _squadron_spot_radius(squad: Squadron) -> float:
	return (squad.params.p() as AircraftParams).spotting_range

# The range at which this squadron actually finds THIS ship. Both halves have to
# hold (see GameServer.handle_air_spot): the aircraft has to look that far, and
# the ship has to be visible from that far. So the tighter of the two governs,
# and a long-sighted spotter buys nothing against a ship that has to be closed
# right up on. Falls back to the squadron's own reach when the ship's
# concealment is not readable.
func _air_detect_radius(squad: Squadron, enemy: Ship) -> float:
	var reach := _squadron_spot_radius(squad)
	if enemy == null or not is_instance_valid(enemy):
		return reach
	if enemy.concealment == null or enemy.concealment.params == null:
		return reach
	return minf(reach, (enemy.concealment.params.p() as ConcealmentParams).air_radius)

# One spotter per known contact, nearest first; every squadron left over fans out
# across the search front instead of piling onto a contact another squadron has
# already been sent to. `watch` is the contact the air group has chosen, which
# jumps the queue ahead of nearest-first: the strike is measured from that ship,
# is already forming up against it, and is waiting on somebody to put eyes back
# on it - a spotter sent to a nearer contact nobody is going to attack leaves the
# whole group holding.
func _spot_squadron(index: int, squad: Squadron, server: GameServer,
		fan_slot: int, fan_count: int, aa_reach: float, priority: float,
		watch: Ship = null) -> void:
	if squad.returning:
		return
	if not squad.active:
		_aviation_spot_issued.erase(index)
	var contacts := _unspotted_contacts_in_range(server, squad, watch)
	var desired: Vector2
	if fan_slot < contacts.size():
		# Watching a particular ship: stand off it instead of orbiting on top of
		# it. A spotter sees far enough to keep the contact from outside its AA,
		# and inside it a lone squadron is shot down one plane every few seconds
		# for the whole sortie (see _spot_station).
		var contact: Dictionary = contacts[fan_slot]
		# Stood off the AA around THIS contact, not the longest reach anywhere:
		# with mixed batteries the board-wide figure pushes every spotter past
		# the range it can still see from, and _spot_station then has to choose
		# between seeing and being safe when it never actually had to.
		desired = _clamp_to_squadron_range(squad, _spot_station(
			squad, contact.point, _aa_reach_near(contact.point, aa_reach), contact.detect))
	else:
		# fan only the squadrons that are actually sweeping, so they spread over
		# the whole front rather than crowding the slots the contacts left free
		desired = _sweep_point(squad, fan_slot - contacts.size(), maxi(fan_count - contacts.size(), 1))
	if _aviation_spot_issued.has(index) and (desired - _aviation_spot_issued[index]).length() < AVIATION_SPOT_REISSUE_DIST:
		return
	if not squad.active:
		# Still on deck: ask for the takeoff slot and station it once it is up -
		# an order given now would be cleared by the launch anyway.
		if _should_launch_spotter(squad, server):
			_request_launch(index, priority)
		return
	var dir = desired - Vector2(_ship.global_position.x, _ship.global_position.z)
	if dir.length_squared() < 1.0:
		dir = Vector2(0.0, 1.0)
	squad.set_attack(desired, dir.normalized())
	_aviation_spot_issued[index] = desired


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
	if cover_intent != null and cover_skill.is_cover_on_the_way(ctx):
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
	if absf(angle_difference(intent.target_heading, ship_heading)) > PI * 0.65:
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
	info["visible"] = _ship.is_detected() if _ship != null else false
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
	if repair != -1:
		var repair_party = (_ship.consumable_manager.equipped_consumables[repair] as RepairParty)
		repair_party = repair_party.p() as RepairParty
		var heal_percent_per_repair = repair_party.heal_per_sec * repair_party.duration if repair != -1 else 0
		var heal_per_repair = max_hp * heal_percent_per_repair
		# var effective_heal = min(healable, heal_per_repair)

		if healable > heal_per_repair or hp < 0.25:
			#if repair != -1:
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
	# Smoke breaks LOS, so it answers being seen or air-spotted but does nothing
	# about a ping — popping it while pinged wastes the charge and parks us.
	# det_* are the server-side flags; radar_detected/hydro_detected are written
	# by the sync_unspotted RPC and are always false on the server.
	if _ship.health_controller.current_hp / _ship.health_controller.max_hp < 0.5 \
			and active_shooters_at_me.size() > 0 and _ship.is_detected() \
			and not (_ship.det_radar or _ship.det_hydro):
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
	# visible_to_enemy only: the deduction is about LOS, and hydro answers neither
	# a radar ping (see _should_use_radar trigger 3) nor an aircraft.
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
	#   3. This ship's det_hydro or det_radar flag is set — an enemy with active
	#      detection is within ~4–8 km.  If no enemy is currently visible,
	#      firing radar may flush out that concealed spotter.
	var server_node: GameServer = _ship.get_node_or_null("/root/Server")
	if server_node == null:
		return false

	var my_team: int = _ship.team.team_id
	const RADAR_RANGE: float = 8000.0

	var spotted := server_node.get_valid_targets(my_team)

	# --- Trigger 1: detected but no visible enemy within radar range ---
	# A ping counts: hydro reaches ~4 km and radar ~8 km, so whoever is lighting
	# us is inside radar range. Air is excluded — radar cannot answer aircraft.
	if (_ship.visible_to_enemy or _ship.det_hydro or _ship.det_radar) \
			and _ship.concealment != null:
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
	# det_hydro/det_radar are server-authoritative flags the bot legitimately reads.
	# HYDRO means an enemy pinger is within ~4 km; RADAR within ~8 km.
	# If no enemy is currently visible, the concealed pinger may be within radar range.
	if (_ship.det_hydro or _ship.det_radar) and spotted.is_empty():
		return true

	return false
