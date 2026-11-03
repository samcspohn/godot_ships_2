class_name SearchedWater
extends RefCounted

## One team's recent search: per CELL_M cell, when a friend last had it in sight and from how near (0 inside a
## hydro or radar bubble). A dark enemy is not in a cell searched since it was last seen from nearer than its concealment.

const CELL_M := 1000.0
const BOUNDS := Rect2(-17500, -17500, 35000, 35000)
## Past this a searched cell may have been sailed into again.
const FORGET_S := 90.0
const UPDATE_S := 1.0
## Relocation looks no further than this from the believed point.
const SEARCH_MAX_M := 15000.0

var _w: int
var _h: int
var _t := PackedFloat32Array()
var _d := PackedFloat32Array()
var _next := -INF
## Cell offsets by distance, out to SEARCH_MAX_M.
static var _rings: Array[Vector2i] = []

func _init() -> void:
	_w = ceili(BOUNDS.size.x / CELL_M)
	_h = ceili(BOUNDS.size.y / CELL_M)
	_t.resize(_w * _h)
	_t.fill(-INF)
	_d.resize(_w * _h)
	_d.fill(INF)
	if _rings.is_empty():
		var n: int = ceili(SEARCH_MAX_M / CELL_M)
		for y in range(-n, n + 1):
			for x in range(-n, n + 1):
				if x * x + y * y <= n * n:
					_rings.append(Vector2i(x, y))
		_rings.sort_custom(func(a: Vector2i, b: Vector2i): return a.length_squared() < b.length_squared())

## Stamps what `friends` see now: out to `reach` with line of sight, and inside each one's active hydro or radar.
func update(friends: Array[Ship], reach: float, now: float, vis: VisibilityGrid) -> void:
	if now < _next:
		return
	_next = now + UPDATE_S
	for f in friends:
		if not is_instance_valid(f) or not f.is_alive() or f.concealment == null or f.concealment.params == null:
			continue
		var cp := f.concealment.params.p() as ConcealmentParams
		var sensor: float = maxf(maxf(cp.spotting_range_override, cp.radar_spotting_range_override), 0.0)
		var at := Vector2(f.global_position.x, f.global_position.z)
		var r: float = maxf(reach, sensor)
		var c := _cell(at)
		var n: int = ceili(r / CELL_M)
		for y in range(maxi(c.y - n, 0), mini(c.y + n + 1, _h)):
			for x in range(maxi(c.x - n, 0), mini(c.x + n + 1, _w)):
				var p := _centre(x, y)
				var d: float = at.distance_to(p)
				if d < sensor:
					d = 0.0
				elif d >= reach or (vis != null and vis.is_built() and not vis.visible(at, p)):
					continue
				var k: int = y * _w + x
				_d[k] = d if now - _t[k] > FORGET_S else minf(_d[k], d)
				_t[k] = now

## A hider of concealment `conceal` would have been found at `p` by a search since `since`.
func cleared(p: Vector2, conceal: float, since: float, now: float) -> bool:
	var c := _cell(p)
	if c.x < 0 or c.y < 0 or c.x >= _w or c.y >= _h:
		return false
	var k: int = c.y * _w + c.x
	return _t[k] > since and now - _t[k] <= FORGET_S and _d[k] < conceal

## `p`, or the nearest water to it no search since `since` has cleared of such a hider.
func relocate(p: Vector2, conceal: float, since: float, now: float) -> Vector2:
	if not cleared(p, conceal, since, now):
		return p
	var c := _cell(p)
	for o in _rings:
		var x: int = c.x + o.x
		var y: int = c.y + o.y
		if x < 0 or y < 0 or x >= _w or y >= _h:
			continue
		var q := _centre(x, y)
		if not cleared(q, conceal, since, now) and NavigationMapManager.get_distance(Vector3(q.x, 0.0, q.y)) > 0.0:
			return q
	return p

func _cell(p: Vector2) -> Vector2i:
	return Vector2i(floori((p.x - BOUNDS.position.x) / CELL_M), floori((p.y - BOUNDS.position.y) / CELL_M))

func _centre(x: int, y: int) -> Vector2:
	return BOUNDS.position + Vector2(x + 0.5, y + 0.5) * CELL_M
