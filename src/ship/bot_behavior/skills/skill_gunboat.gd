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

var band_m: float = 0.0

func debug_text() -> String:
	if not _has_station:
		return "Gunboat: none"
	return "Gunboat %d | band %.0f m | last walk %d cells" % [_count, band_m, _steps]

func _declines(_ctx: SkillContext) -> bool:
	return false

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
