class_name SkillFight
extends BotSkill

## The one fighting posture: a station on the enemies' rings in open water
## (FightStation), island cover (SkillCover) or a spotting station (SkillSpot).
## Open water while threat is under DISENGAGE_THREAT or the station's own
## exposure is, and the run there is survivable; otherwise spot if our
## concealment beats theirs, else cover nearer our priority than we are, each
## failing the other, then the ring station anyway. Under DISENGAGE_THREAT with
## nothing in reach, and when nothing else is found, fight the presumed, else
## close on our priority.
## Whichever search answers, the sailed destination eases from the last one
## toward it at our top speed plus EASE_GAIN_MPS for every second it has held still, never jumping.
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
## Fight not run for longer than this sails straight for its next destination.
const EASE_GAP_S := 1.0
var _shown := Vector2.INF
var _shown_at: float = -INF
const EASE_GAIN_MPS := 0.5
## A goal moving less than this is the same destination.
const EASE_SAME_M := 50.0
var _goal := Vector2.INF
var _goal_since: float = -INF

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

## Disengage's island or dark destination: where Fight's easing resumes from.
func snap_to(p: Vector3) -> void:
	_shown = Vector2(p.x, p.z)
	_shown_at = SimClock.now()
	_goal = Vector2.INF

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var intent := _choose(ctx, params)
	var now: float = SimClock.now()
	var dt: float = now - _shown_at
	_shown_at = now
	if intent == null:
		return null
	var goal := Vector2(intent.target_position.x, intent.target_position.z)
	if not _goal.is_finite() or _goal.distance_to(goal) > EASE_SAME_M:
		_goal_since = now
	_goal = goal
	var speed: float = ctx.ship.movement_controller.max_speed + EASE_GAIN_MPS * (now - _goal_since)
	_shown = goal if not _shown.is_finite() or dt > EASE_GAP_S else _shown.move_toward(goal, speed * maxf(dt, 0.0))
	if _shown.distance_to(goal) > 1.0:
		intent.target_position = ctx.behavior._get_valid_nav_point(Vector3(_shown.x, 0.0, _shown.y))
	return intent

func _choose(ctx: SkillContext, params: Dictionary) -> NavIntent:
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
		if intent != null and not station.doomed() \
				and (threat < BotBehavior.DISENGAGE_THREAT or station.station_threat() < BotBehavior.DISENGAGE_THREAT):
			_shelter_until = -INF
			return intent
		if intent != null:
			_shelter_until = SimClock.now() + SHELTER_S
	# Calm and nothing in reach: close in rather than hide.
	if threat < BotBehavior.DISENGAGE_THREAT and not b._has_shootable_contact(ctx):
		var closing := _close_in(ctx, params)
		if closing != null:
			return closing
	var order: Array = [Mode.SPOT, Mode.COVER] if b.conceals_well(ctx) else [Mode.COVER, Mode.SPOT]
	for m in order:
		var intent := _run(ctx, m, advance_cover_params(ctx) if m == Mode.COVER else {})
		if intent != null:
			return intent
	if not station.resting():
		var held := _run(ctx, Mode.STATION, params)
		if held != null:
			return held
	return _close_in(ctx, params)

## Fight where the enemy is presumed to be, else close on our priority.
func _close_in(ctx: SkillContext, params: Dictionary) -> NavIntent:
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

## OFFENSE cover nearer our priority than we are, or inside the range we want it at.
static func advance_cover_params(ctx: SkillContext) -> Dictionary:
	var p := cover_params(ctx, SkillCover.Mode.OFFENSE)
	var b: BotBehavior = ctx.behavior
	var target: Ship = b.priority_target()
	var at: Vector3 = b.priority_point()
	if not at.is_finite():
		return p
	var to := Vector2(at.x, at.z)
	var near: float = to.distance_to(Vector2(ctx.ship.global_position.x, ctx.ship.global_position.z))
	if is_instance_valid(target):
		near = maxf(near, b.desired(target).x)
	return p.merged({"near_pos": to, "near_d": near})

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
