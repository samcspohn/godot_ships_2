class_name SkillHold
extends BotSkill

## Stopping somewhere worth being: one posture, the mode says what makes a
## position good. SPOT sees targets a friend can shoot from outside detection;
## FIGHT is the firing station on the engagement band (gunboats ask it for a
## radius to ride and a target in sight); COVER hides behind an island. Params: hold
## (the Mode), then the mode's own (SkillSpot, SkillFight, SkillCover).

enum Mode { SPOT, FIGHT, COVER }

var mode: int = Mode.FIGHT
var spot := SkillSpot.new()
var fight := SkillFight.new()
var cover := SkillCover.new()
## The last SPOT or FIGHT station, so switching between them sweeps from where the other left off.
var _seed := Vector2.INF
var _seed_at: float = -INF
const SEED_TTL_S := 30.0

func reset() -> void:
	spot.reset()
	fight.reset()
	cover.reset()

func current() -> SkillPosition:
	return [spot, fight, cover][mode]

func debug_text() -> String:
	return current().debug_text()

## The last SPOT or FIGHT station while it is fresh, else INF: where cover is sought toward.
func fresh_seed() -> Vector2:
	return _seed if SimClock.now() - _seed_at <= SEED_TTL_S else Vector2.INF

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var m: int = params.get("hold", Mode.FIGHT)
	if m != mode:
		current().reset()
		mode = m
	var now: float = SimClock.now()
	var pos := current()
	pos.seed = fresh_seed()
	var intent := pos.execute(ctx, params)
	if m != Mode.COVER and pos.has_station():
		var st: Vector3 = pos.station_position()
		_seed = Vector2(st.x, st.z)
		_seed_at = now
	return intent
