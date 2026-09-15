class_name BotGunnery
extends RefCounted

## Shell and aim-point solver for bots.
##
## The armour walk is shooter-independent: per (target hull, shell, aspect,
## range) a lattice of impact points over the presented silhouette is walked
## natively and each cell stores the HitResult code. A shooter's dispersion,
## TargetMod, rate of fire and citadel guarantee are applied at lookup by
## integrating the lattice under the gun's kernel (_ProjectileManager.lattice_score).
## Finished lattices are persisted under user://gunnery_cache/.

const DMG_CITADEL: float = 1.0
const DMG_CITADEL_OVERPEN: float = 0.5
const DMG_PENETRATION: float = 1.0 / 3.0
const DMG_PARTIAL_PEN: float = 0.0667
const DMG_OVERPENETRATION: float = 0.1
const DMG_TURRET: float = DMG_CITADEL * 0.1
const FIRE_VALUE_PER_FIRE: float = 0.06

const SOLVER_VERSION: int = 1
const CACHE_DIR: String = "user://gunnery_cache/"
const NATIVE_LIB: String = "res://bin/libships_core_rs.linux.x86_64.so"

const CELL_MISS: int = 0xFF
const CELL_UNWALKED: int = 0xFE
const CELL_TURRET: int = 0x10
const CELL_CODE_MASK: int = 0x0F

## Aspect buckets: geometric from bow-on, capped, mirrored about the beam.
const ASPECT_BUCKET_DEG: float = 15.0
const ASPECT_BUCKET_RATIO: float = 1.5
const ASPECT_FLOOR_DEG: float = 5.0

## Range buckets: geometric until the step hits the cap, flat after.
const RANGE_BUCKET_RATIO: float = 1.5
const RANGE_BUCKET_M: float = 2000.0
const RANGE_FLOOR_M: float = 50.0
const RANGE_TOP_M: float = 30000.0

const KIND_MAIN: int = 0
const KIND_SECONDARY: int = 1

const SEC_RANGE_BUCKET_M: float = 1000.0
const SEC_RANGE_FLOOR_M: float = 50.0
const SEC_RANGE_TOP_M: float = 12000.0

const KEY_KIND: int = 0
const KEY_SHOOTER: int = 1
const KEY_TARGET: int = 2
const KEY_ASPECT: int = 3
const KEY_RANGE: int = 4

## Consecutive range buckets whose trajectories are this alike share a lattice.
const RANGE_MERGE_MIN_RATIO: float = 0.8
const FALL_MERGE_DEG: float = 2.5
const SPEED_MERGE_FRAC: float = 0.04

## Lattice sizing: about this many cells, shaped to the silhouette.
const LATTICE_CELLS: int = 192
const LATTICE_MIN: int = 4
const LATTICE_MAX: int = 48
const GUN_HEIGHT_M: float = 5.0

## Walk budget per physics tick.
const CELLS_PER_BUCKET_PER_TICK: int = 24
const WALKS_PER_TICK_CAP: int = 200
const ACTIVE_WINDOW_FRAMES: int = 1
const ANSWER_REFRESH_FRAMES: int = 4
const ANSWER_TTL_FRAMES: int = 64

## DispersionCalculator: 3 of 4 salvos apply the guarantee to 1 of 3 shells.
const CITADEL_GUARANTEE_FRAC: float = 0.25
const CITADEL_ELLIPSE := Vector2(0.4, 0.1)

## Aim candidates as fractions of length, half-beam (toward shooter) and freeboard.
const HULL_STATIONS := [
	[0.0, [0.95]],
	[-0.25, [0.0, 0.55, 0.95]],
	[0.25, [0.0, 0.55, 0.95]],
	[-0.4, [0.0]],
	[0.4, [0.0]],
]
const HULL_HEIGHT_FRACS := [0.05, 0.50, 0.9]
const SUPER_ALONG_FRACS := [0.2, 0.5, 0.8]
const SUPER_HEIGHT_FRACS := [0.1, 0.6]
const SUPER_LATERAL_FRACS := [0.0, 0.6]

## slab id -> {"id", "buckets": {bkey -> bucket}, "dirty"}. A bucket is
## {"nx","ny","rect": Vector4,"dir": Vector3 (local arrival),"cells",
##  "walked","done","kind","aspect","range", + "points"/"order" while open}.
static var _slabs: Dictionary = {}
## [slab id, bkey] -> {"frame","target","owner","shell","bucket","slab"}
static var _active: Dictionary = {}
## bucket key -> {"mounts","mounts_frame","walked","scored_frame","best"}
static var _answers: Dictionary = {}
static var _hull_ids: Dictionary = {}
static var _shell_hashes: Dictionary = {}
static var _range_remap: Dictionary = {}
static var _budget_frame: int = -1
static var _lib_stamp_cache: int = -1
static var _payout_table := PackedFloat64Array()

