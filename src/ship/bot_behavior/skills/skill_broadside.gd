class_name SkillBroadside
extends BotSkill

## Post-processing skill that finds the heading at which all guns can bear on the
## target, then oscillates between that "broadside" heading and the angle-skill
## heading already present in the incoming NavIntent.
##
## Usage:  intent = _skill_broadside.apply(intent, ctx, params)
##
## The oscillation creates unpredictable heading changes that make the ship
## harder to hit while still cycling between maximum firepower (all guns) and
## optimal armor angling.
##
## The ship only swings toward broadside when the turrets have already traversed
## toward the threat — there is no point turning the hull to unmask guns that
## are still pointed the wrong way.

## Oscillation timer — drives the blend between broadside and angled heading.
var _osc_timer: float = 0.0

## How many radians we sample when searching for all-guns headings.
const SAMPLE_STEP: float = deg_to_rad(2.0)

## A gun is considered "aimed toward the broadside side" when its current
## world-space bearing is within this many radians of the threat bearing.
const GUN_AIMED_TOLERANCE: float = deg_to_rad(30.0)

## ---------------------------------------------------------------------------
## Public API — mirrors SkillSpread's apply() pattern
## ---------------------------------------------------------------------------

func apply(intent: NavIntent, ctx: SkillContext, params: Dictionary) -> NavIntent:
	if intent == null:
		return null

	var ship = ctx.ship
	if ship == null or not is_instance_valid(ship):
		return intent

	var target = ctx.target

	# We need a threat position to compute gun bearings against.
	var threat_pos: Vector3 = Vector3.ZERO
	if target != null and is_instance_valid(target):
		threat_pos = target.global_position
	else:
		var spotted_center = ctx.behavior._get_spotted_danger_center()
		threat_pos = spotted_center if spotted_center != Vector3.ZERO else ctx.behavior._get_danger_center()
	if threat_pos == Vector3.ZERO:
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

	# --- Find the broadside heading (all guns can fire) closest to the desired heading ---
	var desired_heading: float = intent.target_heading
	var broadside_heading: float = _find_best_all_guns_heading(guns, threat_bearing, desired_heading)

	# --- Oscillation — period matches gun reload so the ship swings to
	#     broadside roughly once per salvo cycle. ---
	var reload_time: float = ship.artillery_controller.get_params().reload_time
	var osc_period: float = maxf(reload_time, 1.0)  # clamp to avoid zero/tiny periods
	var osc_bias: float = params.get("oscillation_bias", 0.5)  # 0 = pure angle, 1 = pure broadside
	var delta: float = 1.0 / Engine.physics_ticks_per_second
	_osc_timer += delta

	# Sinusoidal blend factor: oscillates between 0 and 1
	var t: float = (sin(_osc_timer * TAU / osc_period) + 1.0) * 0.5  # 0..1
	# Bias shifts the midpoint: higher bias spends more time near broadside
	var blend: float = clampf(t * (1.0 + osc_bias) - osc_bias * 0.5, 0.0, 1.0)

	# --- Gate: only allow oscillation toward broadside when guns are ready ---
	# When blend > 0 the ship wants to swing from desired_heading toward
	# broadside_heading.  Check whether the guns that are NOT currently bearing
	# on the threat (and would be gained by broadside) have at least traversed
	# toward the threat side.  If they haven't, suppress the blend — there is
	# no point turning the hull to unmask guns that are still pointed away.
	if blend > 0.001:
		var ship_heading: float = ctx.behavior._get_ship_heading()
		if not _guns_aimed_toward_broadside(guns, ship_heading, threat_bearing, desired_heading, broadside_heading):
			blend = 0.0

	# Blend between the angle heading (from kite/angle/camp) and broadside
	var final_heading: float = _lerp_angle(desired_heading, broadside_heading, blend)

	# Rotate the destination around the ship so the navigator actually steers
	# toward the new heading.  Skills like kite/angle place the destination
	# along the heading vector, so just changing target_heading alone won't
	# move the rudder — we must swing the destination by the same delta.
	var heading_delta: float = angle_difference(desired_heading, final_heading)
	if absf(heading_delta) > 0.001:
		var ship_pos: Vector3 = ship.global_position
		var offset: Vector3 = intent.target_position - ship_pos
		offset.y = 0.0
		var cos_d: float = cos(heading_delta)
		var sin_d: float = sin(heading_delta)
		# Rotate offset around Y axis (XZ plane) by heading_delta
		var rotated_offset := Vector3(
			offset.x * cos_d + offset.z * sin_d,
			0.0,
			-offset.x * sin_d + offset.z * cos_d
		)
		intent.target_position = ship_pos + rotated_offset
		intent.target_position.y = 0.0
		intent.target_position = ctx.behavior._get_valid_nav_point(intent.target_position)

	intent.target_heading = final_heading

	return intent


