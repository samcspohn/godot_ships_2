class_name SkillCover
extends SkillPosition

## The nearest cell every threat either cannot see (island shadow, outside its
## radar), cannot shell, or sits a concealment radius from (dark water), found
## by VisibilityGrid.cover_search in the cone toward where the ship was headed
## (the shared hold seed, else cone_axis, else the priority) and the cone away,
## away cells costing AWAY_RATIO times their distance. OFFENSE also needs a
## target in reach (one the guns can aim at, unless none is) and never goes dark: its guns would bloom it.
## Dark water is also at least DARK_MARGIN_M farther from each threat than we are now.
## Only enemies with heavy_guns break a shielded cell. A station lost en route is searched on from.
## Params: mode, cone_axis, cone_half, away_ratio (INF: no away cone), allow_dark, fire_en_route, refs,
## near_pos + near_d (new stations only nearer than near_d to near_pos).
## Enemies that see us clip the search (CLIP_HALF) and drop a held station outside their cones.

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
const DARK_MARGIN_M := 500.0
## A station a shell cannot leave for any target, by an exact ray from where the hull is (the
## search reads 300 m cells), is not taken again for BLOCKED_TTL_S: at once when found, after BLOCKED_S on arrival.
const ARRIVED_M := 200.0
const BLOCKED_S := 5.0
const BLOCKED_TTL_S := 60.0
const VERIFY_TRIES := 3
## Each enemy that sees us clips the search to this either side of its bearing to us: no cover past it.
const CLIP_HALF := deg_to_rad(35.0)
## Our speed to a station, as a share of full, when slower now: we will be under way.
const LEAD_SPEED_FRAC := 0.75

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
var _resume := Vector2.INF
var _blocked: Array = []  # [Vector2, expiry]
var _blocked_since: float = INF

func reset() -> void:
	super()
	_dark = false
	_seen = false
	_searched_ms = -100000
	_targets = {}
	_resume = Vector2.INF

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
	if not (opts.shootable as PackedByteArray).has(1):
		opts = search_opts(ctx, field, team_id, belief, g, params, true)
	var now: float = SimClock.now()
	_blocked = _blocked.filter(func(b: Array) -> bool: return now < float(b[1]))
	opts["exclude"] = PackedVector2Array(_blocked.map(func(b: Array) -> Vector2: return b[0]))
	opts["exclude_r"] = COVER_HOLD_M
	var want: int = _aim_bits(field, team_id, opts) if mode == Mode.OFFENSE else 0
	if _has_station and want != 0:
		var st := Vector2(_station.x, _station.z)
		if here.distance_to(st) > ARRIVED_M or field.reach_mask_exact(team_id, opts.hull_key, here) & want != 0:
			_blocked_since = INF
		else:
			_blocked_since = minf(_blocked_since, now)
			if now - _blocked_since >= BLOCKED_S:
				_block(st, now)
				_drop()
	if _has_station:
		var ev: Dictionary = vis.cover_eval(Vector2(_station.x, _station.z), opts.pos, opts)
		if not _in_clip(here, Vector2(_station.x, _station.z), opts.clip_pos):
			_drop()
		elif not bool(ev.ok):
			_resume = Vector2(_station.x, _station.z)
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
		var from := _resume if _resume.is_finite() else here
		_resume = Vector2.INF
		var axis := _axis(ctx, params, from)
		last_sweep = {"here": from, "axis": axis, "opts": opts, "ms": Time.get_ticks_msec()}
		var r: Dictionary = {}
		for i in VERIFY_TRIES:
			r = vis.cover_search(from, axis, opts.pos, opts)
			if not bool(r.found) or want == 0 or field.reach_mask_exact(team_id, opts.hull_key, r.pos) & want != 0:
				break
			_block(r.pos, now)
			opts.exclude.append(r.pos)
			r = {}
		_cells = int(r.get("cells", 0))
		if bool(r.get("found", false)):
			var p: Vector2 = r.pos
			_adopt(Vector3(p.x, 0.0, p.y), float(r.count), {})
			_dark = bool(r.dark)
			_seen = bool(r.seen)
			_target_at = now
			_targets = {}
			_note_targets(opts.ids, int(r.mask))
			_blocked_since = INF
	if not _has_station:
		return _decline()
	_claim(team_id, ship.get_instance_id(), now_ms)
	var intent := _intent(ctx, field, team_id, params.merged({"jitter_radius": COVER_HOLD_M}))
	intent.free_route = true
	return intent