static var _survey_space: RID = RID()
static var _survey_obbs: Dictionary = {}
static var _survey_shapes: Array = []
static var _native_pm: Object = null

static var _range_edge_cache: Dictionary = {}
static var _aspect_edge_cache: PackedFloat64Array = PackedFloat64Array()

## [kind, target id] -> {"ammo"}; per bot, committed only off a finished answer.
var _committed: Dictionary = {}


func solve(shooter: Ship, target: Ship) -> Dictionary:
	return _solve(shooter, target, KIND_MAIN)


func solve_secondary(shooter: Ship, target: Ship) -> Dictionary:
	return _solve(shooter, target, KIND_SECONDARY)


func _solve(shooter: Ship, target: Ship, kind: int) -> Dictionary:
	if not is_instance_valid(shooter) or not is_instance_valid(target):
		return {}
	var key := _bucket_key(shooter, target, kind)
	if key.is_empty():
		return {}
	_service_frame()
	var ans := _answer(key, shooter, target)
	var ck := [kind, target.get_instance_id()]
	if ans.is_empty():
		var held = _committed.get(ck, {})
		return {
			"offset": aim_hint(target),
			"ammo": int(held.get("ammo", _loaded_shell(shooter, kind))),
			"probed": false,
			"walked": false,
		}
	var complete: bool = ans["complete"]
	if complete:
		_committed[ck] = {"ammo": int(ans["ammo"])}
	var commitment = _committed.get(ck, {})
	var offset: Vector3 = ans["offset"]
	if _shooter_side(shooter, target) < 0.0:
		offset.x = -offset.x
	return {
		"offset": offset,
		"ammo": int(commitment.get("ammo", ans["ammo"])),
		"probed": complete,
		"walked": true,
	}


static func _projectile_native() -> Object:
	if _native_pm == null or not is_instance_valid(_native_pm):
		_native_pm = ProjectileManager.get_raw() if ProjectileManager != null else null
	return _native_pm


static func _payouts() -> PackedFloat64Array:
	if _payout_table.is_empty():
		_payout_table.resize(16)
		_payout_table[NativeArmorInteraction.CITADEL] = DMG_CITADEL
		_payout_table[NativeArmorInteraction.CITADEL_OVERPEN] = DMG_CITADEL_OVERPEN
		_payout_table[NativeArmorInteraction.PENETRATION] = DMG_PENETRATION
		_payout_table[NativeArmorInteraction.PARTIAL_PEN] = DMG_PARTIAL_PEN
		_payout_table[NativeArmorInteraction.OVERPENETRATION] = DMG_OVERPENETRATION
	return _payout_table


static func _loaded_shell(shooter: Ship, kind: int) -> int:
	var wc = shooter.secondary_controller if kind == KIND_SECONDARY \
		else shooter.artillery_controller
	return int(wc.shell_index) if wc != null and is_instance_valid(wc) else 0


# ---------------------------------------------------------------- bucketing

static func _geometric_edges(floor_v: float, ratio: float, cap: float,
		top: float) -> PackedFloat64Array:
	var edges := PackedFloat64Array()
	var edge: float = floor_v
	while true:
		edges.append(minf(edge, top))
		if edge >= top:
			break
		edge += minf(edge * (ratio - 1.0), cap)
	return edges


static func _range_edges(kind: int) -> PackedFloat64Array:
	var cached = _range_edge_cache.get(kind)
	if cached != null:
		return cached
	var sec: bool = kind == KIND_SECONDARY
	var edges := _geometric_edges(
		SEC_RANGE_FLOOR_M if sec else RANGE_FLOOR_M,
		RANGE_BUCKET_RATIO,
		SEC_RANGE_BUCKET_M if sec else RANGE_BUCKET_M,
		SEC_RANGE_TOP_M if sec else RANGE_TOP_M)
	_range_edge_cache[kind] = edges
	return edges


static func _aspect_edges() -> PackedFloat64Array:
	if not _aspect_edge_cache.is_empty():
		return _aspect_edge_cache
	var bow := _geometric_edges(ASPECT_FLOOR_DEG, ASPECT_BUCKET_RATIO,
		ASPECT_BUCKET_DEG, 90.0)
	var edges := PackedFloat64Array(bow)
	for i in range(bow.size() - 2, -1, -1):
		edges.append(180.0 - bow[i])
	edges.append(180.0)
	_aspect_edge_cache = edges
	return edges


static func _aspect_index(deg: float) -> int:
	var edges := _aspect_edges()
	return mini(edges.bsearch(deg, false), edges.size() - 1)


