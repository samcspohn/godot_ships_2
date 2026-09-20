class_name SkillKite
extends SkillStation

## Fighting retreat as a station search: the best cell at least kite_open_m
## further from the danger centre than the ship, with something still in
## reach, ranked on who can shoot it and how wide the shooters sit. Each
## arrival invalidates the held cell (it no longer opens range), so the next
## rescore steps back again for as long as the ladder keeps kiting. Falls
## back to the directional kite when no cell in the box has a target in reach.

func _label() -> String:
	return "Kite"

func _weights(d: BotDoctrine) -> PackedFloat32Array:
	return PackedFloat32Array([d.kite_w_reach, d.kite_w_exposed, d.kite_w_cone,
		d.kite_w_detect, d.kite_w_travel, d.kite_w_range, d.kite_w_escape])

func _max_exposed(_d: BotDoctrine) -> float:
	return INF

func _require_unseen(_d: BotDoctrine) -> bool:
	return false

func _range_band(ctx: SkillContext, d: BotDoctrine, _params: Dictionary) -> Array:
	var danger: Vector3 = ctx.behavior._get_positioning_danger_center()
	if danger == Vector3.ZERO:
		return [0.0, INF]
	var here: Vector3 = ctx.ship.global_position
	danger.y = 0.0
	here.y = 0.0
	return [here.distance_to(danger) + d.kite_open_m, INF]

func _pref_range(_d: BotDoctrine, _gun_range: float, band: Array) -> float:
	return float(band[0]) + 1500.0

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var intent: NavIntent = super.execute(ctx, params)
	if intent != null:
		return intent
	return _directional_kite(ctx, params)

## Open range along the angled away-bearing; the navigator reprojects the
## point every tick so it never goes stale.
func _directional_kite(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship: Ship = ctx.ship
	var heading: float = wrapf(SkillAngle.calc_heading(ctx, params) + PI, -PI, PI)
	var fwd := Vector3(sin(heading), 0.0, cos(heading))
	var dest: Vector3 = ship.global_position + fwd * maxf(3000.0, ship.movement_controller._p().turning_circle_radius * 8.0)
	dest.y = 0.0
	dest = ctx.behavior._get_valid_nav_point(dest)
	var intent := NavIntent.create(dest, heading)
	intent.directional = true
	return intent
