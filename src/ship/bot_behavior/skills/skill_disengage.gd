class_name SkillDisengage
extends BotSkill

## Getting out: the nearest safe cell SkillCover DEFENSE finds, toward where the
## ship was headed (else within CONE of the threat axis), behind an island or,
## while going dark still works, in dark water; else a fighting retreat on the
## angled away-heading. Stance decides whether the hull turns or backs out.
## Params: cant_go_dark.

## Without a destination to head toward, cover is searched within this of the threat axis, toward or away.
const CONE: float = deg_to_rad(40.0)
const KITE_DISTANCE_M: float = 3000.0
const KITE_TURNS: float = 8.0

enum Leg { NONE, COVER, DARK, KITE }

var leg: int = Leg.NONE
## The threat axis the cone was cut on; INF without one.
var cone_axis: float = INF
var _cover := SkillCover.new()

func reset() -> void:
	_cover.reset()
	leg = Leg.NONE

func debug_text() -> String:
	return ["Disengage: none", "Disengage: island", "Disengage: dark", "Disengage: kite"][leg]

## Whether the leg run now hides us, so the guns should stay quiet.
func wants_concealment() -> bool:
	return leg == Leg.DARK or (leg == Leg.COVER and _cover.wants_concealment())

func cover() -> SkillCover:
	return _cover

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var cant_go_dark: bool = params.get("cant_go_dark", false)
	cone_axis = _threat_axis(ctx)
	_cover.seed = ctx.behavior._skill_hold.fresh_seed()
	var dive := _cover.execute(ctx, {"mode": SkillCover.Mode.DEFENSE, "fire_en_route": cant_go_dark,
		"allow_dark": not cant_go_dark, "cone_axis": cone_axis, "cone_half": CONE})
	if dive != null:
		leg = Leg.DARK if _cover.is_dark() else Leg.COVER
		return dive
	leg = Leg.KITE
	return _kite(ctx, params)

## Stance's fire axis, else the bearing of the priority.
static func _threat_axis(ctx: SkillContext) -> float:
	var axis: float = ctx.behavior._skill_stance.threat_axis()
	if is_finite(axis):
		return axis
	var pp: Vector3 = ctx.behavior.priority_point()
	if not pp.is_finite():
		return INF
	var to: Vector3 = pp - ctx.ship.global_position
	return atan2(to.x, to.z)

## The angled away-heading, reprojected every tick.
func _kite(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship: Ship = ctx.ship
	var heading: float = wrapf(SkillAngle.calc_heading(ctx, params) + PI, -PI, PI)
	var reach: float = maxf(KITE_DISTANCE_M, ship.movement_controller._p().turning_circle_radius * KITE_TURNS)
	var dest: Vector3 = ship.global_position + Vector3(sin(heading), 0.0, cos(heading)) * reach
	dest.y = 0.0
	var intent := NavIntent.create(ctx.behavior._get_valid_nav_point(dest), heading)
	intent.directional = true
	return intent