## Geometric middle measured from whichever end of the scale the bucket is on.
static func _aspect_center(index: int) -> float:
	var edges := _aspect_edges()
	var i: int = clampi(index, 0, edges.size() - 1)
	var hi: float = edges[i]
	var lo: float = edges[i - 1] if i > 0 else 0.0
	if lo >= 90.0:
		var f_hi: float = 180.0 - lo
		var f_lo: float = 180.0 - hi
		if f_lo <= 0.0:
			f_lo = f_hi / ASPECT_BUCKET_RATIO
		return 180.0 - sqrt(f_lo * f_hi)
	if lo <= 0.0:
		lo = hi / ASPECT_BUCKET_RATIO
	return sqrt(lo * hi)


static func _range_index(kind: int, dist: float) -> int:
	var edges := _range_edges(kind)
	return mini(edges.bsearch(dist, false), edges.size() - 1)


static func _range_center(kind: int, index: int) -> float:
	var edges := _range_edges(kind)
	var i: int = clampi(index, 0, edges.size() - 1)
	var hi: float = edges[i]
	var lo: float = edges[i - 1] if i > 0 else hi / RANGE_BUCKET_RATIO
	return sqrt(lo * hi)


static func _shooter_side(shooter: Ship, target: Ship) -> float:
	var local: Vector3 = target.to_local(shooter.global_position)
	return 1.0 if local.x >= 0.0 else -1.0


static func _bucket_key(shooter: Ship, target: Ship, kind: int = KIND_MAIN) -> Array:
	if shooter.scene_file_path.is_empty() or target.scene_file_path.is_empty():
		return []
	var disp: Vector3 = shooter.global_position - target.global_position
	var aspect: float = rad_to_deg((-(target.global_basis.z as Vector3)).angle_to(disp))
	return [
		kind,
		shooter.scene_file_path,
		target.scene_file_path,
		_aspect_index(aspect),
		_range_index(kind, disp.length()),
	]


## Range bucket whose lattice answers for `range_i`: buckets with near-identical
## fall angle and striking speed for this shell collapse onto the first of them.
static func _canonical_range(shell: ShellParams, kind: int, range_i: int) -> int:
	var k := [_shell_hash(shell), kind]
	var map: PackedInt32Array = _range_remap.get(k, PackedInt32Array())
	if map.is_empty():
		map = _build_range_remap(shell, kind)
		_range_remap[k] = map
	return map[range_i] if range_i < map.size() else -1


static func _build_range_remap(shell: ShellParams, kind: int) -> PackedInt32Array:
	var edges := _range_edges(kind)
	var map := PackedInt32Array()
	map.resize(edges.size())
	var rep: int = -1
	var rep_angle: float = 0.0
	var rep_speed: float = 0.0
	var rep_range: float = 0.0
	for i in edges.size():
		var r := _range_center(kind, i)
		var launch: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(
			Vector3(0.0, GUN_HEIGHT_M, 0.0), Vector3(r, 0.0, 0.0), shell)
		if launch.is_empty() or not launch[0]:
			map[i] = -1
			rep = -1
			continue
		var v: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
			launch[0], launch[1], shell)
		var angle := rad_to_deg(atan2(-v.y, Vector2(v.x, v.z).length()))
		var speed := v.length()
		if rep >= 0 and rep_range / r >= RANGE_MERGE_MIN_RATIO \
				and absf(angle - rep_angle) <= FALL_MERGE_DEG \
				and absf(speed - rep_speed) <= SPEED_MERGE_FRAC * rep_speed:
			map[i] = rep
		else:
			rep = i
			rep_angle = angle
			rep_speed = speed
			rep_range = r
			map[i] = i
	return map


# ------------------------------------------------------------ survey space

static func survey_space_state(target: Ship) -> PhysicsDirectSpaceState3D:
	if not is_instance_valid(target):
		return null
	if not _survey_space.is_valid():
		_survey_space = PhysicsServer3D.space_create()
		PhysicsServer3D.space_set_active(_survey_space, true)
		return null  # queryable only after the server has stepped it once
	var sid: int = target.get_instance_id()
	var body: RID = _survey_obbs.get(sid, RID())
	if not body.is_valid():
		body = _mirror_obb(target)
		if not body.is_valid():
			return null
		_survey_obbs[sid] = body
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM,
		target.global_transform)
	return PhysicsServer3D.space_get_direct_state(_survey_space)


static func _mirror_obb(target: Ship) -> RID:
	var entry: Dictionary = PrecisionPhysicsWorld.get_ship_entry(target)
	if entry.is_empty():
		return RID()
	var obb_node = entry.get("obb_body")
	if obb_node == null or not is_instance_valid(obb_node):
		return RID()
	var col: CollisionShape3D = null
	for child in (obb_node as Node).get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			col = child
			break
	if col == null:
		return RID()
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_space(body, _survey_space)
	PhysicsServer3D.body_set_collision_layer(body,
		PrecisionPhysicsWorld.OBB_COLLISION_LAYER)
	PhysicsServer3D.body_set_collision_mask(body, 0)
	PhysicsServer3D.body_attach_object_instance_id(body, obb_node.get_instance_id())
	_survey_shapes.append(col.shape)
	PhysicsServer3D.body_add_shape(body, col.shape.get_rid(), col.transform)
	return body


