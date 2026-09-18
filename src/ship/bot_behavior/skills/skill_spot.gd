class_name SkillSpot
extends BotSkill

const SPOT_MARGIN            := 1.0
const SAFE_MARGIN            := 1.15

## Fallback walk along the escape bearing, capped at 2x reach so running out
## still leaves the station on our side of the contacts.
const PUSH_STEP_RATIO := 0.25
const MAX_PUSH_PASSES := 8

const NEARBY_TEAMMATES := 3
const MAX_SPOT_TARGETS := 3
const TEAMMATE_DIST_SCALE := 10000.0
const UNSPOTTED_BONUS := 1.5

## Perimeter march: probe spacing and how far each cursor may walk.
const MARCH_STEP := 400.0
const MAX_MARCH_STEPS := 30
const ENTRY_MAX_STEPS := 60
const PROBE_ANGLES: Array[float] = [90.0, 45.0, 0.0, -45.0, -90.0, -135.0, 180.0]

const RESOLVE_INTERVAL := 2.0

## False when the station is inside the router's threat picture, so DDBehavior
## knows stealth routing has no reachable goal.
var stealth_corridor: bool = true

var _station: Vector3 = Vector3.ZERO
var _next_resolve: float = 0.0

func reset() -> void:
	_station = Vector3.ZERO
	_next_resolve = 0.0

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var ship: Ship = ctx.ship
	var behavior = ctx.behavior
	var ship_pos = ship.global_position
	var danger_center: Vector3 = behavior._get_spotted_danger_center()

	var reach: float = behavior.threat_effective_radius()
	if reach <= 0.0:
		return null

	var fpfc = SkillFlank.flank_position(ctx, ship_pos, 60.0)
	var flank_pos: Vector3 = fpfc[0]
	var friendly_center: Vector3 = fpfc[1]
	if flank_pos == Vector3.ZERO:
		return null

	if friendly_center != Vector3.ZERO \
			and flank_pos.distance_to(friendly_center) > flank_pos.distance_to(danger_center) * 0.75:
		var friendly_to_danger = (friendly_center - danger_center)
		var flank_to_friendly = (flank_pos - friendly_center).normalized()
		flank_pos = flank_to_friendly * friendly_to_danger.length() * 0.75 + friendly_center

	var station := _resolve_station(ctx, danger_center, flank_pos, reach)
	if station == Vector3.ZERO:
		station = _push_clear_of_threats(ctx, danger_center, flank_pos, reach)
	else:
		stealth_corridor = true

	var away_dir = (station - danger_center).normalized()
	var away_heading: float = atan2(away_dir.x, away_dir.z)
	var intent := NavIntent.create(station, away_heading)
	# The station was verified against the router's own blocking; the generic
	# radial push would shove it off its bearing, possibly past the contacts.
	intent.skip_threat_adjustment = true
	return intent


