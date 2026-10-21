class_name SkillCover
extends SkillPosition

## The nearest cell every threat either cannot see (island shadow, outside its
## radar), cannot shell, or sits a concealment radius from (dark water), found
## by VisibilityGrid.cover_search in the cone toward where the ship was headed
## (the shared hold seed, else cone_axis, else the priority) and the cone away,
## away cells costing AWAY_RATIO times their distance. OFFENSE also needs a
## target in reach and never goes dark: its guns would bloom it.
## Params: mode, cone_axis, cone_half, away_ratio (INF: no away cone), allow_dark, fire_en_route, refs.

enum Mode { OFFENSE, DEFENSE }

const REACH_M := 8000.0
const AWAY_RATIO := 2.0
## Each side of the axis a cone covers when the caller gives none.
const CONE_HALF := deg_to_rad(40.0)
const COVER_HOLD_M := 300.0
## A hidden station with nothing to shoot is given up after this long, unless a
## friend can spot for it: one on its targets, or a spotter that has claimed one.
const COVER_BLIND_S := 10.0
## A friend counts as on a target within this many of its concealment radii.
const SPOTTER_REACH := 1.3
const RESEARCH_MS := 1000

var mode: int = Mode.OFFENSE
var _dark: bool = false
## Some threat sees the station and only cannot shell it.
var _seen: bool = false
var _target_at: float = -INF
var _searched_ms: int = -100000
var _cells: int = 0
var _targets: Dictionary = {}  # Ship -> true: what the held station shoots
## The last search's {here, axis, opts, ms}, for the debug overlay.
var last_sweep: Dictionary = {}

func reset() -> void:
	super()
	_dark = false
	_seen = false
	_searched_ms = -100000
	_targets = {}

## Whether the held station keeps us unseen, rather than only out of the fire.
func wants_concealment() -> bool:
	return _has_station and not _seen

## Whether the held station hides us by distance alone, in open water.
func is_dark() -> bool:
	return _has_station and _dark

func debug_text() -> String:
	if not _has_station:
		return "Cover: none | %d cells" % _cells
	return "Cover %s%s | %d cells" % ["off" if mode == Mode.OFFENSE else "def",
		" dark" if _dark else (" shielded" if _seen else " hidden"), _cells]

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
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var opts := search_opts(ctx, field, team_id, belief, g, params)
	var now: float = SimClock.now()
	if _has_station:
		var ev: Dictionary = vis.cover_eval(Vector2(_station.x, _station.z), opts.pos, opts)
		if not bool(ev.ok):
			_drop()
		else:
			_dark = bool(ev.dark)
			_seen = bool(ev.seen)
			if int(ev.count) > 0:
				_target_at = now
				_note_targets(opts.ids, int(ev.mask))
			elif mode == Mode.OFFENSE and now - _target_at >= COVER_BLIND_S and not _spotted_for(ctx, team_id, belief):
				_drop()
	var now_ms: int = SimClock.now_ms()
	if not _has_station and now_ms - _searched_ms >= RESEARCH_MS:
		_searched_ms = now_ms
		var axis := _axis(ctx, params, here)
		last_sweep = {"here": here, "axis": axis, "opts": opts, "ms": Time.get_ticks_msec()}
		var r: Dictionary = vis.cover_search(here, axis, opts.pos, opts)
		_cells = int(r.get("cells", 0))
		if bool(r.found):
			var p: Vector2 = r.pos
			_adopt(Vector3(p.x, 0.0, p.y), float(r.count), {})
			_dark = bool(r.dark)
			_seen = bool(r.seen)
			_target_at = now
			_targets = {}
			_note_targets(opts.ids, int(r.mask))
	if not _has_station:
		return _decline()
	_claim(team_id, ship.get_instance_id(), now_ms)
	return _intent(ctx, field, team_id, params.merged({"jitter_radius": COVER_HOLD_M}))