static func _free_survey_space() -> void:
	for body in _survey_obbs.values():
		PhysicsServer3D.free_rid(body)
	_survey_obbs.clear()
	if _survey_space.is_valid():
		PhysicsServer3D.free_rid(_survey_space)
		_survey_space = RID()
	_survey_shapes.clear()


# ------------------------------------------------------------- public misc

func aim_hint(target: Ship) -> Vector3:
	if not is_instance_valid(target) or target.movement_controller == null:
		return Vector3.ZERO
	var freeboard: float = target.movement_controller.ship_height \
		- target.movement_controller.ship_draft
	return Vector3(0.0, maxf(freeboard, 1.0) * 0.35, 0.0)


func forget_dead() -> void:
	pass


## Between matches: flush the cache, drop everything that references a Ship.
static func clear_all() -> void:
	flush_cache()
	_active.clear()
	_answers.clear()
	_shell_hashes.clear()
	_budget_frame = -1
	_free_survey_space()


static func flush_cache() -> void:
	for id in _slabs:
		var slab: Dictionary = _slabs[id]
		if slab["dirty"]:
			_save_slab(slab)


# ----------------------------------------------------------------- answers

static func _service_frame() -> void:
	var frame: int = Engine.get_physics_frames()
	if frame == _budget_frame:
		return
	_budget_frame = frame
	_drain()


func _answer(key: Array, shooter: Ship, target: Ship) -> Dictionary:
	var kind: int = key[KEY_KIND]
	var aspect_i: int = key[KEY_ASPECT]
	var range_i: int = key[KEY_RANGE]
	var frame: int = Engine.get_physics_frames()
	var st: Dictionary = _answers.get(key, {})
	if st.is_empty():
		st = {"mounts": [], "mounts_frame": -1000, "walked": -1, "scored_frame": -1000, "best": {}}
		_answers[key] = st
	if frame - int(st["mounts_frame"]) >= ANSWER_TTL_FRAMES:
		st["mounts"] = _batteries(shooter, kind, _range_center(kind, range_i))
		st["mounts_frame"] = frame
	var mounts: Array = st["mounts"]
	if mounts.is_empty():
		return {}

	var walked: int = 0
	var complete: bool = true
	var buckets: Array = []
	for m in mounts:
		var pair: Array = []
		for ammo in 2:
			var shell: ShellParams = (m as Dictionary)["shells"][ammo]
			var b: Dictionary = {}
			if shell != null:
				var ri := _canonical_range(shell, kind, range_i)
				if ri >= 0:
					b = _request_bucket(target, shooter, kind, shell, aspect_i, ri)
			pair.append(b)
			if not b.is_empty():
				walked += int(b["walked"])
				if not b["done"]:
					complete = false
		buckets.append(pair)
	if walked == 0:
		return {}

	var changed: bool = walked != int(st["walked"])
	var since: int = frame - int(st["scored_frame"])
	if (changed and (complete or since >= ANSWER_REFRESH_FRAMES)) or since >= ANSWER_TTL_FRAMES:
		st["best"] = _score(mounts, buckets, target)
		st["walked"] = walked
		st["scored_frame"] = frame
	var best: Dictionary = st["best"]
	if best.is_empty():
		return {}
	return {"offset": best["offset"], "ammo": best["ammo"], "payout": best["payout"],
		"complete": complete}


