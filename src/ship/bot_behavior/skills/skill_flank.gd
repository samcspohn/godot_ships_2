class_name SkillFlank
extends BotSkill

const MAP_HALF_WIDTH: float = 17500.0
const CIRCLE_RADIUS: float = MAP_HALF_WIDTH * 0.9  # ~15750

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship

	var enemy_avg = ctx.server.get_enemy_avg_position(ship.team.team_id)
	if enemy_avg == Vector3.ZERO:
		return null

	# Angle of this ship on the perimeter circle (from map center)
	var ship_pos = ship.global_position
	var ship_angle = atan2(ship_pos.x, ship_pos.z)

	# Angle of the enemy average on the perimeter circle (from map center)
	var enemy_angle = atan2(enemy_avg.x, enemy_avg.z)

	# Angular difference, wrapped to [-PI, PI] to find the shortest direction
	var angle_diff = enemy_angle - ship_angle
	while angle_diff > PI:
		angle_diff -= TAU
	while angle_diff < -PI:
		angle_diff += TAU

	# Step 45 degrees along the circle toward the enemy average
	var step = deg_to_rad(params.get("flank_angle_deg", 45.0)) * sign(angle_diff)
	var target_angle = ship_angle + step

	# Target point on the perimeter circle
	var flank_pos = Vector3(sin(target_angle), 0.0, cos(target_angle)) * CIRCLE_RADIUS

	flank_pos = ctx.behavior._get_valid_nav_point(flank_pos)

	var to_dest = flank_pos - ship_pos
	to_dest.y = 0.0

	# Face toward enemy avg from the flank position
	var to_enemy = enemy_avg - flank_pos
	to_enemy.y = 0.0
	var heading = atan2(to_enemy.x, to_enemy.z) if to_enemy.length_squared() > 1.0 else ctx.behavior._get_ship_heading()

	return NavIntent.create(flank_pos, heading)
