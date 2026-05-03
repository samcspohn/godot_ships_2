class_name SkillBroadside
extends BotSkill

## Post-processing skill that finds the heading at which all guns can bear on the
## target and gently pulls the ship toward that angle in sync with the reload cycle.
##
## Usage:  intent = _skill_broadside.apply(intent, ctx, params)
##
## Two mechanisms work together:
##
## 1. Heading target:  the broadside heading is found by scanning all candidate
##    ship headings and picking the one that (a) maximises the number of guns
##    that can bear, (b) minimises remaining traversal cost (guns already aimed
##    that way), and (c) is closest to the incoming navigation heading — so the
##    chosen broadside side never conflicts wildly with where the ship is going.
##    An oscillation timer blends between the raw navigation heading and the
##    broadside heading to introduce unpredictability.
##
## 2. Heading weight:  the navigator's arc-scoring weight is driven by the
##    average gun reload fraction (0 = just fired, 1 = all ready).  When guns
##    are reloading, heading_weight ≈ 0 and the navigator steers freely toward
##    the destination.  As guns approach ready, heading_weight rises toward 1
##    and the navigator begins to favour arcs that align the ship with the
##    broadside heading — so the ship arrives at the firing angle just as the
##    guns become ready, then fires and navigates freely again.

## Oscillation timer — drives the blend between navigation and broadside heading.
var _osc_timer: float = 0.0

## How many radians we sample when searching for all-guns headings.
const SAMPLE_STEP: float = deg_to_rad(2.0)

## ---------------------------------------------------------------------------
## Public API
## ---------------------------------------------------------------------------

func apply(intent: NavIntent, ctx: SkillContext, params: Dictionary) -> NavIntent:
	if intent == null:
		return null

	var ship = ctx.ship
	if ship == null or not is_instance_valid(ship):
		return intent

	var target = ctx.target
	var gun_range = ctx.ship.artillery_controller.get_params()._range
	# We need a threat position to compute gun bearings against.
	var threat_pos: Vector3 = Vector3.ZERO
	# var to_threat: Vector3
	if target != null and is_instance_valid(target):
		if target.global_position.distance_to(ctx.ship.global_position) > gun_range:
			return intent
		threat_pos = target.global_position
		var _threat_pos = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(
			ship.global_position,
			threat_pos,
			target.linear_velocity,
			ship.artillery_controller.get_params().shell1)[2]
		if _threat_pos != null:
			threat_pos = _threat_pos
	else:
	# 	var spotted_center = ctx.behavior._get_spotted_danger_center()
	# 	threat_pos = spotted_center if spotted_center != Vector3.ZERO else ctx.behavior._get_danger_center()
	# if threat_pos == Vector3.ZERO:
		return intent

	var guns: Array = ship.artillery_controller.guns
	if guns.is_empty():
		return intent

	# --- Compute the world-space bearing from ship to threat ---
	var to_threat = threat_pos - ship.global_position
	to_threat.y = 0.0
	if to_threat.length_squared() < 1.0:
		return intent
	var threat_bearing: float = atan2(to_threat.x, to_threat.z)

	# --- Find the broadside heading nearest to the current navigation heading ---
	# Using the navigation heading as the preferred direction ensures the chosen
	# broadside side is always the one that least disrupts the ship's travel
	# (e.g. kiting away, covering behind an island, pushing forward).
	var desired_heading: float = intent.target_heading
	var broadside_heading: float = _find_best_all_guns_heading(guns, threat_bearing, desired_heading)

	# --- Oscillation: blend the target heading between navigation and broadside ---
	# Period matches gun reload so the ship completes one full swing per salvo cycle.
	var reload_time: float = ship.artillery_controller.get_params().reload_time
	var osc_period: float = maxf(reload_time, 1.0)
	var osc_bias: float = params.get("oscillation_bias", 0.5)  # 0 = pure nav, 1 = pure broadside
	var delta: float = 1.0 / Engine.physics_ticks_per_second
	_osc_timer += delta

	# Sinusoidal blend 0..1; bias shifts the midpoint so ship spends more time
	# near broadside when bias is high.
	var t: float = (sin(_osc_timer * TAU / osc_period) + 1.0) * 0.5
	var blend: float = clampf(t * (1.0 + osc_bias) - osc_bias * 0.5, 0.0, 1.0)

	# Final target heading: gradually morphs from navigation heading toward broadside.
	var final_heading: float = _lerp_angle(desired_heading, broadside_heading, blend)

	# --- Heading weight driven by actual gun reload state ---
	# Average reload fraction across all guns (0 = all just fired, 1 = all ready).
	# This naturally gates the heading pursuit:
	#   - Just fired  → reload ≈ 0 → heading_weight ≈ 0 → navigator steers freely
	#   - Mid reload  → reload rises → heading_weight rises → navigator starts angling
	#   - Guns ready  → reload = 1  → heading_weight = 1  → ship is at broadside, fires
	var total_reload: float = 0.0
	for gun in guns:
		total_reload += gun.reload
	var guns_ready: float = total_reload / float(guns.size())  # 0..1

	intent.target_heading = final_heading
	intent.heading_weight = guns_ready

	return intent


## ---------------------------------------------------------------------------
## Internals
## ---------------------------------------------------------------------------

