class_name SkillCamp
extends BotSkill

## Locked camping position — only updated when the new desired position
## differs by more than _relock_distance from the current lock.
var _locked_position: Vector3 = Vector3.ZERO
# var _locked_heading: float = 0.0
var _has_lock: bool = false

## Distance threshold (meters) before we accept a new camping position.
## Keeps the navigator stable so it can settle into heading-alignment.
const RELOCK_DISTANCE: float = 500.0

## Clear the position lock — call when switching away from camp so the next
## activation picks a fresh position instead of reusing a stale one.
func reset() -> void:
	_locked_position = Vector3.ZERO
	_has_lock = false

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	var gun_range = ship.artillery_controller.get_params()._range
	var range_ratio = params.get("desired_range_ratio", 0.65)
	var jitter = params.get("jitter_radius", 500.0)
	var focus_threshold = params.get("focus_threshold", 3)
	var here = params.get("here", true)

	var danger_center = ctx.behavior._get_spotted_danger_center()
	if danger_center == Vector3.ZERO:
		danger_center = ctx.behavior._get_danger_center()
	if danger_center == Vector3.ZERO:
		return null

	var to_danger = danger_center - ship.global_position
	to_danger.y = 0.0
	var desired_range = gun_range * range_ratio
	var current_dist = to_danger.length()

	# Compute the "ideal" camping position this frame.
	var candidate_pos: Vector3
	# if current_dist > desired_range * 1.1:
		# Push toward enemy to get in range
	candidate_pos = ship.global_position + to_danger.normalized() * (current_dist - desired_range)
	# else:
	# 	# Already in range — ideal spot is right where we are
	# 	candidate_pos = ship.global_position

	candidate_pos.y = 0.0
	candidate_pos = ctx.behavior._get_valid_nav_point(candidate_pos)

	# --- Position lock logic ---
	# Only update the locked position when:
	#   1. We don't have a lock yet, OR
	#   2. The candidate moved more than RELOCK_DISTANCE from our current lock
	#      (enemy fleet shifted significantly, or we need to close range)
	if not _has_lock:
		_locked_position = candidate_pos
		_has_lock = true
	else:
		var lock_drift = candidate_pos.distance_to(_locked_position)
		if lock_drift > RELOCK_DISTANCE:
			_locked_position = candidate_pos

	## TODO: implement lock/aim/potential damage based focus detection
	## Focus check: count enemies with LOS in gun range
	#var enemies_in_range = 0
	#for enemy in ctx.server.get_valid_targets(ship.team.team_id):
		#if enemy.global_position.distance_to(ship.global_position) <= gun_range:
			#enemies_in_range += 1
	#if enemies_in_range >= focus_threshold:
		#return null  # Signal caller to switch to Kite/Retreat

	# Heading: always angle toward the current danger center (updates every frame
	# so turrets track the enemy even while the position is locked).
	var to_danger_now = danger_center - _locked_position
	to_danger_now.y = 0.0
	var heading = SkillAngle.calc_heading(atan2(to_danger_now.x, to_danger_now.z), ctx, params)

	# If the heading is more than 90° off our current heading, flip it so we
	# present the stern angle instead of executing a large turn while camping.
	# var current_heading = ship.rotation.y
	var current_heading = ctx.behavior._get_ship_heading()
	if absf(angle_difference(current_heading, heading)) > PI / 2.0:
		heading = ctx.behavior._normalize_angle(heading + PI)

	if here:
		return NavIntent.create(ship.global_position, heading, jitter)

	return NavIntent.create(_locked_position, heading, jitter)
