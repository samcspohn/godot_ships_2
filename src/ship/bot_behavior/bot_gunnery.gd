class_name BotGunnery
extends RefCounted

## Shell and aim-point solver for bots, answered from baked per-hull lattices.
##
## tools/bake_gunnery.gd walks every hull offline: per (aspect, descent angle)
## a lattice of parallel rays over the presented silhouette, each cell holding
## the penetration breakpoints at which the native armour walk's result
## changes, plus the first plate for HE and overmatch. At runtime a shell's
## own descent, striking velocity and penetration at the range to each
## candidate pick the lattice and resolve it, and the gun's dispersion kernel
## scores it (_ProjectileManager.lattice_resolve / lattice_score).

const DMG_CITADEL: float = 1.0
const DMG_CITADEL_OVERPEN: float = 0.5
const DMG_PENETRATION: float = 1.0 / 3.0
const DMG_PARTIAL_PEN: float = 0.0667
const DMG_OVERPENETRATION: float = 0.1
const DMG_TURRET: float = DMG_CITADEL * 0.1
const FIRE_VALUE_PER_FIRE: float = 0.06

## Bump when lattice geometry, cell encoding, bucket edges or the walk change.
const SOLVER_VERSION: int = 7

const CELL_MISS: int = 0xFF
const CELL_UNWALKED: int = 0xFE
const CELL_TURRET: int = 0x10
const CELL_CODE_MASK: int = 0x0F
const CELL_SECTION_SHIFT: int = 5
const CELL_SECTION_MASK: int = 0xE0
const FLAG_CITADEL: int = 0x01
const FLAG_TURRET: int = 0x02

## HP sections, indexed by ArmorPart.Type: which of HPManager's pool pairs a
## hit's damage is drawn from. A cell's byte carries the section of the part the
## shell ends in, which is the part HPManager.apply_damage is handed.
const SECTION_COUNT: int = 6
const SEC_MODULE: int = 0
const SEC_CITADEL: int = 1

## What a penetration still does once its section's pools are spent:
## HPManager's `max(_dmg, base_dmg * 0.1)` floor.
const SATURATED_FLOOR: float = 0.1

## How many quantisation steps a pool is tracked in when deciding whether a
## cached answer has gone stale. Eight is fine enough to catch a section
## crossing half-drained or empty within a salvo or two.
const SATURATION_STEPS: int = 8
const ANSWER_CACHE_MAX: int = 4096

## Aspect buckets: geometric from bow-on, capped, mirrored about the beam.
const ASPECT_BUCKET_DEG: float = 10.0
const ASPECT_BUCKET_RATIO: float = 1.3
const ASPECT_FLOOR_DEG: float = 5.0

## Descent-angle buckets: geometric from flat, capped at 2 degrees.
const DESCENT_FLOOR_DEG: float = 1.0
const DESCENT_RATIO: float = 1.35
const DESCENT_CAP_DEG: float = 2.0
const DESCENT_TOP_DEG: float = 45.0

## Range buckets, used only to key the answer cache.
const RANGE_BUCKET_RATIO: float = 1.5
const RANGE_BUCKET_M: float = 2000.0
const RANGE_FLOOR_M: float = 50.0
const RANGE_TOP_M: float = 30000.0
const SEC_RANGE_BUCKET_M: float = 1000.0
const SEC_RANGE_FLOOR_M: float = 50.0
const SEC_RANGE_TOP_M: float = 12000.0

const KIND_MAIN: int = 0
const KIND_SECONDARY: int = 1

const KEY_KIND: int = 0
const KEY_SHOOTER: int = 1
const KEY_TARGET: int = 2
const KEY_ASPECT: int = 3
const KEY_RANGE: int = 4

## Lattice sizing: about this many cells, shaped to the silhouette.
const LATTICE_CELLS: int = 192
const LATTICE_MIN: int = 4
const LATTICE_MAX: int = 48
const GUN_HEIGHT_M: float = 5.0

## Candidate aim points are every CANDIDATE_STRIDE-th cell of the centre lattice.
const CANDIDATE_STRIDE: int = 2
## A candidate within this fraction of the best value wins if nearer the centre.
const CENTER_PULL: float = 0.03

const SHELL_RANGE_STEP_M: float = 250.0
const ANSWER_TTL_FRAMES: int = 64
const RESOLVE_CACHE_MAX: int = 1024
const PEN_QUANTUM_MM: float = 5.0

