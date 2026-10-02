class_name SkillCover
extends SkillStation

## Island cover from one Rust sweep (VisibilityGrid.cover_sweep): every cell
## reachable within SWEEP_BOX_M, paid for in time and in the damage lit enemies
## would do along the way at the aspect each step shows, scored on the targets
## it reaches. OFFENSE wants gunnery near engagement range; DEFENSE wants the
## cheapest way out of sight, and reports the cheapest dark cell for Disengage.

enum Mode { OFFENSE, DEFENSE }

const SWEEP_BOX_M := 8000.0
const COVER_HOLD_M := 300.0
const HOLD_S := 60.0
## A new station must beat the held one by this much, in score units.
const SWITCH_MARGIN := 0.1
## A hidden station with nothing to shoot is given up after this long,
## or SPOTTER_WAIT_S while the friend who lit our targets is still on them.
const COVER_BLIND_S := 10.0
const SPOTTER_WAIT_S := 30.0
## The spotter counts as on a target within this many of its concealment radii.
const SPOTTER_REACH := 1.3
const RESWEEP_MS := 1000
## Heavy shooters sink us inside this long even bow- or stern-on.
const HARD_COVER_TTK_S := 120.0

const WEIGHTS := {
	Mode.OFFENSE: {"need": 1, "w_sticky": 0.5, "w_gain": 1.0, "w_risk": 1.0, "w_time": 0.1, "w_range": 0.5, "w_hard": 0.5},
	Mode.DEFENSE: {"need": 0, "w_gain": 0.3, "w_risk": 2.0, "w_time": 0.2, "w_range": 0.0, "w_hard": 0.3},
}

var mode: int = Mode.OFFENSE
var _hard: bool = false
var _score: float = -INF
var _target_at: float = -INF
var _swept_ms: int = -100000
var _dark: Dictionary = {}
var _best: Dictionary = {}
var _cells: int = 0
var _us: int = 0
var _spotted: Dictionary = {}  # target Ship -> friendly Ship that was lighting it

func reset() -> void:
	super()
	_hard = false
	_score = -INF
	_swept_ms = -100000
	_dark = {}
	_best = {}
	_spotted = {}

## Whether the held station hides us, rather than only shielding us from heavy fire.
func wants_concealment() -> bool:
	return _has_station and not _hard

## Cheapest cell no enemy lights, from the last sweep; {} when none.
func dark() -> Dictionary:
	return _dark

## The last sweep's best station, adopted or not; {} when none.
func best() -> Dictionary:
	return _best

func debug_text() -> String:
	if not _has_station:
		return "Cover: none"
	return "Cover %s %.2f%s | %d cells %d us" % ["off" if mode == Mode.OFFENSE else "def", _score,
		" hard" if _hard else "", _cells, _us]

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var m: int = params.get("mode", mode)
	if m != mode:
		reset()
		mode = m
	var vis: VisibilityGrid = NavigationMapManager.get_visibility()
	var field: ReachField = NavigationMapManager.get_reach_field()
	var ship: Ship = ctx.ship
	if vis == null or field == null or not field.is_built() or ship.team == null or ctx.server == null:
		return _decline()
	var team_id: int = ship.team.team_id
	var belief: Array[Dictionary] = ctx.server._team_belief(team_id)
	var g: Dictionary = NavigationMapManager.reach_gun(ship)
	if belief.is_empty() or g.is_empty():
		return _decline()
	var now_ms: int = SimClock.now_ms()
	if now_ms - _swept_ms >= RESWEEP_MS or not _has_station:
		_swept_ms = now_ms
		_sweep(ctx, vis, field, team_id, belief, g, params)
	if not _has_station:
		return _decline()
	_claim(team_id, ship.get_instance_id(), now_ms)
	return _intent(ctx, field, team_id, params.merged({"jitter_radius": COVER_HOLD_M}))

