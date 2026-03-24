class_name SkillBroadside
extends BotSkill

var current_arc_direction: int = 0
var arc_direction_timer: float = 0.0
var arc_initialized: bool = false

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship = ctx.ship
	var target = ctx.target
	var gun_range = ship.artillery_controller.get_params()._range
	var hp_ratio = ship.health_controller.current_hp / ship.health_controller.max_hp

	var spotted_center = ctx.behavior._get_spotted_danger_center()
	var danger_center = spotted_center if spotted_center != Vector3.ZERO else ctx.behavior._get_danger_center()
	if danger_center == Vector3.ZERO:
		return null

	var range_ratio = params.get("engagement_range_ratio", 0.60)
	var range_increase = params.get("range_increase_when_damaged", 0.10)
	var min_safe_ratio = params.get("min_safe_distance_ratio", 0.30)
	var flank_bias_h = params.get("flank_bias_healthy", 0.6)
	var flank_bias_d = params.get("flank_bias_damaged", 0.2)

	var engagement_range = (range_ratio + clamp((1.0 - hp_ratio) * range_increase, 0.0, range_increase)) * gun_range
	var min_safe = gun_range * min_safe_ratio
	var flank_bias = lerp(flank_bias_h, flank_bias_d, 1.0 - hp_ratio)

	var desired_pos = ctx.behavior._calculate_tactical_position(engagement_range, min_safe, flank_bias)
	desired_pos = _apply_arc(desired_pos, danger_center, engagement_range, ctx)
	desired_pos = ctx.behavior._get_valid_nav_point(desired_pos)

	# Broadside heading
	var threat_pos = target.global_position if target != null and is_instance_valid(target) else danger_center
	var to_threat = threat_pos - desired_pos
	to_threat.y = 0.0
	var threat_bearing = atan2(to_threat.x, to_threat.z)
	var current_heading = ctx.behavior._get_ship_heading()
	var bow_in = deg_to_rad(params.get("bow_in_offset_deg", 15.0))

	var br = ctx.behavior._normalize_angle(threat_bearing + PI / 2.0)
	var bl = ctx.behavior._normalize_angle(threat_bearing - PI / 2.0)
	var broadside = br if abs(ctx.behavior._normalize_angle(br - current_heading)) <= abs(ctx.behavior._normalize_angle(bl - current_heading)) else bl
	var angle_to_threat = ctx.behavior._normalize_angle(threat_bearing - broadside)
	broadside = ctx.behavior._normalize_angle(broadside + bow_in * sign(angle_to_threat))

	return NavIntent.create(desired_pos, broadside)

func _apply_arc(base_pos: Vector3, danger_center: Vector3, engagement_range: float, ctx: SkillContext) -> Vector3:
	var ship = ctx.ship
	var delta = 1.0 / Engine.physics_ticks_per_second
	var to_me = ship.global_position - danger_center
	to_me.y = 0.0
	var current_angle = atan2(to_me.x, to_me.z)

	var friendly_avg = ctx.server.get_team_avg_position(ship.team.team_id)
	var friendly_angle = current_angle
	if friendly_avg != Vector3.ZERO:
		var tf = friendly_avg - danger_center
		tf.y = 0.0
		friendly_angle = atan2(tf.x, tf.z)

	if not arc_initialized:
		arc_initialized = true
		var atf = ctx.behavior._normalize_angle(friendly_angle - current_angle)
		current_arc_direction = -1 if atf > 0 else 1

	arc_direction_timer += delta
	if arc_direction_timer >= 30.0:
		arc_direction_timer = 0.0
		var atf = ctx.behavior._normalize_angle(friendly_angle - current_angle)
		current_arc_direction = 1 if -sign(atf) > 0 else -1

	var arc_pos = danger_center + Vector3(sin(current_angle + 0.15 * current_arc_direction), 0, cos(current_angle + 0.15 * current_arc_direction)) * engagement_range
	arc_pos.y = 0.0
	return base_pos * 0.7 + arc_pos * 0.3

func reset() -> void:
	arc_initialized = false
	arc_direction_timer = 0.0
	current_arc_direction = 0