## DispersionCalculator: 3 of 4 salvos apply the guarantee to 1 of 3 shells.
const CITADEL_GUARANTEE_FRAC: float = 0.25
const CITADEL_ELLIPSE := Vector2(0.4, 0.1)

## scene path -> table Dictionary, or null when missing or stale.
static var _tables: Dictionary = {}
## gunnery.db head, read once.
static var _index: Dictionary = {}
## shell instance id -> {"r","desc","v","pen"} PackedFloat32Arrays over range.
static var _shell_tables: Dictionary = {}
## answer key -> {"frame", "ans"}
static var _answers: Dictionary = {}
## [table path, bucket key, pen quantum, overmatch, is_he] -> resolved codes
static var _resolved: Dictionary = {}
static var _frames: Dictionary = {}
static var _payout_table := PackedFloat64Array()
static var _native_pm: Object = null
static var _range_edge_cache: Dictionary = {}
static var _aspect_edge_cache: PackedFloat64Array = PackedFloat64Array()
static var _descent_edge_cache: PackedFloat64Array = PackedFloat64Array()

## [kind, target id] -> {"ammo"}; per bot, the loaded magazine.
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
	_committed[ck] = {"ammo": int(ans["ammo"])}
	var offset: Vector3 = ans["offset"]
	if _shooter_side(shooter, target) < 0.0:
		offset.x = -offset.x
	return {
		"offset": offset,
		"ammo": int(ans["ammo"]),
		"probed": true,
		"walked": true,
	}


static func _projectile_native() -> Object:
	if _native_pm == null or not is_instance_valid(_native_pm):
		_native_pm = ProjectileManager.get_raw() if ProjectileManager != null else null
	return _native_pm


## What each result is worth against a fresh section, as a fraction of the
## shell's damage. Mirrors the result switch in ProjectileManager.
static func _base_payouts() -> PackedFloat64Array:
	if _payout_table.is_empty():
		_payout_table.resize(16)
		_payout_table[NativeArmorInteraction.CITADEL] = DMG_CITADEL
		_payout_table[NativeArmorInteraction.CITADEL_OVERPEN] = DMG_CITADEL_OVERPEN
		_payout_table[NativeArmorInteraction.PENETRATION] = DMG_PENETRATION
		_payout_table[NativeArmorInteraction.PARTIAL_PEN] = DMG_PARTIAL_PEN
		_payout_table[NativeArmorInteraction.OVERPENETRATION] = DMG_OVERPENETRATION
	return _payout_table


## True for the results HPManager treats as penetrations. Only these draw on a
## section's pools, so only these saturate, and only these get the 10% floor.
static func _is_pen_result(code: int) -> bool:
	return code == NativeArmorInteraction.PENETRATION \
		or code == NativeArmorInteraction.PARTIAL_PEN \
		or code == NativeArmorInteraction.CITADEL \
		or code == NativeArmorInteraction.CITADEL_OVERPEN


## What a section can still absorb: (pool1, pool2) remaining.
##
## A section is a 1/3 + 2/3 pool pair that every hit splits evenly across
## (HpPartMod.apply_damage), so the small pool empties first and the section
## then absorbs half of what it used to - the "saturated" state - before
## running out entirely.
##
## MODULE hits never reach a pool: HPManager caps them at 10% of base and routes
## them to the ship-wide light pool. The citadel is treated as bottomless, since
## a citadel is always worth full damage.
static func _section_pools(target: Ship, section: int) -> Vector2:
	var hp = target.health_controller
	if hp == null or section == SEC_MODULE or section == SEC_CITADEL:
		return Vector2(INF, INF)
	var part: HpPartMod = null
	match section:
		int(ArmorPart.Type.CASEMATE): part = hp.casemate
		int(ArmorPart.Type.BOW): part = hp.bow
		int(ArmorPart.Type.STERN): part = hp.stern
		int(ArmorPart.Type.SUPERSTRUCTURE): part = hp.superstructure
	if part == null:
		return Vector2(INF, INF)
	return Vector2(maxf(part.current_pool1, 0.0), maxf(part.current_pool2, 0.0))