## ---------------------------------------------------------------------------
## Internals
## ---------------------------------------------------------------------------

## Check whether guns that would be *gained* by swinging to broadside have
## already traversed toward the threat.
##
## We look at every gun that can't currently fire at the threat (at the
## desired/angled heading) but could fire at broadside heading.  For the swing
## to be worthwhile, those guns should already be rotated toward the threat
## bearing — otherwise we'd turn the hull for guns that aren't ready.
##
## Returns true if we should allow the oscillation, false to suppress it.
func _guns_aimed_toward_broadside(guns: Array, ship_heading: float, threat_bearing: float, desired_heading: float, broadside_heading: float) -> bool:
	var dominated_count: int = 0   # guns that would be gained by broadside
	var aimed_count: int = 0       # of those, how many are traversed toward the threat

	for gun in guns:
		var can_at_desired: bool = _can_gun_bear(gun, desired_heading, threat_bearing)
		var can_at_broadside: bool = _can_gun_bear(gun, broadside_heading, threat_bearing)

		if can_at_broadside and not can_at_desired:
			# This gun would be gained by swinging to broadside
			dominated_count += 1

			# Check if this gun is currently aimed toward the threat bearing.
			# gun.rotation.y is the turret's local rotation; add ship heading
			# and base_rotation to get world-space aim direction.
			var gun_world_aim: float = _normalize_0_tau(ship_heading + gun.base_rotation + gun.rotation.y)
			var aim_diff: float = absf(angle_difference(gun_world_aim, threat_bearing))
			if aim_diff <= GUN_AIMED_TOLERANCE:
				aimed_count += 1

	# If no guns would be gained, broadside = desired — allow it (no-op blend).
	if dominated_count == 0:
		return true

	# Require at least half the to-be-gained guns to be aimed toward the threat.
	return aimed_count >= ceili(dominated_count * 0.5)


## Find the ship heading (world-space) at which all guns can bear on the threat,
## choosing the one closest to `preferred_heading`.
##
## Approach: for each candidate ship heading we check whether every turret's
## firing arc (in world space) contains the threat bearing.  We sample headings
## around the full circle and return the valid one nearest to the preferred
## heading.  If no heading allows all guns, we fall back to the heading that
## maximises the number of guns that can fire.
func _find_best_all_guns_heading(guns: Array, threat_bearing: float, preferred_heading: float) -> float:
	var best_heading: float = preferred_heading
	var best_diff: float = PI * 2.0
	var best_gun_count: int = -1

	# We want to check: "if the ship were facing `candidate_heading`, how many
	# guns could bear on `threat_bearing`?"
	#
	# A turret's world-space firing arc when the ship faces heading h:
	#   world_min = h + base_rotation + min_rotation_angle
	#   world_max = h + base_rotation + max_rotation_angle
	# The turret can fire if threat_bearing (normalised to [0, TAU]) falls
	# inside [world_min, world_max] (with wrapping).

	var step_count: int = int(TAU / SAMPLE_STEP)

	for i in step_count:
		var candidate: float = -PI + i * SAMPLE_STEP  # sample -PI .. +PI
		var guns_bearing: int = _count_guns_bearing(guns, candidate, threat_bearing)

		var diff: float = absf(angle_difference(preferred_heading, candidate))

		if guns_bearing > best_gun_count or (guns_bearing == best_gun_count and diff < best_diff):
			best_gun_count = guns_bearing
			best_diff = diff
			best_heading = candidate

	# If we found a heading where ALL guns fire, great.
	# Otherwise we still return the best we found (maximises gun count while
	# being close to preferred heading).
	return best_heading


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

	# Turret's world-space arc boundaries when ship faces `ship_heading`.
	# base_rotation is the turret's resting orientation relative to the ship.
	var arc_min: float = _normalize_0_tau(ship_heading + gun.base_rotation + gun.min_rotation_angle)
	var arc_max: float = _normalize_0_tau(ship_heading + gun.base_rotation + gun.max_rotation_angle)
	var target_angle: float = _normalize_0_tau(threat_bearing)

	if arc_min <= arc_max:
		return target_angle >= arc_min and target_angle <= arc_max
	else:
		# Wrapping arc
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