## The aim point is chosen by its best value, the shell by the grid's landed-
## weighted mean (a magazine is committed for a whole engagement). HE carries the
## fire it would start, scaled down where AP already out-damages a burn.
static func _score(mounts: Array, buckets: Array, target: Ship) -> Dictionary:
	var cands := _aim_candidates(target)
	var n := cands.size()
	if n == 0:
		return {}
	var pm := _projectile_native()
	if pm == null:
		return {}
	var total_rate: float = 0.0
	for m in mounts:
		total_rate += float((m as Dictionary)["rate"])
	if total_rate <= 0.0:
		return {}
	var value: Array = [_zeros(n), _zeros(n)]
	var landed: Array = [_zeros(n), _zeros(n)]
	var fire := _zeros(n)
	var payouts := _payouts()
	for mi in mounts.size():
		var m: Dictionary = mounts[mi]
		for ammo in 2:
			var b: Dictionary = buckets[mi][ammo]
			if b.is_empty() or int(b["walked"]) == 0:
				continue
			var shell: ShellParams = m["shells"][ammo]
			var res: PackedFloat64Array = pm.lattice_score(b["cells"], b["nx"], b["ny"],
				b["rect"], _bucket_aims(b, cands), m["half_disp"], m["sigma"],
				m["guarantee"], CITADEL_ELLIPSE, payouts, DMG_TURRET)
			var rate: float = m["rate"]
			var vals: PackedFloat64Array = value[ammo]
			var lands: PackedFloat64Array = landed[ammo]
			for ci in n:
				var v: float = res[2 * ci]
				if v < 0.0:
					continue
				var l: float = res[2 * ci + 1]
				vals[ci] += v * shell.damage * rate
				lands[ci] += l * rate
				if ammo == 1:
					fire[ci] += _fire_value(shell, target, cands[ci]) * l * rate
	for ammo in 2:
		for ci in n:
			value[ammo][ci] /= total_rate
			landed[ammo][ci] /= total_rate
	for ci in n:
		fire[ci] /= total_rate

	var ap_mean := _weighted_mean(value[0], landed[0], null, 0.0)
	var fire_scale: float = 1.0
	var ap_dps: float = ap_mean * total_rate
	if ap_dps > 0.0:
		var fp := target.fire_manager.fparams.p() as DOTParams \
			if target.fire_manager != null and target.fire_manager.fparams != null else null
		if fp != null:
			var fire_dps: float = fp.dmg_rate * target.health_controller.max_hp
			fire_scale = clampf(fire_dps / ap_dps, 0.0, 1.0)
	var he_mean := _weighted_mean(value[1], landed[1], fire, fire_scale)

	var center := Vector3(0.0, (target.aabb.position.y + target.aabb.size.y) * 0.25, 0.0)
	for ammo in ([1, 0] if he_mean > ap_mean else [0, 1]):
		var best: float = 0.0
		var best_ci: int = -1
		var best_dist: float = INF
		for ci in n:
			var v: float = value[ammo][ci]
			if ammo == 1:
				v += fire[ci] * fire_scale
			if v <= 0.0:
				continue
			var dist: float = (cands[ci] as Vector3).distance_to(center)
			if v > best or (is_equal_approx(v, best) and dist < best_dist):
				best = v
				best_dist = dist
				best_ci = ci
		if best_ci >= 0:
			return {"offset": cands[best_ci] as Vector3, "ammo": ammo, "payout": best}
	return {}


static func _weighted_mean(vals: PackedFloat64Array, weights: PackedFloat64Array,
		extra, extra_scale: float) -> float:
	var total: float = 0.0
	var weight: float = 0.0
	for i in vals.size():
		var w: float = weights[i]
		if w <= 0.0:
			continue
		var v: float = vals[i]
		if extra != null:
			v += (extra as PackedFloat64Array)[i] * extra_scale
		total += v * w
		weight += w
	return total / weight if weight > 0.0 else 0.0


static func _zeros(n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n)
	return out


## Candidates projected onto the bucket's lattice plane along the arrival
## direction; in-plane dispersion offsets carry over unchanged.
static func _bucket_aims(b: Dictionary, cands: Array) -> PackedVector2Array:
	var cached = b.get("aims")
	if cached != null and (cached as PackedVector2Array).size() == cands.size():
		return cached
	var frame := _frame(_from_local(b["kind"], b["aspect"], b["range"]))
	var dir: Vector3 = b["dir"]
	var out := PackedVector2Array()
	out.resize(cands.size())
	for i in cands.size():
		out[i] = _to_plane(cands[i], dir, frame)
	b["aims"] = out
	return out


# ----------------------------------------------------------------- mounts

## One entry per calibre that reaches `range_m`: shells, half-ellipse in metres,
## sigma, shells per second, citadel guarantee fraction.
static func _batteries(shooter: Ship, kind: int, range_m: float) -> Array:
	var found: Array = []
	if kind == KIND_SECONDARY:
		var sec = shooter.secondary_controller
		if sec == null or not is_instance_valid(sec):
			return found
		var mod := _peak_target_mod(shooter, sec.target_mod, true)
		for sc in sec.sub_controllers:
			if sc == null or not is_instance_valid(sc):
				continue
			found.append(_battery(sc.get_params(), sc.get_base_params(), mod,
				(sc.guns as Array).size(), range_m, 0.0))
	else:
		var ac = shooter.artillery_controller
		if ac == null or not is_instance_valid(ac):
			return found
		found.append(_battery(ac.get_params(), ac.get_base_params(),
			_peak_target_mod(shooter, ac.target_mod, false), ac.guns.size(), range_m,
			CITADEL_GUARANTEE_FRAC))
	var live: Array = []
	for b in found:
		if b != null:
			live.append(b)
	return live