## Payout per (section, result), section-major, as the native kernel indexes it.
##
## This is where damage saturation enters the bot's reward: a shell landing in a
## section whose pools are drawn down is worth what that section can still
## absorb, floored at SATURATED_FLOOR. It is what moves a bot off a bow it has
## already wrecked and onto the upper belt or the superstructure, without
## anything having to say so.
##
## Overpenetrations are deliberately not saturated: HPManager only applies the
## pools to penetrations (`is_pen`), so an overpen pays its 10% wherever it
## lands.
static func _payouts(target: Ship, shell_damage: float) -> PackedFloat64Array:
	var base := _base_payouts()
	var out := PackedFloat64Array()
	out.resize(SECTION_COUNT * 16)
	for section in SECTION_COUNT:
		var pools := _section_pools(target, section)
		for code in base.size():
			var frac: float = base[code]
			if frac <= 0.0:
				continue
			var value: float = frac
			if section == SEC_MODULE:
				# Capped at 10% of base going in and floored at it coming out.
				value = SATURATED_FLOOR
			elif _is_pen_result(code) and shell_damage > 0.0:
				var d: float = frac * shell_damage
				var absorbed: float = minf(pools.x, d * 0.5) + minf(pools.y, d * 0.5)
				value = maxf(absorbed / shell_damage, SATURATED_FLOOR)
			out[section * 16 + code] = value
	return out


## How drawn-down the saturating sections are, quantised. An answer is recomputed
## when this moves, so a section emptying retargets the guns on the next tick
## instead of at the end of the answer's lifetime.
static func _saturation_sig(target: Ship) -> int:
	var hp = target.health_controller
	if hp == null:
		return 0
	var sig: int = 0
	for part in [hp.casemate, hp.bow, hp.stern, hp.superstructure]:
		if part == null:
			continue
		sig = sig * (SATURATION_STEPS + 1) + clampi(
			int(SATURATION_STEPS * part.current_pool1 / maxf(part.pool1, 1.0)), 0, SATURATION_STEPS)
		sig = sig * (SATURATION_STEPS + 1) + clampi(
			int(SATURATION_STEPS * part.current_pool2 / maxf(part.pool2, 1.0)), 0, SATURATION_STEPS)
	return sig


static func _loaded_shell(shooter: Ship, kind: int) -> int:
	var wc = shooter.secondary_controller if kind == KIND_SECONDARY \
		else shooter.artillery_controller
	return int(wc.shell_index) if wc != null and is_instance_valid(wc) else 0


func aim_hint(target: Ship) -> Vector3:
	if not is_instance_valid(target) or target.movement_controller == null:
		return Vector3.ZERO
	var freeboard: float = target.movement_controller.ship_height \
		- target.movement_controller.ship_draft
	return Vector3(0.0, maxf(freeboard, 1.0) * 0.35, 0.0)


func forget_dead() -> void:
	pass


## Between matches: drop everything keyed on instances. Tables are per hull
## file and stay loaded.
static func clear_all() -> void:
	_answers.clear()
	_shell_tables.clear()
	_resolved.clear()


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


static func descent_edges() -> PackedFloat64Array:
	if _descent_edge_cache.is_empty():
		_descent_edge_cache = _geometric_edges(DESCENT_FLOOR_DEG, DESCENT_RATIO,
			DESCENT_CAP_DEG, DESCENT_TOP_DEG)
	return _descent_edge_cache


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


static func _descent_index(deg: float) -> int:
	var edges := descent_edges()
	if deg > edges[edges.size() - 1]:
		return -1
	return mini(edges.bsearch(deg, false), edges.size() - 1)


static func _descent_center(index: int) -> float:
	var edges := descent_edges()
	var i: int = clampi(index, 0, edges.size() - 1)
	var hi: float = edges[i]
	var lo: float = edges[i - 1] if i > 0 else hi / DESCENT_RATIO
	return sqrt(lo * hi)


static func _range_index(kind: int, dist: float) -> int:
	var edges := _range_edges(kind)
	return mini(edges.bsearch(dist, false), edges.size() - 1)


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
		# The INSTANCE, not the hull: two ships off one scene have taken
		# different damage, so they no longer share an answer.
		target.get_instance_id(),
		_aspect_index(aspect),
		_range_index(kind, disp.length()),
	]


static func bucket_id(aspect_i: int, descent_i: int) -> int:
	return aspect_i * 64 + descent_i


# ---------------------------------------------------------------- lattice

## [forward, right, up] of the lattice plane for an aspect bucket, target-local.
static func lattice_frame(aspect_i: int) -> Array:
	var cached = _frames.get(aspect_i)
	if cached != null:
		return cached
	var a := deg_to_rad(_aspect_center(aspect_i))
	var fwd := -Vector3(sin(a), 0.0, -cos(a))
	var right := fwd.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = fwd.cross(Vector3.RIGHT)
	right = right.normalized()
	var frame := [fwd, right, right.cross(fwd).normalized()]
	_frames[aspect_i] = frame
	return frame


