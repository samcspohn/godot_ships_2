class_name GunneryModel
extends RefCounted
## Shell, battery, hull-lattice and payout model shared by point tables and the v4 solver.

const DMG_CITADEL: float = 1.0
const DMG_CITADEL_OVERPEN: float = 0.5
const DMG_PENETRATION: float = 1.0 / 3.0
const DMG_PARTIAL_PEN: float = 0.0667
const DMG_OVERPENETRATION: float = 0.1
const DMG_TURRET: float = DMG_CITADEL * 0.1
## Share of a fire's full duration it burns before damage control puts it out.
const FIRE_BURN_SHARE: float = 0.7

## HP sections, indexed by ArmorPart.Type: which of HPManager's part pools a
## hit's damage is drawn from. A cell's byte carries the section of the part the
## shell ends in, which is the part HPManager.apply_damage is handed.
const SECTION_COUNT: int = 6
const SEC_MODULE: int = 0
const SEC_CITADEL: int = 1

## What a penetration still does once its section and the hull are spent:
## HPManager's `max(_dmg, base_dmg * 0.1)` floor.
const SATURATED_FLOOR: float = 0.1

## Aspect buckets: geometric from bow-on, capped, mirrored about the beam.
const ASPECT_BUCKET_DEG: float = 10.0
const ASPECT_BUCKET_RATIO: float = 1.3
const ASPECT_FLOOR_DEG: float = 5.0

## Descent-angle buckets: geometric from flat, capped at 2 degrees.
const DESCENT_FLOOR_DEG: float = 1.0
const DESCENT_RATIO: float = 1.35
const DESCENT_CAP_DEG: float = 2.0
const DESCENT_TOP_DEG: float = 45.0

const RANGE_TOP_M: float = 30000.0
const KIND_MAIN: int = 0
const KIND_SECONDARY: int = 1

## Lattice sizing: about this many cells, shaped to the silhouette.
const LATTICE_CELLS: int = 192
const LATTICE_MIN: int = 4
const LATTICE_MAX: int = 48
const GUN_HEIGHT_M: float = 5.0

## Candidate aim points are every CANDIDATE_STRIDE-th cell of the centre lattice.
const CANDIDATE_STRIDE: int = 2
const CANDIDATE_MIN_V_M: float = 2.0

## Rows are fine across the waterline band so a 2-3 m citadel is sampled, not
## aliased by one ray per 7 m row; coarse rows above. Off at steep descent,
## where the citadel is entered through the deck and the band is wide anyway.
const FINE_Y_LO_M: float = -4.0
const FINE_Y_HI_M: float = 4.0
const FINE_ROW_M: float = 0.8
const FINE_ROWS_MAX: int = 12
const FINE_DESCENT_MAX_DEG: float = 20.0
## Each feature point's cell and the cells above and below it are split to about SUB_CELL_M, so a
## narrow pen window there is walked, not aliased; the points are aim candidates too.
const SUB_CELL_M: float = 1.0
const SUB_MAX: int = 3
## Projected feature points closer than this many columns and metres to one kept earlier are dropped:
## a thin projection squeezes the citadel's 15 into a few cells.
const ANCHOR_GAP_COLS: float = 2.0
const ANCHOR_GAP_V_M: float = 2.0
const SHELL_RANGE_STEP_M: float = 250.0
## DispersionCalculator moves at most 1 shell per batch; native code reads the batch size back as 1 / frac.
const CITADEL_GUARANTEE_FRAC: float = 1.0 / DispersionCalculator.BATCH_SIZE
const CITADEL_ELLIPSE := Vector2(0.36, 0.1)
## shell instance id -> {"r","desc","v","pen"} PackedFloat32Arrays over range.
static var _shell_tables: Dictionary = {}
static var _frames: Dictionary = {}
static var _features: Dictionary = {}
static var _payout_table := PackedFloat64Array()
static var _native_pm: Object = null
static var _aspect_edge_cache: PackedFloat64Array = PackedFloat64Array()
static var _descent_edge_cache: PackedFloat64Array = PackedFloat64Array()

static func native_pm() -> Object:
	if _native_pm == null or not is_instance_valid(_native_pm):
		_native_pm = ProjectileManager.get_raw() if ProjectileManager != null else null
	return _native_pm


