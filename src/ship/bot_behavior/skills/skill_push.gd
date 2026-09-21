class_name SkillPush
extends SkillStation

## The station search with a must-close band: cells nearer the danger centre
## than the hull stands, never inside the threat-equalised engagement range.
## Without a field it runs straight down the bearing instead.
##
## Params: desired_range (the standoff), equalize_threat / equalize_floor
## (override the doctrine's push_equalize_*), line_of_fire (refuse a cell
## the guns cannot reach anything from).

## Standoff smoothing: threat steps, the destination should not.
const EQUALIZE_TAU: float = 2.0
const EQUALIZE_RESUME_GAP: float = 3.0

var _range_ratio: float = 1.0
var _ratio_time: float = -1.0
var _desired: float = 0.0

func reset() -> void:
	super.reset()
	_ratio_time = -1.0

func _label() -> String:
	return "Push"

func _weights(d: BotDoctrine) -> PackedFloat32Array:
	return PackedFloat32Array([d.push_w_reach, d.push_w_exposed, d.push_w_cone,
		d.push_w_detect, d.push_w_travel, d.push_w_range, d.push_w_escape])

func _accepts_no_reach(_ctx: SkillContext, _d: BotDoctrine, params: Dictionary) -> bool:
	return not bool(params.get("line_of_fire", false))

func _max_exposed(d: BotDoctrine) -> float:
	return d.push_max_exposed

func _range_band(ctx: SkillContext, d: BotDoctrine, params: Dictionary, here_dist: float) -> Array:
	_desired = _equalized_range(ctx, params, float(params.get("desired_range", 0.0)))
	if here_dist <= _desired:
		return [0.0, here_dist]
	var step: float = ctx.ship.movement_controller._p().turning_circle_radius * d.push_step_turns
	return [_desired, maxf(here_dist - step, _desired)]

func _pref_range(_ctx: SkillContext, _d: BotDoctrine, _params: Dictionary, _gun_range: float, _band: Array) -> float:
	return _desired

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var intent: NavIntent = super.execute(ctx, params)
	if intent != null:
		return intent
	return _geometric(ctx, params)

## Standoff scaled by threat over push_equalize_threat, floored, and lagged
## by EQUALIZE_TAU; snapped after EQUALIZE_RESUME_GAP away from the skill.
func _equalized_range(ctx: SkillContext, params: Dictionary, desired_range: float) -> float:
	if desired_range <= 0.0:
		return desired_range
	var d: BotDoctrine = ctx.behavior._doc()
	var equalize: float = float(params.get("equalize_threat", d.push_equalize_threat))
	if equalize <= 0.0:
		_ratio_time = -1.0
		return desired_range
	var floor_ratio: float = clampf(float(params.get("equalize_floor", d.push_equalize_floor)), 0.0, 1.0)
	var wanted: float = clampf(ctx.behavior.get_threat_score(ctx) / equalize, floor_ratio, 1.0)
	var now: float = Time.get_ticks_msec() / 1000.0
	if _ratio_time < 0.0 or now - _ratio_time > EQUALIZE_RESUME_GAP:
		_range_ratio = wanted
	else:
		_range_ratio = lerpf(_range_ratio, wanted, clampf((now - _ratio_time) / EQUALIZE_TAU, 0.0, 1.0))
	_ratio_time = now
	return desired_range * _range_ratio

## Field-free push: down the bearing to the danger centre, stopping at the
## standoff from it and from whatever contact the run would reach first.
func _geometric(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship: Ship = ctx.ship
	var danger_center: Vector3 = ctx.behavior._get_spotted_danger_center()
	var confirmed: bool = danger_center != Vector3.ZERO
	if not confirmed:
		if ctx.target == null or not is_instance_valid(ctx.target):
			return null
		danger_center = ctx.target.global_position
	var to_enemy: Vector3 = danger_center - ship.global_position
	to_enemy.y = 0.0
	if to_enemy.length_squared() < 1.0:
		return null
	var bearing := atan2(to_enemy.x, to_enemy.z)
	var heading := bearing
	if confirmed:
		heading = lerp_angle(bearing, SkillAngle.calc_heading(ctx, params), 0.2)
	var desired: float = _equalized_range(ctx, params, float(params.get("desired_range", 0.0)))
	var center_dist: float = to_enemy.length()
	var close_dist: float = maxf(center_dist - desired, 0.0)
	var dir: Vector3 = to_enemy / center_dist
	if desired > 0.0:
		close_dist = minf(close_dist, _standoff_breach(ctx, dir, desired, close_dist))
	var dest: Vector3 = ship.global_position + dir * close_dist
	dest.y = 0.0
	return NavIntent.create(ctx.behavior._get_valid_nav_point(dest), heading)

## How far the run along `dir` goes before it is within `radius` of a known
## contact. A contact already inside the standoff does not constrain it.
func _standoff_breach(ctx: SkillContext, dir: Vector3, radius: float, limit: float) -> float:
	var ship_pos: Vector3 = ctx.ship.global_position
	var team_id: int = ctx.ship.team.team_id
	var r_sq: float = radius * radius
	var out: float = limit
	var positions: Array = []
	for e in ctx.server.get_valid_targets(team_id):
		if is_instance_valid(e):
			positions.append(e.global_position)
	positions.append_array(ctx.server.get_unspotted_enemies(team_id).values())
	for pos in positions:
		var to_contact: Vector3 = (pos as Vector3) - ship_pos
		to_contact.y = 0.0
		var along: float = to_contact.dot(dir)
		if along <= 0.0:
			continue
		var perp_sq: float = maxf(to_contact.length_squared() - along * along, 0.0)
		if perp_sq >= r_sq:
			continue
		var entry: float = along - sqrt(r_sq - perp_sq)
		if entry > 0.0:
			out = minf(out, entry)
	return out