## Walk from the ship to the stamped perimeter, then along it both ways until
## a cursor spots a target. Held while it still spots and stays clear.
func _resolve_station(ctx: SkillContext, danger_center: Vector3, flank_pos: Vector3,
		reach: float) -> Vector3:
	var now: float = Time.get_ticks_msec() / 1000.0
	if now < _next_resolve:
		return _station
	_next_resolve = now + RESOLVE_INTERVAL

	var nav: ShipNavigator = ctx.navigator
	var targets := _spot_targets(ctx)
	if nav == null or targets.is_empty() or danger_center == Vector3.ZERO:
		_station = Vector3.ZERO
		return Vector3.ZERO
	var circles: PackedVector3Array = nav.get_threat_circles()
	if _station != Vector3.ZERO and not _blocked(nav, circles, _station) \
			and _spots(_station, targets):
		return _station

	var ship_pos: Vector3 = ctx.ship.global_position
	var entry := _perimeter_entry(nav, circles, ship_pos, danger_center)
	if entry == Vector2.INF:
		_station = Vector3.ZERO
		return Vector3.ZERO
	if _spots(Vector3(entry.x, 0.0, entry.y), targets):
		_station = Vector3(entry.x, 0.0, entry.y)
		return _station

	var toward := (Vector2(danger_center.x, danger_center.z) - entry).normalized()
	var perp := Vector2(-toward.y, toward.x)
	var flank_dir := entry - Vector2(flank_pos.x, flank_pos.z)
	if flank_dir.dot(perp) > 0.0:
		perp = -perp
	var cursors: Array = [
		{"pos": entry, "dir": perp, "wall": signf(perp.cross(toward)), "done": false},
		{"pos": entry, "dir": -perp, "wall": signf((-perp).cross(toward)), "done": false},
	]
	for _i in MAX_MARCH_STEPS:
		for cur in cursors:
			if cur.done:
				continue
			if not _march(cur, nav, circles):
				cur.done = true
				continue
			var p := Vector3(cur.pos.x, 0.0, cur.pos.y)
			if _spots(p, targets):
				_station = p
				return p
		if cursors[0].done and cursors[1].done:
			break
	_station = Vector3.ZERO
	return Vector3.ZERO


## Last clear probe on the ship-to-danger line before the perimeter, or the
## first clear one outward when the ship already sits inside it.
func _perimeter_entry(nav: ShipNavigator, circles: PackedVector3Array,
		ship_pos: Vector3, danger_center: Vector3) -> Vector2:
	var from := Vector2(ship_pos.x, ship_pos.z)
	var to := Vector2(danger_center.x, danger_center.z)
	var span: float = from.distance_to(to)
	if span < 1.0:
		return Vector2.INF
	var dir := (to - from) / span
	var inside: bool = _blocked(nav, circles, ship_pos)
	if inside:
		for i in range(1, ENTRY_MAX_STEPS + 1):
			var p := from - dir * MARCH_STEP * float(i)
			if not _blocked(nav, circles, Vector3(p.x, 0.0, p.y)):
				return p
		return Vector2.INF
	var last := from
	var steps: int = mini(int(span / MARCH_STEP), ENTRY_MAX_STEPS)
	for i in range(1, steps + 1):
		var p := from + dir * MARCH_STEP * float(i)
		if _blocked(nav, circles, Vector3(p.x, 0.0, p.y)):
			return last
		last = p
	return Vector2.INF


## One wall-following step: prefer turning into the wall, then straight, then
## away, so the cursor hugs the perimeter. False when boxed in.
func _march(cur: Dictionary, nav: ShipNavigator, circles: PackedVector3Array) -> bool:
	var dir: Vector2 = cur.dir
	for deg in PROBE_ANGLES:
		var d: Vector2 = dir.rotated(deg_to_rad(deg) * cur.wall)
		var p: Vector2 = cur.pos + d * MARCH_STEP
		if _blocked(nav, circles, Vector3(p.x, 0.0, p.y)):
			continue
		cur.pos = p
		cur.dir = d
		return true
	return false


## Terrain shadow does not excuse a point inside a circle: the router would
## accept it, but reaching it means crossing the zone, and the contact moves.
static func _blocked(nav: ShipNavigator, circles: PackedVector3Array, p: Vector3) -> bool:
	var p2 := Vector2(p.x, p.z)
	for c in circles:
		if p2.distance_squared_to(Vector2(c.x, c.y)) < c.z * c.z:
			return true
	return nav.is_point_blocked(p2)


func _spots(p: Vector3, targets: Array) -> bool:
	for t in targets:
		if p.distance_to(t.pos) <= t.spot_range \
				and not NavigationMapManager.is_los_blocked(p, t.pos):
			return true
	return false


