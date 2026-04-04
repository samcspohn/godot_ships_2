class_name SkillFlank
extends BotSkill

var _flank_side: int = 0
var _flank_depth: float = 0.0
var _initialized: bool = false

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	if not _initialized:
		_flank_side = params.get("flank_side", ctx.behavior._flank_side if ctx.behavior._flank_side != 0 else (1 if randf() > 0.5 else -1))
		_flank_depth = params.get("flank_depth", ctx.behavior._flank_depth if ctx.behavior._flank_depth > 0.0 else randf_range(0.2, 0.5))
		_initialized = true

	var enemy_avg = ctx.server.get_enemy_avg_position(ship.team.team_id)
	if enemy_avg == Vector3.ZERO:
		return null

	var gun_range = ship.artillery_controller.get_params()._range
	var engagement_ratio = params.get("engagement_range_ratio", 0.6)
	var flank_angle = deg_to_rad(params.get("flank_angle_deg", 90.0))

	# Enemy facing direction (from their spawn toward center of map)
	ctx.behavior._initialize_spawn_cache()
	var enemy_spawn = ctx.behavior._cached_enemy_spawn
	var friendly_spawn = ctx.behavior._cached_friendly_spawn
	var enemy_facing = (friendly_spawn - enemy_spawn).normalized() if enemy_spawn != Vector3.ZERO and friendly_spawn != Vector3.ZERO else Vector3(0, 0, -1)
	enemy_facing.y = 0.0

	# Flank target: rotate from enemy avg by flank angle, push out to engagement range
	var flank_dir = enemy_facing.rotated(Vector3.UP, _flank_side * flank_angle).normalized()
	var flank_pos = enemy_avg + flank_dir * gun_range * engagement_ratio

	# Push forward by depth
	var depth_push = enemy_facing * _flank_depth * gun_range * 0.5
	flank_pos += depth_push

	# Safety: check friendlies in front
	var min_friendlies = params.get("min_friendlies_in_front", 1)
	var friendly_ships = ctx.server.get_team_ships(ship.team.team_id)
	var friendlies_in_front = 0
	for f in friendly_ships:
		if f == ship:
			continue
		var f_to_enemy = (enemy_avg - f.global_position).length()
		var me_to_enemy = (enemy_avg - ship.global_position).length()
		if f_to_enemy < me_to_enemy:
			friendlies_in_front += 1
	if friendlies_in_front < min_friendlies and ship.global_position.distance_to(enemy_avg) < gun_range:
		return null  # Abort flanking — team collapsed

	flank_pos.y = 0.0
	flank_pos = ctx.behavior._get_valid_nav_point(flank_pos)
	var to_dest = flank_pos - ship.global_position
	to_dest.y = 0.0
	var heading = atan2(to_dest.x, to_dest.z) if to_dest.length_squared() > 1.0 else ctx.behavior._get_ship_heading()
	return NavIntent.create(flank_pos, heading)

func reset() -> void:
	_initialized = false