## What each result is worth against a fresh section, as a fraction of the
## shell's damage. Mirrors the result switch in ProjectileManager.
static func base_payouts() -> PackedFloat64Array:
	if _payout_table.is_empty():
		_payout_table.resize(16)
		_payout_table[NativeArmorInteraction.CITADEL] = DMG_CITADEL
		_payout_table[NativeArmorInteraction.CITADEL_OVERPEN] = DMG_CITADEL_OVERPEN
		_payout_table[NativeArmorInteraction.PENETRATION] = DMG_PENETRATION
		_payout_table[NativeArmorInteraction.PARTIAL_PEN] = DMG_PARTIAL_PEN
		_payout_table[NativeArmorInteraction.OVERPENETRATION] = DMG_OVERPENETRATION
	return _payout_table


## HP per second one fire takes off `ship`, its build included.
static func fire_dps(ship: Ship) -> float:
	var fm = ship.fire_manager
	var fp := fm.fparams.p() as DOTParams if fm != null and fm.fparams != null else null
	return fp.dmg_rate * ship.health_controller.max_hp if fp != null else 0.0


static func fire_burn_s(ship: Ship) -> float:
	var fm = ship.fire_manager
	var fp := fm.fparams.p() as DOTParams if fm != null and fm.fparams != null else null
	return fp.dur * FIRE_BURN_SHARE if fp != null else 0.0


## Fire zones: no more fires than this burn at once.
static func fire_zones(ship: Ship) -> float:
	return float(ship.fire_manager.get_child_count()) if ship.fire_manager != null else 0.0


## Share of a salvo's per-shell fire chances that can burn: shells at one aim point build up one zone, which
## ignites once and takes no more buildup while it burns.
static func salvo_fire_share(shells: int, landed: float, chance: float) -> float:
	var k: float = float(shells) * landed * chance
	return minf(k, 1.0) / k if k > 0.0 else 1.0

static func raw_fire_chance(shell: ShellParams, target: Ship) -> float:
	var fm = target.fire_manager
	if shell.fire_buildup <= 0.0 or fm == null or fm.rparams == null:
		return 0.0
	var rp := fm.rparams.p() as ResistanceParams
	if rp == null or rp.max_buildup <= 0.0:
		return 0.0
	return clampf(shell.fire_buildup / rp.max_buildup, 0.0, 1.0)


## live_payouts with every pool full, for the baked expected-damage summary.
## HPManager.DAMAGE_LEVEL of each payout: what ProjectileManager passes with the
## hit, light for modules, which HPManager repairs as light.
static func full_levels() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(SECTION_COUNT * 16)
	for section in SECTION_COUNT:
		if section == SEC_MODULE:
			continue
		for code in [NativeArmorInteraction.PENETRATION, NativeArmorInteraction.PARTIAL_PEN]:
			out[section * 16 + code] = HPManager.DAMAGE_LEVEL.MEDIUM
		for code in [NativeArmorInteraction.CITADEL, NativeArmorInteraction.CITADEL_OVERPEN]:
			out[section * 16 + code] = HPManager.DAMAGE_LEVEL.HEAVY
	return out


static func full_payouts() -> PackedFloat64Array:
	var base := base_payouts()
	var out := PackedFloat64Array()
	out.resize(SECTION_COUNT * 16)
	for section in SECTION_COUNT:
		for code in base.size():
			if base[code] > 0.0:
				out[section * 16 + code] = SATURATED_FLOOR if section == SEC_MODULE else base[code]
	return out


## True for the results HPManager treats as penetrations. Only these draw on a
## section's pools, so only these saturate, and only these get the 10% floor.
static func is_pen_result(code: int) -> bool:
	return code == NativeArmorInteraction.PENETRATION \
		or code == NativeArmorInteraction.PARTIAL_PEN \
		or code == NativeArmorInteraction.CITADEL \
		or code == NativeArmorInteraction.CITADEL_OVERPEN


