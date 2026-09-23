class_name SkillSpot
extends SkillUtility

## Go and make vision: the utility search weighted for reveal, with close
## pulling toward the launch band (params.launch_range) when the hull has one.
## Declines when the team believes in no enemy at all, so the idle chain can
## run Hunt.

## Kept for DDBehavior.engagement_range and _is_gunboat, which band on it.
const SAFE_MARGIN := 1.15

## False when no station was found, so DDBehavior knows stealth routing has
## no reachable goal.
var stealth_corridor: bool = true

func _label() -> String:
	return "Spot"

func reset() -> void:
	super()
	stealth_corridor = true

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var field: ReachField = NavigationMapManager.get_reach_field()
	if field == null or not field.is_built() or ctx.ship.team == null \
			or field.get_team_enemy_ids(ctx.ship.team.team_id).is_empty():
		_drop()
		stealth_corridor = false
		return null
	var intent := super(ctx, params)
	stealth_corridor = intent != null
	return intent

func _extra_opts(ctx: SkillContext, field: ReachField, team_id: int, g: Dictionary) -> Dictionary:
	var d: BotDoctrine = ctx.behavior.doctrine()
	var o: Dictionary = ctx.behavior.reach_utility_opts(field, team_id, g)
	o["w_reach"] = d.spot_w_reach
	o["w_reveal"] = d.spot_w_reveal
	o["w_close"] = d.spot_w_close
	var launch: float = float(_params.get("launch_range", 0.0))
	o["close_range"] = launch if launch > 0.0 else float(g.range) * d.station_range_ratio
	return o
