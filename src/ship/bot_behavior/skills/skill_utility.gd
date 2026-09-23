class_name SkillUtility
extends SkillStation

## The single-objective search (ReachField.score_utility): value from reach
## and reveal against the cell's threat score and the transit risk. Rides the
## station base for the plan, claims, hysteresis, shore refinement and the
## hold intent. Tried first by the ladder when doctrine.utility_first is set.

## Per-call overrides of the doctrine's utility weights: w_reach, w_reveal,
## w_close, w_threat, close_range.
const OVERRIDE_KEYS: Array[String] = ["w_reach", "w_reveal", "w_close", "w_threat", "close_range"]

var _params: Dictionary = {}

func _label() -> String:
	return "Utility"

func _accepts_no_reach(_ctx: SkillContext, _d: BotDoctrine, _params: Dictionary) -> bool:
	return true

func _claim_separation(d: BotDoctrine, _clearance: float) -> float:
	return d.utility_claim_separation

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	_params = params
	return super(ctx, params)

func _extra_opts(ctx: SkillContext, field: ReachField, team_id: int, g: Dictionary) -> Dictionary:
	var o: Dictionary = ctx.behavior.reach_utility_opts(field, team_id, g)
	for k in OVERRIDE_KEYS:
		if _params.has(k):
			o[k] = float(_params[k])
	return o

func _search(field: ReachField, team_id: int, id: int, key: int, opts: Dictionary) -> Dictionary:
	return field.score_utility(team_id, id, key, opts)

func _score_at(field: ReachField, team_id: int, id: int, key: int, opts: Dictionary, point: Vector2) -> Dictionary:
	return field.utility_score_at(team_id, id, key, opts, point)

func debug_text() -> String:
	if not _has_station:
		return "Utility: none"
	return "%s %.2f%s | threat %.2f = %.1f units (%d shooters) reach %.1f reveal %.1f close %.2f risk %.0f | plan %.1f ms score %.1f ms" % [
		_label(), _station_score, " shore" if _refined else "",
		float(_terms.get("threat", 0.0)), float(_terms.get("pressure", 0.0)),
		int(_terms.get("shooters", 0)),
		float(_terms.get("reach", 0.0)), float(_terms.get("reveal", 0.0)), float(_terms.get("close", 0.0)),
		float(_terms.get("risk", 0.0)), _plan_us / 1000.0, _score_us / 1000.0]