## Bits, in the reach field's enemy order, of the targets opts counts as shootable.
func _aim_bits(field: ReachField, team_id: int, opts: Dictionary) -> int:
	var order: PackedInt64Array = field.get_team_enemy_ids(team_id)
	var bits := 0
	for i in (opts.ids as PackedInt64Array).size():
		var b: int = order.find(opts.ids[i])
		if opts.shootable[i] == 1 and b >= 0 and b < 63:
			bits |= 1 << b
	return bits

func _block(p: Vector2, now: float) -> void:
	_blocked.append([p, now + BLOCKED_TTL_S])

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
## Targets are what the guns can aim at; with `all_targets`, every contact and reference too.
func search_opts(ctx: SkillContext, field: ReachField, team_id: int, belief: Array[Dictionary], g: Dictionary,
		params: Dictionary, all_targets: bool = false) -> Dictionary:
	var ship: Ship = ctx.ship
	var conceal: float = NavigationMapManager.reach_conceal_radius(ship)
	# Firing on the way, the bloom is what they see us from.
	var seen_from: float = maxf(conceal, float(g.get("range", 0.0))) if params.get("fire_en_route", false) else conceal
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var opts := {"pos": PackedVector2Array(), "det_r": PackedFloat32Array(), "dark_r": PackedFloat32Array(), "los_r": PackedFloat32Array(),
		"spot_r": PackedFloat32Array(), "heavy": PackedByteArray(), "shells": PackedByteArray(), "shootable": PackedByteArray(),
		"ids": PackedInt64Array(), "clip_pos": PackedVector2Array(), "lead": PackedVector2Array()}
	var lit: bool = ship.is_detected()
	for b in belief:
		var e: Ship = b.ship
		var spread: float = b.spread
		var force: float = float(b.force_spot)
		opts.pos.append(b.pos)
		opts.det_r.append(maxf(seen_from - spread, 0.0))
		opts.dark_r.append(here.distance_to(b.pos) + DARK_MARGIN_M)
		opts.los_r.append(maxf(force - spread, 0.0) if force > 0.0 else 0.0)
		opts.spot_r.append(0.0)
		opts.heavy.append(1)
		opts.shells.append(1 if BotBehavior.heavy_guns(e, ship) else 0)
		opts.shootable.append(1 if all_targets or ctx.behavior._aimable(e) else 0)
		opts.ids.append(e.get_instance_id())
		opts.lead.append(Vector2(e.linear_velocity.x, e.linear_velocity.z) if int(b.source) == 0 else Vector2.ZERO)
		if lit and here.distance_to(b.pos) <= maxf(seen_from, force):
			opts.clip_pos.append(b.pos)
	for r in params.get("refs", []):
		opts.pos.append(r.pos)
		opts.det_r.append(0.0)
		opts.dark_r.append(0.0)
		opts.los_r.append(0.0)
		opts.spot_r.append(0.0)
		opts.heavy.append(0)
		opts.shells.append(0)
		opts.shootable.append(1 if all_targets else 0)
		opts.ids.append(int(r.id))
		opts.lead.append(Vector2.ZERO)
	opts.merge({"reach_field": field, "team": team_id, "hull_key": NavigationMapManager.reach_hull_key(g),
		"clearance": ctx.behavior._get_ship_clearance(), "reach_m": REACH_M, "away_ratio": float(params.get("away_ratio", AWAY_RATIO)),
		"cone_half": float(params.get("cone_half", CONE_HALF)), "need": 1 if mode == Mode.OFFENSE else 0,
		"allow_dark": mode == Mode.DEFENSE and bool(params.get("allow_dark", not params.get("fire_en_route", false))),
		"near_pos": params.get("near_pos", Vector2.ZERO), "near_d": float(params.get("near_d", INF)),
		"clip_half": CLIP_HALF, "from": here,
		"speed": maxf(ship.linear_velocity.length(), ship.movement_controller.max_speed * LEAD_SPEED_FRAC)}, true)
	# Offense stations are fought from, not run to ahead of a pursuer.
	if mode != Mode.DEFENSE:
		opts.lead = PackedVector2Array()
	return opts

## Whether `p` is within CLIP_HALF of each seeing enemy's bearing to `from`, as cover_search clips.
static func _in_clip(from: Vector2, p: Vector2, clip_pos: PackedVector2Array) -> bool:
	for c in clip_pos:
		if p.distance_to(c) >= 1.0 and absf(angle_difference((from - c).angle(), (p - c).angle())) > CLIP_HALF:
			return false
	return true

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