## What a section can still absorb: (section, hull) remaining. MODULE hits never
## reach a pool: HPManager caps them at 10% of base and routes them to light damage.
## Citadels have no pool and always pay full.
static func section_pools(target: Ship, section: int) -> Vector2:
	var hp = target.health_controller
	if hp == null or hp.hull == null or section == SEC_MODULE or section == SEC_CITADEL:
		return Vector2(INF, INF)
	var part: HpPartMod = null
	match section:
		int(ArmorPart.Type.CASEMATE): part = hp.casemate
		int(ArmorPart.Type.BOW): part = hp.bow
		int(ArmorPart.Type.STERN): part = hp.stern
		int(ArmorPart.Type.SUPERSTRUCTURE): part = hp.superstructure
	if part == null:
		return Vector2(INF, INF)
	return Vector2(maxf(part.current_pool, 0.0), maxf(hp.hull.current_pool, 0.0))


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
static func live_payouts(target: Ship, shell_damage: float) -> PackedFloat64Array:
	var base := base_payouts()
	var out := PackedFloat64Array()
	out.resize(SECTION_COUNT * 16)
	for section in SECTION_COUNT:
		var pools := section_pools(target, section)
		for code in base.size():
			var frac: float = base[code]
			if frac <= 0.0:
				continue
			var value: float = frac
			if section == SEC_MODULE:
				# Capped at 10% of base going in and floored at it coming out.
				value = SATURATED_FLOOR
			elif is_pen_result(code) and shell_damage > 0.0:
				var d: float = frac * shell_damage
				var absorbed: float = minf(pools.x, d * HPManager.SECTION_SHARE) \
					+ minf(pools.y, d * (1.0 - HPManager.SECTION_SHARE))
				value = maxf(absorbed / shell_damage, SATURATED_FLOOR)
			out[section * 16 + code] = value
	return out


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


static func aspect_edges() -> PackedFloat64Array:
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


static func aspect_index(deg: float) -> int:
	var edges := aspect_edges()
	return mini(edges.bsearch(deg, false), edges.size() - 1)


## Geometric middle measured from whichever end of the scale the bucket is on.
static func aspect_center(index: int) -> float:
	var edges := aspect_edges()
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


static func descent_index(deg: float) -> int:
	var edges := descent_edges()
	if deg > edges[edges.size() - 1]:
		return -1
	return mini(edges.bsearch(deg, false), edges.size() - 1)


static func descent_center(index: int) -> float:
	var edges := descent_edges()
	var i: int = clampi(index, 0, edges.size() - 1)
	var hi: float = edges[i]
	var lo: float = edges[i - 1] if i > 0 else hi / DESCENT_RATIO
	return sqrt(lo * hi)


## [forward, right, up] of the lattice plane for an aspect bucket, target-local.
static func lattice_frame(aspect_i: int) -> Array:
	var cached = _frames.get(aspect_i)
	if cached != null:
		return cached
	var a := deg_to_rad(aspect_center(aspect_i))
	var fwd := -Vector3(sin(a), 0.0, -cos(a))
	var right := fwd.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = fwd.cross(Vector3.RIGHT)
	right = right.normalized()
	var frame := [fwd, right, right.cross(fwd).normalized()]
	_frames[aspect_i] = frame
	return frame


static func to_plane(p: Vector3, dir: Vector3, frame: Array) -> Vector2:
	var fwd: Vector3 = frame[0]
	var dn := dir.dot(fwd)
	var q := p - dir * (p.dot(fwd) / dn) if absf(dn) > 1e-4 else p
	return Vector2(q.dot(frame[1]), q.dot(frame[2]))


## With `stride` > 1 (candidate aim points) fine rows are also thinned so
## candidates sit at least CANDIDATE_MIN_V_M apart: dispersion is metres, so
## aims 0.9 m apart score alike and only cost solve time.
static func lattice_points(frame: Array, rect: Vector4, nx: int, edges: PackedFloat32Array,
		stride: int = 1) -> PackedVector3Array:
	var du: float = (rect.z - rect.x) / nx
	var out := PackedVector3Array()
	var last_v: float = -INF
	for iy in range(0, edges.size() - 1, stride):
		var v: float = 0.5 * (edges[iy] + edges[iy + 1])
		if stride > 1 and v - last_v < CANDIDATE_MIN_V_M:
			continue
		last_v = v
		for ix in range(0, nx, stride):
			out.append(frame[1] * (rect.x + (ix + 0.5) * du) + frame[2] * v)
	return out


static func uniform_edges(lo: float, hi: float, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n + 1)
	for i in n + 1:
		out[i] = lo + (hi - lo) * i / n
	return out