## Toward where the ship was headed: the shared hold seed, else the caller's axis, else the priority.
func _axis(ctx: SkillContext, params: Dictionary, here: Vector2) -> float:
	if seed.is_finite() and seed.distance_to(here) > COVER_HOLD_M:
		return atan2(seed.x - here.x, seed.y - here.y)
	var axis: float = float(params.get("cone_axis", INF))
	if is_finite(axis):
		return axis
	var pp: Vector3 = ctx.behavior.priority_point()
	return atan2(pp.x - here.x, pp.z - here.y) if pp.is_finite() else INF

## cover_search's opts for this ship now.
func search_opts(ctx: SkillContext, field: ReachField, team_id: int, belief: Array[Dictionary], g: Dictionary,
		params: Dictionary) -> Dictionary:
	var ship: Ship = ctx.ship
	var conceal: float = NavigationMapManager.reach_conceal_radius(ship)
	# Firing on the way, the bloom is what they see us from.
	var seen_from: float = maxf(conceal, float(g.get("range", 0.0))) if params.get("fire_en_route", false) else conceal
	var opts := {"pos": PackedVector2Array(), "det_r": PackedFloat32Array(), "los_r": PackedFloat32Array(),
		"spot_r": PackedFloat32Array(), "heavy": PackedByteArray(), "shootable": PackedByteArray(), "ids": PackedInt64Array()}
	for b in belief:
		var e: Ship = b.ship
		var spread: float = b.spread
		var force: float = float(b.force_spot)
		opts.pos.append(b.pos)
		opts.det_r.append(seen_from + spread)
		opts.los_r.append(force + spread if force > 0.0 else 0.0)
		opts.spot_r.append(0.0)
		opts.heavy.append(1)
		opts.shootable.append(1)
		opts.ids.append(e.get_instance_id())
	for r in params.get("refs", []):
		opts.pos.append(r.pos)
		opts.det_r.append(0.0)
		opts.los_r.append(0.0)
		opts.spot_r.append(0.0)
		opts.heavy.append(0)
		opts.shootable.append(1)
		opts.ids.append(int(r.id))
	opts.merge({"reach_field": field, "team": team_id, "hull_key": NavigationMapManager.reach_hull_key(g),
		"clearance": ctx.behavior._get_ship_clearance(), "reach_m": REACH_M, "away_ratio": float(params.get("away_ratio", AWAY_RATIO)),
		"cone_half": float(params.get("cone_half", CONE_HALF)), "need": 1 if mode == Mode.OFFENSE else 0,
		"allow_dark": mode == Mode.DEFENSE and bool(params.get("allow_dark", not params.get("fire_en_route", false)))}, true)
	return opts

## What this station shoots, so a dark spell can be waited out while a friend can spot it.
func _note_targets(ids: PackedInt64Array, mask: int) -> void:
	for i in mini(ids.size(), 64):
		if mask & (1 << i) != 0 and ids[i] > 0:
			var t := instance_from_id(ids[i]) as Ship
			if t != null:
				_targets[t] = true

func _spotted_for(ctx: SkillContext, team_id: int, belief: Array[Dictionary]) -> bool:
	var now: int = SimClock.now_ms()
	var friends: Array = ctx.server.get_team_ships(team_id)
	for b in belief:
		var t: Ship = b.ship
		if not _targets.has(t) or not is_instance_valid(t):
			continue
		var claimer := SkillSpot.spot_claimer(team_id, t, now)
		if claimer != null and claimer != ctx.ship:
			return true
		var reach: float = t.concealment.get_concealment() * SPOTTER_REACH
		for f: Ship in friends:
			if f != ctx.ship and is_instance_valid(f) and f.is_alive() \
					and Vector2(f.global_position.x, f.global_position.z).distance_squared_to(b.pos) <= reach * reach:
				return true
	return false

func _decline() -> NavIntent:
	_drop()
	return null
