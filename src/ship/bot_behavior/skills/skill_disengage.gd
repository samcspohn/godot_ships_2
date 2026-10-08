class_name SkillDisengage
extends BotSkill

## Getting out, cheapest first: behind an island when hiding there beats going
## dark (SkillCover DEFENSE), else to the nearest cell nobody lights while going
## dark still works, else a fighting retreat on the angled away-heading. Stance
## decides whether the hull turns or backs out. Params: cant_go_dark.

const KITE_DISTANCE_M: float = 3000.0
const KITE_TURNS: float = 8.0

enum Leg { NONE, COVER, DARK, KITE }

var leg: int = Leg.NONE
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
	var dive := _cover.execute(ctx, {"mode": SkillCover.Mode.DEFENSE, "fire_en_route": cant_go_dark})
	var dark: Dictionary = _cover.dark()
	if dive != null and (cant_go_dark or dark.is_empty() or float(_cover.best().score) >= float(dark.score)):
		leg = Leg.COVER
		return dive
	_cover.reset()
	if not cant_go_dark and not dark.is_empty():
		leg = Leg.DARK
		var p: Vector2 = dark.pos
		var to := Vector3(p.x, 0.0, p.y) - ctx.ship.global_position
		return NavIntent.create(Vector3(p.x, 0.0, p.y), atan2(to.x, to.z))
	leg = Leg.KITE
	return _kite(ctx, params)

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
