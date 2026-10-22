class_name SkillFight
extends BotSkill

## The one fighting posture: a station on the enemies' rings in open water
## (FightStation), island cover (SkillCover) or a spotting station (SkillSpot).
## Open water while threat is under DISENGAGE_THREAT or the station's own
## exposure is; otherwise, and when no station is found, spot if our
## concealment beats theirs, else cover, each failing the other; with nothing
## found, fight the presumed, else close on our priority.
## Params: only (run that Mode alone), prefer_cover (OFFENSE cover first), and
## each search's own.

enum Mode { STATION, COVER, SPOT }

## A station judged too exposed is not tried again for this long unless threat falls under REENGAGE_THREAT.
const SHELTER_S := 20.0
## The last STATION or SPOT station seeds the next search this long.
const SEED_TTL_S := 30.0

var mode: int = Mode.STATION
var station := FightStation.new()
var cover := SkillCover.new()
var spot := SkillSpot.new()
var _shelter_until: float = -INF
var _seed := Vector2.INF
var _seed_at: float = -INF

func reset() -> void:
	station.reset()
	cover.reset()
	spot.reset()

func current() -> SkillPosition:
	return [station, cover, spot][mode]

func debug_text() -> String:
	return current().debug_text()

func fresh_seed() -> Vector2:
	return _seed if SimClock.now() - _seed_at <= SEED_TTL_S else Vector2.INF

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var only: int = int(params.get("only", -1))
	if only >= 0:
		return _run(ctx, only, params)
	if bool(params.get("prefer_cover", false)):
		var held := _run(ctx, Mode.COVER, cover_params(ctx, SkillCover.Mode.OFFENSE))
		if held != null:
			return held
	var b: BotBehavior = ctx.behavior
	var threat: float = b.get_threat_score(ctx)
	if not station.resting() and (SimClock.now() >= _shelter_until or threat < BotBehavior.REENGAGE_THREAT):
		var intent := _run(ctx, Mode.STATION, params)
		if intent != null and (threat < BotBehavior.DISENGAGE_THREAT or station.station_threat() < BotBehavior.DISENGAGE_THREAT):
			_shelter_until = -INF
			return intent
		if intent != null:
			_shelter_until = SimClock.now() + SHELTER_S
	var order: Array = [Mode.SPOT, Mode.COVER] if b.conceals_well(ctx) else [Mode.COVER, Mode.SPOT]
	for m in order:
		var intent := _run(ctx, m, cover_params(ctx, SkillCover.Mode.OFFENSE) if m == Mode.COVER else {})
		if intent != null:
			return intent
	# Nothing seen to fight: fight where they are presumed to be, else close on our priority.
	var presumed: NavIntent = null
	if not bool(params.get("presumed", false)):
		presumed = _run(ctx, Mode.STATION, params.merged({"presumed": true}))
	return presumed if presumed != null else _advance(ctx)

## Up to a window toward our priority (an anonymous spawn reference before any is identified).
func _advance(ctx: SkillContext) -> NavIntent:
	var p: Vector3 = ctx.behavior.priority_point()
	if not p.is_finite():
		return null
	var at: Vector3 = ctx.ship.global_position
	var to := Vector3(p.x - at.x, 0.0, p.z - at.z)
	if to.length() < 1.0:
		return null
	var dest: Vector3 = at + to.limit_length(FightStation.WINDOW_M)
	dest.y = 0.0
	return NavIntent.create(ctx.behavior._get_valid_nav_point(dest), atan2(to.x, to.z))

static func cover_params(ctx: SkillContext, cover_mode: int) -> Dictionary:
	return {"mode": cover_mode, "refs": ctx.behavior.cover_refs() if cover_mode == SkillCover.Mode.OFFENSE else [],
		"fire_en_route": ctx.behavior.cant_go_dark}

## Runs one search, resetting the last on a switch so its claim and station go.
func _run(ctx: SkillContext, m: int, params: Dictionary) -> NavIntent:
	if m != mode:
		current().reset()
		mode = m
	var pos := current()
	pos.seed = fresh_seed()
	var intent := pos.execute(ctx, params)
	if m != Mode.COVER and pos.has_station():
		var st: Vector3 = pos.station_position()
		_seed = Vector2(st.x, st.z)
		_seed_at = SimClock.now()
	if intent != null and m == Mode.COVER:
		ctx.behavior.wants_stealth = ctx.behavior.wants_stealth or cover.wants_concealment()
	return intent