## Row boundaries: `n_u` uniform rows over [lo, hi], with the rows overlapping
## [band_lo, band_hi] replaced by up to FINE_ROWS_MAX rows of ~FINE_ROW_M.
static func _row_edges(lo: float, hi: float, n_u: int, band_lo: float, band_hi: float,
		fine: bool) -> PackedFloat32Array:
	if not fine or band_hi <= band_lo:
		return uniform_edges(lo, hi, n_u)
	var dv: float = (hi - lo) / n_u
	var b_lo: float = maxf(band_lo, lo)
	var b_hi: float = minf(band_hi, hi)
	var out := PackedFloat32Array()
	var n_below: int = roundi((b_lo - lo) / dv)
	if n_below <= 0:
		b_lo = lo
	else:
		out.append_array(uniform_edges(lo, b_lo, n_below))
		out.resize(out.size() - 1)
	var n_fine: int = clampi(roundi((b_hi - b_lo) / FINE_ROW_M), 2, FINE_ROWS_MAX)
	out.append_array(uniform_edges(b_lo, b_hi, n_fine))
	var n_above: int = roundi((hi - b_hi) / dv)
	if n_above <= 0:
		out[out.size() - 1] = hi
	else:
		var above := uniform_edges(b_hi, hi, n_above)
		above.remove_at(0)
		out.append_array(above)
	return out


## Ship-local aim features: citadel side 5 x 3, its ends 3 each and deck 3; upper casemate 5;
## superstructure 3; bow and stern 2 each. Shooter on +x, as the lattice frames have it.
static func feature_points(target: Ship) -> PackedVector3Array:
	var key: String = target.scene_file_path
	if _features.has(key):
		return _features[key]
	var boxes := {}
	for part in target.armor_parts:
		var mesh := part.get_parent() as MeshInstance3D
		if mesh == null or part.type == ArmorPart.Type.MODULE:
			continue
		var box: AABB = target._node_to_ship_transform(mesh) * mesh.get_aabb()
		boxes[part.type] = (boxes[part.type] as AABB).merge(box) if boxes.has(part.type) else box
	var out := PackedVector3Array()
	var along := func(b: AABB, i: int, n: int) -> float: return lerpf(b.position.z, b.end.z, (i + 0.5) / n)
	var cit = boxes.get(ArmorPart.Type.CITADEL)
	if cit != null:
		var c: AABB = cit
		for i in 5:
			for j in 3:
				out.append(Vector3(c.end.x, lerpf(c.position.y, c.end.y, (j + 0.5) / 3.0), along.call(c, i, 5)))
		for z in [c.position.z, c.end.z]:
			for i in 3:
				out.append(Vector3(lerpf(c.position.x, c.end.x, (i + 0.5) / 3.0), c.get_center().y, z))
		for i in 3:
			out.append(Vector3(0.0, c.end.y, along.call(c, i, 3)))
	var cas = boxes.get(ArmorPart.Type.CASEMATE)
	if cas != null:
		var k: AABB = cas
		var y_lo: float = (cit as AABB).end.y if cit != null else k.get_center().y
		for i in 5:
			out.append(Vector3(k.end.x, 0.5 * (y_lo + k.end.y), along.call(k, i, 5)))
	for t in [[ArmorPart.Type.SUPERSTRUCTURE, 3], [ArmorPart.Type.BOW, 2], [ArmorPart.Type.STERN, 2]]:
		var b = boxes.get(t[0])
		if b == null:
			continue
		var bb: AABB = b
		var x: float = 0.0 if t[0] == ArmorPart.Type.SUPERSTRUCTURE else 0.5 * bb.end.x
		var y: float = bb.get_center().y if t[0] == ArmorPart.Type.SUPERSTRUCTURE else lerpf(maxf(bb.position.y, 0.0), bb.end.y, 0.3)
		for i in int(t[1]):
			out.append(Vector3(x, y, along.call(bb, i, int(t[1]))))
	_features[key] = out
	return out