## Peak rather than live TargetMod: ramping skills would freeze the answer at
## somebody's first salvo.
static func _peak_target_mod(shooter: Ship, mod: Moddable, peak: bool) -> TargetMod:
	var out := TargetMod.new()
	var now := (mod.p() if mod != null else null) as TargetMod
	if now != null:
		out.grouping = now.grouping
		out.h_spread = now.h_spread
		out.v_spread = now.v_spread
	if peak and shooter.skills != null and is_instance_valid(shooter.skills):
		for id in shooter.skills.skills:
			var skill: Skill = shooter.skills.skills[id]
			if skill != null:
				skill.peak_secondary_target_mod(out)
	return out


static func _battery(p: GunParams, base: GunParams, mod: TargetMod,
		gun_count: int, range_m: float, guarantee: float) -> Variant:
	if p == null or p.dispersion == null or gun_count <= 0 or p.reload_time <= 0.0:
		return null
	if p.shell1 == null and p.shell2 == null:
		return null
	if p._range < range_m:
		return null
	var h_spread: float = mod.h_spread if mod != null else 1.0
	var v_spread: float = mod.v_spread if mod != null else 1.0
	# Gun.fire() normalises range against the BASE range.
	var base_range: float = base._range if base != null else p._range
	var d: Vector2 = p.dispersion.dispersion_at(range_m, base_range)
	return {
		"shells": [p.shell1, p.shell2],
		"half_disp": Vector2(d.x * h_spread, d.y * v_spread) * 0.5,
		"sigma": p.dispersion.sigma * (mod.grouping if mod != null else 1.0),
		"rate": float(gun_count) / p.reload_time,
		"guarantee": guarantee,
	}


# ---------------------------------------------------------------- lattice

static func _from_local(kind: int, aspect_i: int, range_i: int) -> Vector3:
	var a := deg_to_rad(_aspect_center(aspect_i))
	return Vector3(sin(a), 0.0, -cos(a)) * _range_center(kind, range_i) \
		+ Vector3(0.0, GUN_HEIGHT_M, 0.0)


## [forward, right, up] of the lattice plane, target-local.
static func _frame(from_local: Vector3) -> Array:
	var fwd := (-from_local).normalized()
	var right := fwd.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = fwd.cross(Vector3.RIGHT)
	right = right.normalized()
	return [fwd, right, right.cross(fwd).normalized()]


static func _to_plane(p: Vector3, dir: Vector3, frame: Array) -> Vector2:
	var fwd: Vector3 = frame[0]
	var dn := dir.dot(fwd)
	var q := p - dir * (p.dot(fwd) / dn) if absf(dn) > 1e-4 else p
	return Vector2(q.dot(frame[1]), q.dot(frame[2]))


static func _slab_id(target: Ship, shell: ShellParams, kind: int) -> String:
	return "%s__%s__%d" % [_hull_id(target), _shell_hash(shell), kind]


static func _hull_id(ship: Ship) -> String:
	var path := ship.scene_file_path
	var cached = _hull_ids.get(path)
	if cached != null:
		return cached
	var glb: String = ship.resolve_glb_path(ship.ship_model_glb_path) \
		if ship.has_method("resolve_glb_path") else ""
	var md5 := FileAccess.get_md5(glb) if not glb.is_empty() else ""
	var id := "%s-%s" % [path.get_file().get_basename(),
		md5.substr(0, 10) if not md5.is_empty() else "nohash"]
	_hull_ids[path] = id
	return id


## Only what the walk reads; shells differing in damage alone share a slab.
static func _shell_hash(shell: ShellParams) -> String:
	var iid := shell.get_instance_id()
	var cached = _shell_hashes.get(iid)
	if cached != null:
		return cached
	var fields := [shell.speed, shell.drag, shell.caliber, shell.mass, shell.fuze_delay,
		shell.type, shell.penetration_modifier, shell.auto_bounce, shell.ricochet_angle,
		shell.overmatch, shell.arming_threshold]
	var h := str(fields).md5_text().substr(0, 12)
	_shell_hashes[iid] = h
	return h


static func _lib_stamp() -> int:
	if _lib_stamp_cache < 0:
		_lib_stamp_cache = FileAccess.get_modified_time(ProjectSettings.globalize_path(NATIVE_LIB))
	return _lib_stamp_cache


static func _slab(target: Ship, shell: ShellParams, kind: int) -> Dictionary:
	var id := _slab_id(target, shell, kind)
	var s = _slabs.get(id)
	if s != null:
		return s
	s = {"id": id, "buckets": {}, "dirty": false}
	var f := FileAccess.open(CACHE_DIR + id + ".bin", FileAccess.READ)
	if f != null:
		var d = f.get_var()
		if d is Dictionary and int(d.get("version", -1)) == SOLVER_VERSION \
				and int(d.get("lib", -1)) == _lib_stamp():
			for bkey in d["buckets"]:
				var b: Dictionary = d["buckets"][bkey]
				b["walked"] = int(b["nx"]) * int(b["ny"])
				b["done"] = true
				s["buckets"][bkey] = b
	_slabs[id] = s
	return s


