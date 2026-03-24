class_name SkillChase
extends BotSkill

var _chase_target_id: int = -1
var _last_known_pos: Vector3 = Vector3.ZERO
var _last_known_velocity: Vector3 = Vector3.ZERO
var _last_seen_time: float = 0.0
var _chase_started: float = 0.0

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	var chase_timeout = params.get("chase_timeout", 45.0)
	var min_hp = params.get("min_hp_ratio", 0.2)
	var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp
	if hp_ratio < min_hp:
		return null

	# Try to find or update chase target
	var now = Time.get_ticks_msec() / 1000.0
	var spotted = ctx.server.get_valid_targets(ship.team.team_id)
	var unspotted = ctx.server.get_unspotted_enemies(ship.team.team_id)

	# If we have no chase target, pick one from unspotted
	if _chase_target_id == -1:
		var best_dist = INF
		for s in unspotted.keys():
			var pos: Vector3 = unspotted[s]
			var d = pos.distance_to(ship.global_position)
			if d < best_dist:
				best_dist = d
				_chase_target_id = s.get_instance_id() if s is Object else -1
				_last_known_pos = pos
				_last_known_velocity = s.linear_velocity if s is Ship else Vector3.ZERO
				_last_seen_time = now
				_chase_started = now

	if _chase_target_id == -1:
		return null

	# Check if chase target is visible again (update tracking)
	for enemy in spotted:
		if enemy.get_instance_id() == _chase_target_id:
			_last_known_pos = enemy.global_position
			_last_known_velocity = enemy.linear_velocity
			_last_seen_time = now
			break

	# Timeout check
	if now - _last_seen_time > chase_timeout:
		reset()
		return null

	# Predict position
	var time_since = now - _last_seen_time
	var predicted_pos = _last_known_pos + _last_known_velocity * time_since
	predicted_pos.y = 0.0
	predicted_pos = ctx.behavior._get_valid_nav_point(predicted_pos)

	var to_dest = predicted_pos - ship.global_position
	to_dest.y = 0.0
	var heading = atan2(to_dest.x, to_dest.z) if to_dest.length_squared() > 1.0 else ctx.behavior._get_ship_heading()
	var intent = NavIntent.create(predicted_pos, heading)
	intent.throttle_override = 4
	return intent

func reset() -> void:
	_chase_target_id = -1
	_last_known_pos = Vector3.ZERO
	_last_known_velocity = Vector3.ZERO