## The feature points in the plane, the cells split around them, and the sub-cell ray points:
## the blob's refine section (survey.rs) and the points to walk after the grid's.
static func _refine(target: Ship, frame: Array, dir: Vector3, rect: Vector4, nx: int,
		edges: PackedFloat32Array) -> Dictionary:
	var ny: int = edges.size() - 1
	var du: float = (rect.z - rect.x) / nx
	var anchors := PackedVector2Array()
	var split := {}
	for p in feature_points(target):
		var q := to_plane(p, dir, frame)
		if q.x <= rect.x or q.x >= rect.z or q.y <= rect.y or q.y >= rect.w or anchors.size() >= 255:
			continue
		var near := false
		for a in anchors:
			if absf(a.x - q.x) < ANCHOR_GAP_COLS * du and absf(a.y - q.y) < ANCHOR_GAP_V_M:
				near = true
				break
		if near:
			continue
		anchors.append(q)
		var ix: int = clampi(int((q.x - rect.x) / du), 0, nx - 1)
		var iy: int = clampi(edges.bsearch(q.y) - 1, 0, ny - 1)
		for dy in [-1, 0, 1]:
			if iy + dy >= 0 and iy + dy < ny:
				split[(iy + dy) * nx + ix] = true
	var cells: Array = split.keys()
	cells.sort()
	var kx: int = clampi(ceili(du / SUB_CELL_M - 0.001), 1, SUB_MAX)
	var ky := PackedByteArray()
	for iy in ny:
		ky.append(clampi(ceili((edges[iy + 1] - edges[iy]) / SUB_CELL_M - 0.001), 1, SUB_MAX))
	var b := PackedByteArray()
	b.resize(3)
	b.encode_u16(0, cells.size())
	b.encode_u8(2, kx)
	b.append_array(ky)
	var pts := PackedVector3Array()
	for c in cells:
		var o := b.size()
		b.resize(o + 2)
		b.encode_u16(o, c)
		var ix: int = c % nx
		var iy: int = c / nx
		for sy in ky[iy]:
			var v: float = lerpf(edges[iy], edges[iy + 1], (sy + 0.5) / ky[iy])
			for sx in kx:
				pts.append(frame[1] * (rect.x + (ix + (sx + 0.5) / kx) * du) + frame[2] * v)
	b.append(anchors.size())
	for a in anchors:
		var o := b.size()
		b.resize(o + 8)
		b.encode_float(o, a.x)
		b.encode_float(o + 4, a.y)
	return {"refine": b, "points": pts}


## Parallel-ray lattice geometry for one bucket, from the hull's AABB.
static func build_lattice(target: Ship, aspect_i: int, descent_i: int) -> Dictionary:
	return build_lattice_at(target, aspect_i, descent_center(descent_i))


static func build_lattice_at(target: Ship, aspect_i: int, descent_deg: float, cells: int = LATTICE_CELLS) -> Dictionary:
	var frame := lattice_frame(aspect_i)
	var d := deg_to_rad(descent_deg)
	var dir: Vector3 = ((frame[0] as Vector3) * cos(d) + Vector3.DOWN * sin(d)).normalized()
	var box: AABB = target.aabb
	if box.size == Vector3.ZERO:
		return {}
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	# The band's plane extent: a horizontal slab slides along `dir` onto the
	# plane, so it spans more v the steeper the descent and the longer the hull.
	var band_lo: float = INF
	var band_hi: float = -INF
	for i in 8:
		var c: Vector3 = box.get_endpoint(i)
		c.y = maxf(c.y, FINE_Y_LO_M)
		var q := to_plane(c, dir, frame)
		lo = lo.min(q)
		hi = hi.max(q)
		c.y = clampf(c.y, FINE_Y_LO_M, FINE_Y_HI_M)
		var qb := to_plane(c, dir, frame).y
		band_lo = minf(band_lo, qb)
		band_hi = maxf(band_hi, qb)
	var w: float = maxf(hi.x - lo.x, 1.0)
	var h: float = maxf(hi.y - lo.y, 1.0)
	var cap: int = maxi(LATTICE_MAX, roundi(LATTICE_MAX * sqrt(float(cells) / LATTICE_CELLS)))
	var nx: int = clampi(roundi(sqrt(cells * w / h)), LATTICE_MIN, cap)
	var ny_u: int = clampi(roundi(float(cells) / nx), 3, cap)
	var rect := Vector4(lo.x, lo.y, lo.x + w, lo.y + h)
	var edges := _row_edges(rect.y, rect.w, ny_u, band_lo, band_hi, descent_deg < FINE_DESCENT_MAX_DEG)
	var points := lattice_points(frame, rect, nx, edges)
	var ref := _refine(target, frame, dir, rect, nx, edges)
	points.append_array(ref["points"])
	return {"nx": nx, "ny": edges.size() - 1, "rect": rect, "dir": dir, "edges": edges,
		"points": points, "refine": ref["refine"]}