static func _save_slab(slab: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var f := FileAccess.open(CACHE_DIR + slab["id"] + ".bin", FileAccess.WRITE)
	if f == null:
		return
	var out := {}
	for bkey in slab["buckets"]:
		var b: Dictionary = slab["buckets"][bkey]
		if not b["done"]:
			continue
		out[bkey] = {"nx": b["nx"], "ny": b["ny"], "rect": b["rect"], "dir": b["dir"],
			"cells": b["cells"], "kind": b["kind"], "aspect": b["aspect"], "range": b["range"]}
	f.store_var({"version": SOLVER_VERSION, "lib": _lib_stamp(), "buckets": out})
	slab["dirty"] = false


static func _request_bucket(target: Ship, owner: Ship, kind: int, shell: ShellParams,
		aspect_i: int, range_i: int) -> Dictionary:
	var slab := _slab(target, shell, kind)
	var bkey: int = aspect_i * 64 + range_i
	var b = slab["buckets"].get(bkey)
	if b == null:
		b = _open_bucket(target, shell, kind, aspect_i, range_i)
		slab["buckets"][bkey] = b
	if not b["done"]:
		_active[[slab["id"], bkey]] = {"frame": Engine.get_physics_frames(), "target": target,
			"owner": owner, "shell": shell, "bucket": b, "slab": slab}
	return b


static func _open_bucket(target: Ship, shell: ShellParams, kind: int, aspect_i: int,
		range_i: int) -> Dictionary:
	var b := {"nx": 0, "ny": 0, "rect": Vector4.ZERO, "dir": Vector3.ZERO,
		"cells": PackedByteArray(), "walked": 0, "done": true,
		"kind": kind, "aspect": aspect_i, "range": range_i}
	var fl := _from_local(kind, aspect_i, range_i)
	var launch: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(
		target.to_global(fl), target.global_position, shell)
	if launch.is_empty() or not launch[0]:
		return b
	var vel: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
		launch[0], launch[1], shell)
	var dir: Vector3 = (target.global_basis.inverse() * vel).normalized()
	var frame := _frame(fl)
	var box: AABB = target.aabb
	if box.size == Vector3.ZERO:
		return b
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in 8:
		var c: Vector3 = box.get_endpoint(i)
		c.y = maxf(c.y, 0.0)
		var q := _to_plane(c, dir, frame)
		lo = lo.min(q)
		hi = hi.max(q)
	var w: float = maxf(hi.x - lo.x, 1.0)
	var h: float = maxf(hi.y - lo.y, 1.0)
	var nx: int = clampi(roundi(sqrt(LATTICE_CELLS * w / h)), LATTICE_MIN, LATTICE_MAX)
	var ny: int = clampi(roundi(float(LATTICE_CELLS) / nx), 3, LATTICE_MAX)
	var du: float = w / nx
	var dv: float = h / ny
	var points := PackedVector3Array()
	points.resize(nx * ny)
	for iy in ny:
		for ix in nx:
			points[iy * nx + ix] = frame[1] * (lo.x + (ix + 0.5) * du) \
				+ frame[2] * (lo.y + (iy + 0.5) * dv)
	var cells := PackedByteArray()
	cells.resize(nx * ny)
	cells.fill(CELL_UNWALKED)
	b["nx"] = nx
	b["ny"] = ny
	b["rect"] = Vector4(lo.x, lo.y, lo.x + w, lo.y + h)
	b["dir"] = dir
	b["cells"] = cells
	b["done"] = false
	b["points"] = points
	b["order"] = _walk_order(nx, ny)
	return b