## Find the ship heading (world-space) at which all guns can bear on the threat,
## staying as close to `preferred_heading` as possible.
##
## The threat is to either the port or starboard side of `preferred_heading`,
## and either ahead of or behind the perpendicular.  For each of those four
## quadrants exactly one gun-set/limit binds: e.g. when the threat is in the
## port-front quadrant, every front gun can already swing to it (their port
## limit reaches at least to broadside), so the constraint is the back guns'
## port limit (their `min`).  We pick the most-restrictive such gun and rotate
## the ship just enough to place the threat at that limit — or, if the threat
## is already inside every gun's arc, return `preferred_heading` unchanged.
func _find_best_all_guns_heading(guns: Array, threat_bearing: float, preferred_heading: float) -> float:
	# `diff` is the threat's local angle relative to the ship at preferred_heading.
	# Convention: 0 = forward, +π/2 = port, ±π = back, -π/2 = starboard.
	var diff: float = angle_difference(preferred_heading, threat_bearing)
	var candidate: float
	var preferred_ok: bool

	if diff >= 0.0:
		# Threat to port. Same-side broadside ≈ +π/2.
		if diff < PI * 0.5:
			# Port-front quadrant: bound by back guns' port limit (their min).
			# Pick the largest min — the most restrictive port reach.
			var worst: float = 0.0
			for gun: Turret in guns:
				if gun.position.z > 0.0 and gun.min_rotation_angle > worst:
					worst = gun.min_rotation_angle
			candidate = worst
			# Preferred works iff threat is already past every back gun's min.
			preferred_ok = diff >= candidate
		else:
			# Port-back quadrant: bound by front guns' port limit (their max).
			# Pick the smallest max — the most restrictive port reach.
			var worst: float = PI
			for gun: Turret in guns:
				if gun.position.z < 0.0 and gun.max_rotation_angle < worst:
					worst = gun.max_rotation_angle
			candidate = worst
			preferred_ok = diff <= candidate
	else:
		# Threat to starboard. Same-side broadside ≈ -π/2.
		if diff > -PI * 0.5:
			# Starboard-front quadrant: bound by back guns' starboard limit (their max).
			# Pick the smallest max in [0, TAU] — most restrictive starboard reach.
			var worst: float = TAU
			for gun: Turret in guns:
				if gun.position.z > 0.0 and gun.max_rotation_angle < worst:
					worst = gun.max_rotation_angle
			candidate = worst - TAU  # convert to signed [-π, π]
			preferred_ok = diff <= candidate
		else:
			# Starboard-back quadrant: bound by front guns' starboard limit (their min).
			# Pick the largest min in [0, TAU] — most restrictive starboard reach.
			var worst: float = PI
			for gun: Turret in guns:
				if gun.position.z < 0.0 and gun.min_rotation_angle > worst:
					worst = gun.min_rotation_angle
			candidate = worst - TAU  # convert to signed
			preferred_ok = diff >= candidate

	if preferred_ok:
		return preferred_heading

	# Rotate the ship so the threat lands exactly at the binding gun's limit.
	return wrapf(threat_bearing - candidate, -PI, PI)
	# return preferred_heading + angle_difference(preferred_heading, threat_bearing + candidate)


## Sum the absolute local traversal each *bearing* gun must still rotate to
## aim at the threat when the ship faces `ship_heading`.  Lower = guns are
## already closer to the correct side, so this heading should be preferred.
func _total_traversal_cost(guns: Array, ship_heading: float, threat_bearing: float) -> float:
	var total: float = 0.0
	for gun in guns:
		if not _can_gun_bear(gun, ship_heading, threat_bearing):
			continue
		var needed_local: float = threat_bearing - ship_heading - gun.base_rotation
		needed_local = atan2(sin(needed_local), cos(needed_local))
		total += absf(angle_difference(gun.rotation.y, needed_local))
	return total


## Count how many guns can bear on `threat_bearing` if the ship were facing
## `ship_heading`.
func _count_guns_bearing(guns: Array, ship_heading: float, threat_bearing: float) -> int:
	var count: int = 0
	for gun in guns:
		if _can_gun_bear(gun, ship_heading, threat_bearing):
			count += 1
	return count


## Check if a single gun/turret can bear on the threat given a hypothetical
## ship heading.
func _can_gun_bear(gun: Turret, ship_heading: float, threat_bearing: float) -> bool:
	if not gun.rotation_limits_enabled:
		return true  # No limits means 360° traverse

	var arc_min: float = _normalize_0_tau(ship_heading + gun.base_rotation + gun.min_rotation_angle)
	var arc_max: float = _normalize_0_tau(ship_heading + gun.base_rotation + gun.max_rotation_angle)
	var target_angle: float = _normalize_0_tau(threat_bearing)

	if arc_min <= arc_max:
		return target_angle >= arc_min and target_angle <= arc_max
	else:
		return target_angle >= arc_min or target_angle <= arc_max


## Lerp between two angles using the shortest path.
func _lerp_angle(from: float, to: float, weight: float) -> float:
	var diff: float = angle_difference(from, to)
	return from + diff * weight


## Normalise an angle to [0, TAU).
func _normalize_0_tau(a: float) -> float:
	var r: float = fmod(a, TAU)
	if r < 0.0:
		r += TAU
	return r


func reset() -> void:
	_osc_timer = 0.0