## Descent angle, striking speed and penetration of `shell` over range.
static func shell_table(shell: ShellParams) -> Dictionary:
	var iid := shell.get_instance_id()
	var cached = _shell_tables.get(iid)
	if cached != null:
		return cached
	var pm := native_pm()
	var t := {"r": PackedFloat32Array(), "desc": PackedFloat32Array(),
		"v": PackedFloat32Array(), "pen": PackedFloat32Array(), "tof": PackedFloat32Array()}
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
		t["tof"].append(float(launch[1]))
		r += SHELL_RANGE_STEP_M
	_shell_tables[iid] = t
	return t


## [descent deg, speed, penetration] at `range_m`, or empty past the shell's reach.
## Seconds `shooter`'s main-battery shell flies to `range_m`; INF past its reach.
static func flight_time(shooter: Ship, range_m: float) -> float:
	var ac = shooter.artillery_controller
	if ac == null or not is_instance_valid(ac):
		return INF
	var p = ac.get_params()
	var shell: ShellParams = p.shell1 if p.shell1 != null else p.shell2
	if shell == null:
		return INF
	var t := shell_table(shell)
	var rs: PackedFloat32Array = t["r"]
	if rs.size() < 2 or range_m > rs[rs.size() - 1]:
		return INF
	var i: int = clampi(rs.bsearch(range_m), 1, rs.size() - 1)
	return lerpf(t["tof"][i - 1], t["tof"][i], clampf((range_m - rs[i - 1]) / (rs[i] - rs[i - 1]), 0.0, 1.0))


static func shell_at(t: Dictionary, range_m: float) -> Array:
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


## Secondary sub-battery `i` of `shooter` at `range_m`, as batteries builds it with every barrel; null out of range.
static func sec_battery(shooter: Ship, i: int, range_m: float) -> Variant:
	var sec = shooter.secondary_controller
	if sec == null or not is_instance_valid(sec) or i >= sec.sub_controllers.size():
		return null
	var sc = sec.sub_controllers[i]
	if sc == null or not is_instance_valid(sc):
		return null
	return _battery(sc.get_params(), sc.get_base_params(), _peak_target_mod(shooter, sec.target_mod, true), barrels(sc.guns),
		range_m, 0.0)


## Main-battery half-dispersion at `range_m` for point tables: Close Quarters Expertise's in-range factor is taken
## out of the live params, where it toggles with the aim, and applied by range instead (inside the longest
## secondary range only), so one table is right at every range.
static func table_half_disp(shooter: Ship, m: Dictionary, range_m: float) -> Vector2:
	var hd := half_disp(m, range_m)
	var cq := _cq_expertise(shooter)
	if cq == null:
		return hd
	var mod: float = cq.main_gun_in_range_mod
	hd /= maxf(float(cq.applied_bonus), 0.01)
	return hd * mod if range_m < max_secondary_range(shooter) else hd


static func _cq_expertise(shooter: Ship) -> Skill:
	if shooter.skills == null or not is_instance_valid(shooter.skills):
		return null
	for id in shooter.skills.skills:
		var sk: Skill = shooter.skills.skills[id]
		if sk != null and sk.get_script() != null and (sk.get_script() as Script).resource_path.ends_with("cq_expertise.gd"):
			return sk
	return null


static func max_secondary_range(shooter: Ship) -> float:
	var out := 0.0
	var sec = shooter.secondary_controller
	if sec == null or not is_instance_valid(sec):
		return out
	for sc in sec.sub_controllers:
		if sc != null and is_instance_valid(sc):
			out = maxf(out, (sc.params.dynamic_mod as GunParams)._range)
	return out


