class_name SkillFlank
extends SkillStation

## The station search banded at the engagement range, out to where the hull
## stands, with a penalty for sitting on the axis from the enemy to the
## friendly centre: the ship slides round to a bearing the line is not
## facing. Without a field it steps 45 deg round the old arc instead.

const MAP_HALF_WIDTH: float = 17500.0
const MIN_RADIUS: float = 2000.0
## Inside this fraction of gun range the flank declines; the fight is on.
const NO_FLANK_RANGE_RATIO: float = 0.5

var _engage: float = 0.0

func _label() -> String:
	return "Flank"

func _weights(d: BotDoctrine) -> PackedFloat32Array:
	return PackedFloat32Array([d.flank_w_reach, d.flank_w_exposed, d.flank_w_cone,
		d.flank_w_detect, d.flank_w_travel, d.flank_w_range, d.flank_w_escape])

func _accepts_no_reach(_ctx: SkillContext, _d: BotDoctrine, _params: Dictionary) -> bool:
	return true

func _max_exposed(d: BotDoctrine) -> float:
	return d.flank_max_exposed

func _flank_weight(d: BotDoctrine) -> float:
	return d.flank_w_axis

func _flank_from(ctx: SkillContext) -> Vector2:
	var ship: Ship = ctx.ship
	var gun_range: float = ship.artillery_controller.get_params()._range
	var sum := Vector2.ZERO
	var n := 0
	for friendly in ctx.server.get_team_ships(ship.team.team_id):
		if friendly == ship or not is_instance_valid(friendly):
			continue
		if friendly.global_position.distance_to(ship.global_position) <= gun_range:
			sum += Vector2(friendly.global_position.x, friendly.global_position.z)
			n += 1
	return sum / float(n) if n > 0 else Vector2.ZERO

func _range_band(ctx: SkillContext, d: BotDoctrine, params: Dictionary, here_dist: float) -> Array:
	var gun_range: float = ctx.ship.artillery_controller.get_params()._range
	if not bool(params.get("allow_close", false)) and here_dist < gun_range * NO_FLANK_RANGE_RATIO:
		return [1.0, 0.0]
	_engage = ctx.behavior.engagement_range(ctx.ship, ctx.behavior.get_threat_score(ctx))
	return [_engage, maxf(_engage * d.flank_band_ratio, minf(here_dist, gun_range))]

func _pref_range(_ctx: SkillContext, _d: BotDoctrine, _params: Dictionary, _gun_range: float, _band: Array) -> float:
	return _engage

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var intent: NavIntent = super.execute(ctx, params)
	if intent != null:
		return intent
	return _geometric(ctx)

func _geometric(ctx: SkillContext) -> NavIntent:
	var ship_pos: Vector3 = ctx.ship.global_position
	var battle_center: Vector3 = ctx.behavior._get_spotted_danger_center()
	var fpfc: Array[Vector3] = flank_position(ctx, ship_pos, 45.0)
	var flank_pos: Vector3 = fpfc[0]
	var friendly_center: Vector3 = fpfc[1]
	if flank_pos == Vector3.ZERO:
		return null
	var to_center := Vector3(ship_pos.x - battle_center.x, 0.0, ship_pos.z - battle_center.z)
	var to_friendly := Vector3(friendly_center.x - battle_center.x, 0.0, friendly_center.z - battle_center.z)
	var side := signf(to_center.x * to_friendly.z - to_center.z * to_friendly.x)
	var target_angle := atan2(to_center.x, to_center.z) + deg_to_rad(45.0) * side
	return NavIntent.create(flank_pos, target_angle + PI * 0.5 * side)

## A point `theta` deg round the circle through `base_pos` about the battle
## centre, stepping away from the friendly centre. [ZERO, ZERO] when too close
## to flank unless allow_close. Also used by SkillSpot.
static func flank_position(ctx: SkillContext, base_pos: Vector3, theta: float,
		allow_close: bool = false) -> Array[Vector3]:
	var ship = ctx.ship
	var ship_pos = base_pos
	var gun_range: float = MAP_HALF_WIDTH
	if ship.artillery_controller != null:
		gun_range = ship.artillery_controller.get_params()._range

	var enemy_pos: Array = []
	var friendly_pos: Array = []
	for friendly in ctx.server.get_team_ships(ship.team.team_id):
		if friendly == ship or not is_instance_valid(friendly):
			continue
		if friendly.global_position.distance_to(ship_pos) <= gun_range:
			friendly_pos.append(friendly.global_position)
	var spotted = ctx.server.get_valid_targets(ship.team.team_id)
	for enemy in spotted:
		if not is_instance_valid(enemy):
			continue
		if enemy.global_position.distance_to(ship_pos) <= gun_range:
			enemy_pos.append(enemy.global_position)
	var unspotted = ctx.server.get_unspotted_enemies(ship.team.team_id)
	for enemy in unspotted.keys():
		var last_pos: Vector3 = unspotted[enemy]
		if last_pos.distance_to(ship_pos) <= gun_range:
			enemy_pos.append(last_pos)
	var battle_center = ctx.behavior._get_spotted_danger_center()

	if not allow_close and battle_center != Vector3.ZERO \
			and ship_pos.distance_to(battle_center) < gun_range * NO_FLANK_RANGE_RATIO:
		return [Vector3.ZERO, Vector3.ZERO]

	var friendly_center: Vector3
	if friendly_pos.is_empty():
		friendly_center = Vector3.ZERO
	else:
		var sum = Vector3.ZERO
		for p in friendly_pos:
			sum += p
		friendly_center = sum / float(friendly_pos.size())
	battle_center.y = 0.0

	var target = ctx.target
	if target != null and is_instance_valid(target):
		var dist_to_center = ship_pos.distance_to(battle_center)
		var dist_to_target = ship_pos.distance_to(target.global_position)
		if dist_to_center > 0.0:
			battle_center = battle_center.lerp(target.global_position, clamp(1.0 - dist_to_target / dist_to_center, 0.0, 1.0))

	var to_center = Vector3(ship_pos.x - battle_center.x, 0.0, ship_pos.z - battle_center.z)
	var dynamic_radius = max(to_center.length(), MIN_RADIUS)
	if not (spotted.size() == 0 and unspotted.size() == 0):
		dynamic_radius *= pow(float(enemy_pos.size()) / 12.0, 0.5)

	var to_friendly_from_center = Vector3(friendly_center.x - battle_center.x, 0.0, friendly_center.z - battle_center.z)
	var side = sign(to_center.x * to_friendly_from_center.z - to_center.z * to_friendly_from_center.x)
	var step = deg_to_rad(theta)
	var ship_angle = atan2(to_center.x, to_center.z)
	var target_angle = ship_angle + step * side
	var flank_pos = battle_center + Vector3(sin(target_angle), 0.0, cos(target_angle)) * dynamic_radius
	return [flank_pos, friendly_center]