static func _to_plane(p: Vector3, dir: Vector3, frame: Array) -> Vector2:
	var fwd: Vector3 = frame[0]
	var dn := dir.dot(fwd)
	var q := p - dir * (p.dot(fwd) / dn) if absf(dn) > 1e-4 else p
	return Vector2(q.dot(frame[1]), q.dot(frame[2]))


static func lattice_points(frame: Array, rect: Vector4, nx: int, ny: int,
		stride: int = 1) -> PackedVector3Array:
	var du: float = (rect.z - rect.x) / nx
	var dv: float = (rect.w - rect.y) / ny
	var out := PackedVector3Array()
	for iy in range(0, ny, stride):
		for ix in range(0, nx, stride):
			out.append(frame[1] * (rect.x + (ix + 0.5) * du) + frame[2] * (rect.y + (iy + 0.5) * dv))
	return out


## Parallel-ray lattice geometry for one bucket, from the hull's AABB.
static func build_lattice(target: Ship, aspect_i: int, descent_i: int) -> Dictionary:
	var frame := lattice_frame(aspect_i)
	var d := deg_to_rad(_descent_center(descent_i))
	var dir: Vector3 = ((frame[0] as Vector3) * cos(d) + Vector3.DOWN * sin(d)).normalized()
	var box: AABB = target.aabb
	if box.size == Vector3.ZERO:
		return {}
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
	var rect := Vector4(lo.x, lo.y, lo.x + w, lo.y + h)
	return {"nx": nx, "ny": ny, "rect": rect, "dir": dir,
		"points": lattice_points(frame, rect, nx, ny)}


# ------------------------------------------------------------------ tables

static func hull_md5(ship: Ship) -> String:
	var glb: String = ship.resolve_glb_path(ship.ship_model_glb_path) \
		if ship.has_method("resolve_glb_path") else ""
	return FileAccess.get_md5(glb) if not glb.is_empty() else ""


static func _db_index() -> Dictionary:
	if _index.is_empty():
		_index = GunneryDb.read_index()
		if _index.is_empty():
			push_warning("BotGunnery: no %s, run `make bake`" % GunneryDb.read_path())
	return _index


static func _table(target: Ship) -> Variant:
	var path := target.scene_file_path
	if _tables.has(path):
		return _tables[path]
	var t = null
	var idx := _db_index()
	if int(idx.get("version", -1)) != SOLVER_VERSION:
		if not idx.is_empty():
			push_warning("BotGunnery: gunnery.db is version %s, want %d; run `make bake`"
				% [idx.get("version", -1), SOLVER_VERSION])
	else:
		var d = GunneryDb.read_hull(path, idx)
		if d is Dictionary and String(d.get("glb_md5", "")) == hull_md5(target):
			t = d
		else:
			push_warning("BotGunnery: stale gunnery table for %s, run `make bake`" % path)
	_tables[path] = t
	return t


## Descent angle, striking speed and penetration of `shell` over range.
static func _shell_table(shell: ShellParams) -> Dictionary:
	var iid := shell.get_instance_id()
	var cached = _shell_tables.get(iid)
	if cached != null:
		return cached
	var pm := _projectile_native()
	var t := {"r": PackedFloat32Array(), "desc": PackedFloat32Array(),
		"v": PackedFloat32Array(), "pen": PackedFloat32Array()}
	var r: float = SHELL_RANGE_STEP_M
	while r <= RANGE_TOP_M:
		var launch: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(
			Vector3(0.0, GUN_HEIGHT_M, 0.0), Vector3(r, 0.0, 0.0), shell)
		if launch.is_empty() or not launch[0]:
			break
		var v: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
			launch[0], launch[1], shell)
		t["r"].append(r)
		t["desc"].append(rad_to_deg(atan2(-v.y, Vector2(v.x, v.z).length())))
		t["v"].append(v.length())
		t["pen"].append(pm.walk_penetration(shell, v.length()) if pm != null else 0.0)
		r += SHELL_RANGE_STEP_M
	_shell_tables[iid] = t
	return t


## [descent deg, speed, penetration] at `range_m`, or empty past the shell's reach.
static func _shell_at(t: Dictionary, range_m: float) -> Array:
	var rs: PackedFloat32Array = t["r"]
	if rs.is_empty() or range_m > rs[rs.size() - 1] + SHELL_RANGE_STEP_M:
		return []
	var i: int = clampi(rs.bsearch(range_m), 1, rs.size() - 1)
	var f: float = clampf((range_m - rs[i - 1]) / (rs[i] - rs[i - 1]), 0.0, 1.0)
	return [
		lerpf(t["desc"][i - 1], t["desc"][i], f),
		lerpf(t["v"][i - 1], t["v"][i], f),
		lerpf(t["pen"][i - 1], t["pen"][i], f),
	]