## One entry per calibre that reaches `range_m`: shells, dispersion params,
## sigma, shells per second, citadel guarantee fraction.
static func batteries(shooter: Ship, kind: int, range_m: float, bearing_deg: float = NAN) -> Array:
	var found: Array = []
	if kind == KIND_SECONDARY:
		var sec = shooter.secondary_controller
		if sec == null or not is_instance_valid(sec):
			return found
		var mod := _peak_target_mod(shooter, sec.target_mod, true)
		var counts := _sec_bearing(shooter, sec, bearing_deg)
		for i in sec.sub_controllers.size():
			var sc = sec.sub_controllers[i]
			if sc == null or not is_instance_valid(sc) or counts[i] == 0:
				continue
			found.append(_battery(sc.get_params(), sc.get_base_params(), mod,
				counts[i], range_m, 0.0))
	else:
		var ac = shooter.artillery_controller
		if ac == null or not is_instance_valid(ac):
			return found
		found.append(_battery(ac.get_params(), ac.get_base_params(),
			_peak_target_mod(shooter, ac.target_mod, false), barrels(ac.guns), range_m,
			CITADEL_GUARANTEE_FRAC))
	var live: Array = []
	for b in found:
		if b != null:
			live.append(b)
	return live


## Shells one salvo of `guns` fires: one per muzzle.
static func barrels(guns: Array) -> int:
	var n := 0
	for g in guns:
		n += maxi(g.muzzles.size(), 1)
	return n


## [scene path, bearing] -> barrels per sub-controller bearing on the better side.
static var _sec_bearing_cache: Dictionary = {}

static func _sec_bearing(shooter: Ship, sec, bearing_deg: float) -> PackedInt32Array:
	var all := PackedInt32Array()
	for sc in sec.sub_controllers:
		all.append(barrels(sc.guns) if sc != null and is_instance_valid(sc) else 0)
	if is_nan(bearing_deg):
		return all
	var key := [shooter.scene_file_path, snappedf(bearing_deg, 0.5)]
	if _sec_bearing_cache.has(key):
		return _sec_bearing_cache[key]
	var best := PackedInt32Array()
	var best_n := -1
	for side in [1.0, -1.0]:
		var counts := PackedInt32Array()
		var n := 0
		for i in all.size():
			var c := 0
			if all[i] > 0:
				for g in sec.sub_controllers[i].guns:
					if BotBehavior.gun_bears(shooter, g, bearing_deg, side):
						c += barrels([g])
			counts.append(c)
			n += c
		if n > best_n:
			best = counts
			best_n = n
	_sec_bearing_cache[key] = best
	return best


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
		"guns": gun_count,
		"guarantee": guarantee,
	}


## Lead error on the target (DamageExpectation.lead_sigmas), 1-sigma metres horizontal and vertical at the aim:
## DamageModel's lead_axes().
static func lead_axes(desc_deg: float, aspect_deg: float, range_m: float, lead: PackedFloat32Array) -> Vector2:
	var bands := lead.size() / 2
	if bands == 0:
		return Vector2.ZERO
	var t := clampf(range_m / DamageExpectation.LEAD_BAND_M - 0.5, 0.0, bands - 1)
	var i := mini(int(t), maxi(bands - 2, 0))
	var j := mini(i + 1, bands - 1)
	var f := t - i
	var al := lerpf(lead[2 * i], lead[2 * j], f)
	var ac := lerpf(lead[2 * i + 1], lead[2 * j + 1], f)
	var sa := sin(deg_to_rad(aspect_deg))
	var ca := cos(deg_to_rad(aspect_deg))
	return Vector2(Vector2(al * sa, ac * ca).length(), Vector2(al * ca, ac * sa).length() * sin(deg_to_rad(desc_deg)))


static func half_disp(m: Dictionary, range_m: float) -> Vector2:
	var d: Vector2 = (m["dispersion"] as DispersionParams).dispersion_at(range_m, m["base_range"])
	return d * (m["spread"] as Vector2) * 0.5


## Zero when the nearest fire section is already alight.
static func fire_chance(shell: ShellParams, target: Ship, local_aim: Vector3) -> float:
	if not is_instance_valid(target) or target.fire_manager == null:
		return 0.0
	var nearest: Fire = null
	var nearest_d: float = INF
	for f in target.fire_manager.fires:
		if f == null:
			continue
		var d: float = (f as Fire).position.distance_squared_to(local_aim)
		if d < nearest_d:
			nearest_d = d
			nearest = f
	if nearest != null and nearest.lifetime > 0.0:
		return 0.0
	return raw_fire_chance(shell, target)