func _sweep(ctx: SkillContext, vis: VisibilityGrid, field: ReachField, team_id: int, belief: Array[Dictionary],
		g: Dictionary, params: Dictionary) -> void:
	var ship: Ship = ctx.ship
	var opts := _inputs(ctx, belief, g, params.get("fire_en_route", mode == Mode.OFFENSE))
	opts.merge(WEIGHTS[mode], true)
	opts.merge({"reach_field": field, "team": team_id, "hull_key": NavigationMapManager.reach_hull_key(g),
		"clearance": ctx.behavior._get_ship_clearance(), "los_margin": 1, "allow_hard": ship.is_detected(),
		"box_m": SWEEP_BOX_M, "speed": ship.movement_controller.max_speed, "my_hp": ship.health_controller.current_hp,
		"gun_range": float(g.get("range", 0.0)), "pref_range": float(params.get("pref_range", 0.0)), "hold_s": HOLD_S,
		"held": Vector2(_station.x, _station.z) if _has_station else Vector2.INF}, true)
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var r: Dictionary = vis.cover_sweep(here, opts.pos, opts)
	_cells = int(r.get("cells", 0))
	_us = int(r.get("us", 0))
	_dark = r.get("dark", {})
	_best = r.get("best", {})
	var held: Dictionary = r.get("held", {})
	var now: float = SimClock.now()
	if _has_station:
		if held.is_empty():
			_drop()
		else:
			_score = float(held.score)
			if int(held.count) > 0:
				_target_at = now
				_note_spotters(opts.ids, int(held.mask))
			elif mode == Mode.OFFENSE and now - _target_at >= _blind_limit(belief):
				_drop()
	if _best.is_empty() or (_has_station and float(_best.score) <= _score + SWITCH_MARGIN):
		return
	var p: Vector2 = _best.pos
	_adopt(Vector3(p.x, 0.0, p.y), float(_best.score), {})
	_score = float(_best.score)
	_hard = bool(_best.hard)
	_target_at = now
	_spotted = {}
	_note_spotters(opts.ids, int(_best.mask))

## Who is lighting each target this station shoots, so a dark spell can be waited out.
func _note_spotters(ids: PackedInt64Array, mask: int) -> void:
	_spotted = {}
	for i in mini(ids.size(), 64):
		if mask & (1 << i) == 0:
			continue
		var t := instance_from_id(ids[i]) as Ship
		if t != null and t.concealment.spotted_by != null:
			_spotted[t] = t.concealment.spotted_by

func _blind_limit(belief: Array[Dictionary]) -> float:
	for b in belief:
		var t: Ship = b.ship
		var spotter: Ship = _spotted.get(t)
		if spotter == null or not is_instance_valid(spotter) or not spotter.is_alive():
			continue
		var reach: float = t.concealment.get_concealment() * SPOTTER_REACH
		var at := Vector2(spotter.global_position.x, spotter.global_position.z)
		if at.distance_squared_to(b.pos) <= reach * reach:
			return SPOTTER_WAIT_S
	return COVER_BLIND_S

## Per belief contact: where it is, what it sees and shoots, and what it is worth.
func _inputs(ctx: SkillContext, belief: Array[Dictionary], g: Dictionary, fire_en_route: bool) -> Dictionary:
	var ship: Ship = ctx.ship
	var conceal: float = NavigationMapManager.reach_conceal_radius(ship)
	var bloom: float = maxf(conceal, float(g.get("range", 0.0)))
	var model := BotGunnery.damage_model(ship)
	var out := {"damage_model": model, "me": ship.get_instance_id(), "pos": PackedVector2Array(),
		"det_r": PackedFloat32Array(), "spot_r": PackedFloat32Array(), "los_r": PackedFloat32Array(),
		"seen_r": PackedFloat32Array(), "prio": PackedFloat32Array(), "shootable": PackedByteArray(),
		"ids": PackedInt64Array(), "heavy": PackedByteArray(), "live": PackedByteArray(), "sticky": PackedByteArray()}
	for b in belief:
		var e: Ship = b.ship
		BotGunnery.damage_model(e)
		var spread: float = b.spread
		var force: float = float(b.force_spot)
		var live: bool = int(b.source) == 0
		out.pos.append(b.pos)
		out.det_r.append(force + spread if force > 0.0 else 0.0)
		out.spot_r.append(0.0)
		out.los_r.append(maxf(bloom, force) + spread)
		out.seen_r.append((bloom if fire_en_route else conceal) + spread)
		out.prio.append(ctx.behavior.get_threat_class_weight(e.ship_class) / maxf(e.health_controller.current_hp, 1.0)
			* float(b.get("weight", 1.0)))
		out.shootable.append(1)
		out.live.append(1 if live else 0)
		out.sticky.append(1 if e.ship_class == Ship.ShipClass.BB else 0)
		out.ids.append(e.get_instance_id())
		out.heavy.append(1 if unangleable(ship, e, Vector2(ship.global_position.x, ship.global_position.z).distance_to(b.pos)) else 0)
	return out

## Bow- or stern-in, whichever the table says hurts less, is the only mitigation.
static func unangleable(ship: Ship, enemy: Ship, range_m: float) -> bool:
	var bow := SkillStance.dps_at(ship, enemy, range_m, 0.0)
	var stern := SkillStance.dps_at(ship, enemy, range_m, 180.0)
	if bow < 0.0 or stern < 0.0:
		return false
	return minf(bow, stern) * HARD_COVER_TTK_S >= ship.health_controller.max_hp

func _decline() -> NavIntent:
	_drop()
	return null