static func _resolve(path: String, bid: int, blob: PackedByteArray, pen: float,
		overmatch: float, is_he: bool) -> PackedByteArray:
	var key := [path, bid, roundi(pen / PEN_QUANTUM_MM), roundi(overmatch), is_he]
	var cached = _resolved.get(key)
	if cached != null:
		return cached
	if _resolved.size() >= RESOLVE_CACHE_MAX:
		_resolved.clear()
	var pm := _projectile_native()
	var codes: PackedByteArray = pm.lattice_resolve(blob, pen, overmatch, is_he)
	_resolved[key] = codes
	return codes


## nx, ny, rect, dir from a baked bucket blob header (see survey.rs BLOB_HDR).
const BLOB_HDR: int = 32


static func bucket_nx(b: PackedByteArray) -> int:
	return b.decode_u8(0)


static func bucket_ny(b: PackedByteArray) -> int:
	return b.decode_u8(1)


static func bucket_rect(b: PackedByteArray) -> Vector4:
	return Vector4(b.decode_float(4), b.decode_float(8), b.decode_float(12), b.decode_float(16))


static func bucket_dir(b: PackedByteArray) -> Vector3:
	return Vector3(b.decode_float(20), b.decode_float(24), b.decode_float(28))


# ----------------------------------------------------------------- answers

func _answer(key: Array, shooter: Ship, target: Ship) -> Dictionary:
	var table = _table(target)
	if table == null:
		return {}
	var frame: int = Engine.get_physics_frames()
	var sig := _saturation_sig(target)
	var st: Dictionary = _answers.get(key, {})
	if not st.is_empty() and int(st["sig"]) == sig \
			and frame - int(st["frame"]) < ANSWER_TTL_FRAMES:
		return st["ans"]
	var kind: int = key[KEY_KIND]
	var range_c: float = (shooter.global_position - target.global_position).length()
	var mounts := _batteries(shooter, kind, range_c)
	var ans := {}
	if not mounts.is_empty():
		ans = _score(mounts, shooter, target, table)
	# Keyed by target instance, so the working set is bounded by the ships alive
	# rather than by the hulls in the game. Dropped wholesale when it grows.
	if _answers.size() >= ANSWER_CACHE_MAX:
		_answers.clear()
	_answers[key] = {"frame": frame, "sig": sig, "ans": ans}
	return ans


