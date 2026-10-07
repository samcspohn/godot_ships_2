class_name SkillGunboat
extends SkillSpot

## SkillSpot's perimeter walk on engagement range instead of detection: the
## boat holds just outside every contact's band, where the hull can hit one.
## It spots as bait: whoever shoots back gives themselves away. Below 0.5
## threat it closes in; above, it holds near 70% of gun range, since threat
## ignores how hard a destroyer is to hit, and only opens out near the top.

const RANGE_FRAC_PUSH := 0.5
const RANGE_FRAC_HOLD := 0.7
const RANGE_FRAC_MAX := 0.99
const HOLD_THREAT := 0.5
## Above HOLD_THREAT the band stays near RANGE_FRAC_HOLD until threat is extreme.
const RANGE_POW := 8.0
const EXIT_STEP_M := 200.0
const EXIT_MAX_STEPS := 100
const EXIT_MARGIN_M := 300.0
## Patrol leg along the band edge, at least, and in turning circles.
const PATROL_STEP_M := 1500.0
const PATROL_STEP_TURNS := 3.0

var band_m: float = 0.0
var _patrol_sign: float = 0.0

func debug_text() -> String:
	if not _has_station:
		return "Gunboat: none"
	return "Gunboat %d | band %.0f m | last walk %d cells" % [_count, band_m, _steps]

func _declines(_ctx: SkillContext) -> bool:
	return false

func reset() -> void:
	super()
	_patrol_sign = 0.0

## Out of any band first, then never still: a boat that reaches its station
## rides the band edge instead of parking, since speed is its armour.
func _shape(intent: NavIntent, ctx: SkillContext, vis: VisibilityGrid, here: Vector2,
		pos: PackedVector2Array, opts: Dictionary) -> void:
	var radii: PackedFloat32Array = opts.det_r
	intent.avoid_origins = pos
	intent.avoid_radii = radii
	var out := _exit_point(here, pos, radii)
	if out != here:
		_point(intent, here, out)
		return
	var tcr: float = ctx.ship.movement_controller._p().turning_circle_radius
	if here.distance_to(Vector2(_station.x, _station.z)) > tcr * 2.0:
		return
	var step: float = maxf(PATROL_STEP_M, tcr * PATROL_STEP_TURNS)
	if _patrol_sign == 0.0:
		var ahead := _patrol_point(here, pos, radii, step) - here
		_patrol_sign = -1.0 if ahead.dot(_flank_dir(ctx)) < 0.0 else 1.0
	for attempt in 2:
		var next := _patrol_point(here, pos, radii, step * _patrol_sign)
		var ev: Dictionary = vis.hold_eval(next, pos, opts)
		if next != here and bool(ev.get("free", false)) and int(ev.get("count", 0)) > 0:
			_station = Vector3(next.x, 0.0, next.y)
			_point(intent, here, next)
			return
		_patrol_sign = -_patrol_sign

static func _point(intent: NavIntent, here: Vector2, to: Vector2) -> void:
	intent.target_position = Vector3(to.x, 0.0, to.y)
	intent.target_heading = atan2(to.x - here.x, to.y - here.y)

## `arc` metres along the edge of the band we ride (the one whose edge is nearest).
static func _patrol_point(here: Vector2, centres: PackedVector2Array, radii: PackedFloat32Array, arc: float) -> Vector2:
	var best := -1
	var best_gap := INF
	for i in centres.size():
		if radii[i] <= 0.0:
			continue
		var gap: float = absf(here.distance_to(centres[i]) - radii[i])
		if gap < best_gap:
			best_gap = gap
			best = i
	if best < 0:
		return here
	var c: Vector2 = centres[best]
	var r: float = maxf(radii[best], here.distance_to(c))
	return c + (here - c).normalized().rotated(arc / r) * r


func _walk_inputs(ctx: SkillContext, field: ReachField, team_id: int, belief: Array[Dictionary]) -> Dictionary:
	var g: Dictionary = NavigationMapManager.reach_gun(ctx.ship)
	if g.is_empty():
		return {}
	var gun_range: float = float(g.range)
	var threat := clampf(ctx.behavior.get_threat_score(ctx), 0.0, 1.0)
	band_m = gun_range * range_frac(threat)
	var pos := PackedVector2Array()
	var band := PackedFloat32Array()
	var reach := PackedFloat32Array()
	var any := PackedByteArray()
	var ids := PackedInt64Array()
	for b in belief:
		pos.append(b.pos)
		band.append(band_m + float(b.spread) if _threatens(b.ship) else 0.0)
		reach.append(gun_range)
		any.append(1)
		ids.append((b.ship as Ship).get_instance_id())
	return {"pos": pos, "opts": {"det_r": band, "spot_r": reach, "shootable": any, "reach_field": field,
		"team": team_id, "hull_key": NavigationMapManager.reach_hull_key(g), "ids": ids, "reach_needs_los": true}}

## A destroyer out front spotting, guns quiet, is a target to close on, not a band to keep out of.
static func _threatens(e: Ship) -> bool:
	return e.ship_class != Ship.ShipClass.DD or (e.concealment != null and e.concealment.bloom_value > 0.0)

static func range_frac(threat: float) -> float:
	if threat < HOLD_THREAT:
		return lerpf(RANGE_FRAC_PUSH, RANGE_FRAC_HOLD, threat / HOLD_THREAT)
	var u := clampf((threat - HOLD_THREAT) / (1.0 - HOLD_THREAT), 0.0, 1.0)
	return RANGE_FRAC_HOLD + (RANGE_FRAC_MAX - RANGE_FRAC_HOLD) * pow(u, RANGE_POW)

## Inside the zones a route cannot be walled, so the way out comes first:
## along the depth-weighted push of every zone holding us, to clear water.
func _exit_point(here: Vector2, centres: PackedVector2Array, radii: PackedFloat32Array) -> Vector2:
	var push := Vector2.ZERO
	for i in centres.size():
		var d: float = here.distance_to(centres[i])
		if radii[i] > 0.0 and d < radii[i]:
			push += (here - centres[i]).normalized() * (radii[i] - d) if d > 1.0 else Vector2.RIGHT * radii[i]
	if push == Vector2.ZERO:
		return here
	var dir := push.normalized()
	var p := here
	for _step in EXIT_MAX_STEPS:
		p += dir * EXIT_STEP_M
		var clear := true
		for i in centres.size():
			if radii[i] > 0.0 and p.distance_to(centres[i]) < radii[i]:
				clear = false
				break
		if clear:
			return p + dir * EXIT_MARGIN_M
	return p