## Coarse-to-fine, so a part-walked lattice covers the whole silhouette.
static func _walk_order(nx: int, ny: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var seen := PackedByteArray()
	seen.resize(nx * ny)
	for step in [[4, 2], [2, 1], [1, 1]]:
		for iy in range(0, ny, step[1]):
			for ix in range(0, nx, step[0]):
				var i: int = iy * nx + ix
				if seen[i] == 0:
					seen[i] = 1
					out.append(i)
	return out


static func _drain() -> void:
	var stale: Array = []
	var live: int = 0
	for k in _active:
		if _budget_frame - int(_active[k]["frame"]) <= ACTIVE_WINDOW_FRAMES:
			live += 1
	var per_bucket: int = clampi(WALKS_PER_TICK_CAP / maxi(live, 1), 1, CELLS_PER_BUCKET_PER_TICK)
	for k in _active:
		var a: Dictionary = _active[k]
		if _budget_frame - int(a["frame"]) > ACTIVE_WINDOW_FRAMES:
			stale.append(k)
			continue
		var b: Dictionary = a["bucket"]
		if b["done"] or not is_instance_valid(a["target"]) or not is_instance_valid(a["owner"]):
			stale.append(k)
			continue
		if _iterate(b, a, per_bucket) == 0:
			stale.append(k)
	for k in stale:
		_active.erase(k)
	for id in _slabs:
		var slab: Dictionary = _slabs[id]
		if slab["dirty"]:
			_save_slab(slab)
			break


static func _iterate(b: Dictionary, a: Dictionary, n: int) -> int:
	var target: Ship = a["target"]
	var space := survey_space_state(target)
	if space == null:
		return 0
	var pm := _projectile_native()
	if pm == null:
		return 0
	var order: PackedInt32Array = b["order"]
	var points: PackedVector3Array = b["points"]
	var walked: int = b["walked"]
	var count: int = mini(n, order.size() - walked)
	if count <= 0:
		return 0
	var pts := PackedVector3Array()
	pts.resize(count)
	for i in count:
		pts[i] = points[order[walked + i]]
	var from: Vector3 = target.to_global(_from_local(b["kind"], b["aspect"], b["range"]))
	var codes: PackedByteArray = pm.survey_walk(target, a["owner"], a["shell"], from, pts, space)
	var cells: PackedByteArray = b["cells"]
	for i in count:
		cells[order[walked + i]] = codes[i]
	b["walked"] = walked + count
	if b["walked"] >= order.size():
		b["done"] = true
		b.erase("order")
		b.erase("points")
		(a["slab"] as Dictionary)["dirty"] = true
	return count


# ------------------------------------------------------------- candidates

## Priority order: amidships outboard, quarters, ends, then superstructure.
static func _aim_candidates(target: Ship) -> Array:
	var mc = target.movement_controller
	if mc == null:
		return []
	var length: float = mc.ship_length
	var freeboard: float = mc.ship_height - mc.ship_draft
	if length <= 0.0 or freeboard <= 0.0:
		return []
	var half_beam: float = target.aabb.size.x * 0.5
	if half_beam <= 0.0:
		half_beam = maxf(target.beam, 1.0) * 0.5
	var out: Array = []
	for station in HULL_STATIONS:
		var along: float = float(station[0])
		for lf in (station[1] as Array):
			for hf in HULL_HEIGHT_FRACS:
				out.append(Vector3(half_beam * float(lf), freeboard * float(hf),
					length * along))
	var ss: AABB = _superstructure_bounds(target)
	if ss.size.y > 0.0:
		for af in SUPER_ALONG_FRACS:
			for hf in SUPER_HEIGHT_FRACS:
				for lf in SUPER_LATERAL_FRACS:
					out.append(Vector3(
						ss.position.x + ss.size.x * (0.5 + 0.5 * float(lf)),
						ss.position.y + ss.size.y * float(hf),
						ss.position.z + ss.size.z * float(af)))
	return out


## Superstructure mesh bounds in ship space, floored at the deck.
static func _superstructure_bounds(target: Ship) -> AABB:
	var ss = target.super_structure
	if ss == null or not is_instance_valid(ss) or not (ss is MeshInstance3D):
		return AABB()
	var mesh_aabb: AABB = (ss as MeshInstance3D).get_aabb()
	if mesh_aabb.size == Vector3.ZERO:
		return AABB()
	var to_ship: Transform3D = target.global_transform.affine_inverse() \
		* (ss as Node3D).global_transform
	var box := AABB(to_ship * mesh_aabb.position, Vector3.ZERO)
	for i in 8:
		box = box.expand(to_ship * mesh_aabb.get_endpoint(i))
	var deck_y: float = target.to_local((ss as Node3D).global_position).y
	if deck_y > box.position.y:
		var lift: float = deck_y - box.position.y
		box.position.y = deck_y
		box.size.y = maxf(box.size.y - lift, 0.0)
	return box


## Zero when the nearest fire section is already alight.
static func _fire_value(shell: ShellParams, target: Ship, local_aim: Vector3) -> float:
	if shell.fire_buildup <= 0.0 or not is_instance_valid(target):
		return 0.0
	var fm = target.fire_manager
	if fm == null or fm.rparams == null:
		return 0.0
	var rp := fm.rparams.p() as ResistanceParams
	if rp == null or rp.max_buildup <= 0.0:
		return 0.0
	var nearest: Fire = null
	var nearest_d: float = INF
	for f in fm.fires:
		if f == null:
			continue
		var d: float = (f as Fire).position.distance_squared_to(local_aim)
		if d < nearest_d:
			nearest_d = d
			nearest = f
	if nearest != null and nearest.lifetime > 0.0:
		return 0.0
	var chance: float = clampf(shell.fire_buildup / rp.max_buildup, 0.0, 1.0)
	return chance * target.health_controller.max_hp * FIRE_VALUE_PER_FIRE