## Every candidate is scored in the lattice of its own bearing and range, so a
## near shooter sees the bow and the stern at their true aspects.
static func _score(mounts: Array, shooter: Ship, target: Ship, table: Dictionary) -> Dictionary:
	var pm := _projectile_native()
	if pm == null:
		return {}
	var buckets: Dictionary = table["buckets"]
	var path: String = target.scene_file_path
	var g: Vector3 = target.to_local(shooter.global_position)
	g.x = absf(g.x)
	var aspect_c := _aspect_of(g, Vector3.ZERO)
	var range_c: float = g.length()

	var first_shell: ShellParams = null
	for m in mounts:
		for s in (m as Dictionary)["shells"]:
			if s != null:
				first_shell = s
				break
		if first_shell != null:
			break
	if first_shell == null:
		return {}
	var at := _shell_at(_shell_table(first_shell), range_c)
	if at.is_empty():
		return {}
	var desc_c := _descent_index(at[0])
	if desc_c < 0:
		return {}
	var b0 = buckets.get(bucket_id(aspect_c, desc_c))
	if b0 == null:
		return {}
	var cands := lattice_points(lattice_frame(aspect_c), bucket_rect(b0), bucket_nx(b0),
		bucket_ny(b0), CANDIDATE_STRIDE)
	var n := cands.size()
	var cand_aspect := PackedInt32Array()
	var cand_range := PackedFloat64Array()
	cand_aspect.resize(n)
	cand_range.resize(n)
	for i in n:
		cand_aspect[i] = _aspect_of(g, cands[i])
		cand_range[i] = (g - cands[i]).length()

	var total_rate: float = 0.0
	for m in mounts:
		total_rate += float((m as Dictionary)["rate"])
	if total_rate <= 0.0:
		return {}
	var value: Array = [_zeros(n), _zeros(n)]
	var landed: Array = [_zeros(n), _zeros(n)]
	var fire := _zeros(n)

	for m in mounts:
		var rate: float = m["rate"]
		for ammo in 2:
			var shell: ShellParams = m["shells"][ammo]
			if shell == null:
				continue
			# Saturation is measured against THIS shell's damage: what a section
			# can still absorb only means something next to the hit it absorbs.
			var payouts := _payouts(target, shell.damage)
			var st := _shell_table(shell)
			var is_he: bool = shell.type == ShellParams.ShellType.HE
			var groups: Dictionary = {}
			for i in n:
				var s := _shell_at(st, cand_range[i])
				if s.is_empty():
					continue
				var di := _descent_index(s[0])
				if di < 0:
					continue
				var gk := bucket_id(cand_aspect[i], di)
				if not groups.has(gk):
					groups[gk] = PackedInt32Array()
				groups[gk].append(i)
			for gk in groups:
				var b = buckets.get(gk)
				if b == null:
					continue
				var idx: PackedInt32Array = groups[gk]
				var mean_r: float = 0.0
				for i in idx:
					mean_r += cand_range[i]
				mean_r /= idx.size()
				var s := _shell_at(st, mean_r)
				if s.is_empty():
					continue
				var codes := _resolve(path, gk, b, s[2], shell.overmatch, is_he)
				var frame := lattice_frame(int(gk) / 64)
				var b_dir := bucket_dir(b)
				var aims := PackedVector2Array()
				aims.resize(idx.size())
				for k in idx.size():
					aims[k] = _to_plane(cands[idx[k]], b_dir, frame)
				var res: PackedFloat64Array = pm.lattice_score(codes, bucket_nx(b), bucket_ny(b),
					bucket_rect(b), aims, _half_disp(m, mean_r), m["sigma"], m["guarantee"],
					CITADEL_ELLIPSE, payouts, DMG_TURRET)
				var vals: PackedFloat64Array = value[ammo]
				var lands: PackedFloat64Array = landed[ammo]
				for k in idx.size():
					var v: float = res[2 * k]
					if v < 0.0:
						continue
					var l: float = res[2 * k + 1]
					var ci: int = idx[k]
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
	return _choose(cands, value, landed, fire, total_rate, target)


## Shell by the landed-weighted mean over the plane (a magazine is committed for
## an engagement), aim point by best value with a mild pull toward the centre.
static func _choose(cands: PackedVector3Array, value: Array, landed: Array,
		fire: PackedFloat64Array, total_rate: float, target: Ship) -> Dictionary:
	var n := cands.size()
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
		for ci in n:
			var v: float = value[ammo][ci]
			if ammo == 1:
				v += fire[ci] * fire_scale
			best = maxf(best, v)
		if best <= 0.0:
			continue
		var best_ci: int = -1
		var best_dist: float = INF
		for ci in n:
			var v: float = value[ammo][ci]
			if ammo == 1:
				v += fire[ci] * fire_scale
			if v < best * (1.0 - CENTER_PULL):
				continue
			var dist: float = cands[ci].distance_to(center)
			if dist < best_dist:
				best_dist = dist
				best_ci = ci
		if best_ci >= 0:
			var v: float = value[ammo][best_ci]
			if ammo == 1:
				v += fire[best_ci] * fire_scale
			return {"offset": cands[best_ci], "ammo": ammo, "payout": v}
	return {}


## Aspect bucket of the bearing from local point `p` to the gun at `g`.
static func _aspect_of(g: Vector3, p: Vector3) -> int:
	var d := g - p
	return _aspect_index(rad_to_deg(atan2(absf(d.x), -d.z)))


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


# ----------------------------------------------------------------- mounts

## One entry per calibre that reaches `range_m`: shells, dispersion params,
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
	return {
		"shells": [p.shell1, p.shell2],
		"dispersion": p.dispersion,
		# Gun.fire() normalises range against the BASE range.
		"base_range": base._range if base != null else p._range,
		"spread": Vector2(mod.h_spread, mod.v_spread) if mod != null else Vector2.ONE,
		"sigma": p.dispersion.sigma * (mod.grouping if mod != null else 1.0),
		"rate": float(gun_count) / p.reload_time,
		"guarantee": guarantee,
	}


static func _half_disp(m: Dictionary, range_m: float) -> Vector2:
	var d: Vector2 = (m["dispersion"] as DispersionParams).dispersion_at(range_m, m["base_range"])
	return d * (m["spread"] as Vector2) * 0.5


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