## Contacts worth eyes: the nearest contact to each of our nearest teammates,
## weighted by how close it sits to them. Entries: {pos, weight, spot_range}.
func _spot_targets(ctx: SkillContext) -> Array:
	var ship: Ship = ctx.ship
	var ship_pos: Vector3 = ship.global_position
	var team_id: int = ship.team.team_id

	var contacts: Array = []
	for e in ctx.server.get_valid_targets(team_id):
		if is_instance_valid(e) and e.is_alive():
			var holder: Ship = e.concealment.spotted_by if e.concealment != null else null
			var held: bool = holder != null and holder != ship and holder.team.team_id == team_id
			contacts.append({"ship": e, "pos": e.global_position, "spotted": true, "held": held})
	var unspotted: Dictionary = ctx.server.get_unspotted_enemies(team_id)
	for e in unspotted.keys():
		if is_instance_valid(e) and e.is_alive():
			contacts.append({"ship": e, "pos": unspotted[e], "spotted": false, "held": false})
	if contacts.is_empty():
		return []

	var friendlies: Array = []
	for f in ctx.server.get_team_ships(team_id):
		if f != ship and is_instance_valid(f) and f.is_alive():
			friendlies.append(f.global_position)
	friendlies.sort_custom(func(a, b): return a.distance_squared_to(ship_pos) < b.distance_squared_to(ship_pos))
	friendlies = friendlies.slice(0, NEARBY_TEAMMATES)
	if friendlies.is_empty():
		friendlies.append(ship_pos)

	# A contact a teammate already holds needs no second pair of eyes.
	var any_free: bool = false
	for c in contacts:
		if not c.held:
			any_free = true
			break

	var weights: Dictionary = {}
	for fpos in friendlies:
		var best_i: int = -1
		var best_d: float = INF
		for i in contacts.size():
			if any_free and contacts[i].held:
				continue
			var d: float = fpos.distance_to(contacts[i].pos)
			if d < best_d:
				best_d = d
				best_i = i
		var w: float = 1.0 / (1.0 + best_d / TEAMMATE_DIST_SCALE)
		if not contacts[best_i].spotted:
			w *= UNSPOTTED_BONUS
		weights[best_i] = weights.get(best_i, 0.0) + w

	var targets: Array = []
	for i in weights.keys():
		var c: Dictionary = contacts[i]
		targets.append({"pos": c.pos, "weight": weights[i], "spot_range": _spot_range(c.ship)})
	targets.sort_custom(func(a, b): return a.weight > b.weight)
	return targets.slice(0, MAX_SPOT_TARGETS)


func _spot_range(enemy: Ship) -> float:
	if enemy.concealment == null or enemy.concealment.params == null:
		return INF
	var cp := enemy.concealment.params.p() as ConcealmentParams
	if cp == null or cp.radius <= 0.0:
		return INF
	return cp.radius


## Slide `pos` out along its bearing from the danger centre to the first probe
## the router does not block. Done here, not via adjust_destination_for_threats,
## because that pushes radially from each circle - with a contact along the
## bearing its exit is the far side of that contact - and ignores terrain and
## cluster granularity.
func _push_clear_of_threats(ctx: SkillContext, danger_center: Vector3,
		pos: Vector3, reach: float) -> Vector3:
	stealth_corridor = true

	var nav: ShipNavigator = ctx.navigator
	if nav == null or nav.get_threat_circle_count() == 0:
		return pos

	var center_2d := Vector2(danger_center.x, danger_center.z)
	var away := Vector2(pos.x, pos.z) - center_2d
	if danger_center == Vector3.ZERO or away.length_squared() < 1.0:
		return pos

	var dir := away.normalized()
	var dist := away.length()
	var step: float = maxf(reach * PUSH_STEP_RATIO, SPOT_MARGIN)
	var circles: PackedVector3Array = nav.get_threat_circles()

	for _pass in MAX_PUSH_PASSES + 1:
		var probe := center_2d + dir * dist
		var probe3 := Vector3(probe.x, pos.y, probe.y)
		if not _blocked(nav, circles, probe3):
			return probe3
		dist += step

	stealth_corridor = false
	return pos
