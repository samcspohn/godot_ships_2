class_name BotGunnery
extends GunneryModel

## Shell and aim-point solver for bots, answered from baked per-hull lattices.
##
## tools/bake_gunnery.gd walks every hull offline: per (aspect, descent angle)
## a lattice of parallel rays over the presented silhouette, each cell holding
## the penetration breakpoints at which the native armour walk's result
## changes, plus the first plate for HE and overmatch. At runtime a shell's
## own descent, striking velocity and penetration at the range to each
## candidate pick the lattice and resolve it, and the gun's dispersion kernel
## scores it (_ProjectileManager.lattice_resolve / lattice_score).

## Bump when lattice geometry, cell encoding, bucket edges or the walk change.
const SOLVER_VERSION: int = 22

const CELL_MISS: int = 0xFF
const CELL_UNWALKED: int = 0xFE
const CELL_TURRET: int = 0x10
const CELL_CODE_MASK: int = 0x0F
const CELL_SECTION_SHIFT: int = 5
const CELL_SECTION_MASK: int = 0xE0
const FLAG_CITADEL: int = 0x01
const FLAG_TURRET: int = 0x02

## How many quantisation steps a pool is tracked in when deciding whether a
## cached answer has gone stale. Eight is fine enough to catch a section
## crossing half-drained or empty within a salvo or two.
const SATURATION_STEPS: int = 8
const ANSWER_CACHE_MAX: int = 4096

## Range buckets, used only to key the answer cache.
const RANGE_BUCKET_RATIO: float = 1.5
const RANGE_BUCKET_M: float = 2000.0
const RANGE_FLOOR_M: float = 50.0
const SEC_RANGE_BUCKET_M: float = 1000.0
const SEC_RANGE_FLOOR_M: float = 50.0
const SEC_RANGE_TOP_M: float = 12000.0

const KEY_KIND: int = 0
const KEY_SHOOTER: int = 1
const KEY_TARGET: int = 2
const KEY_ASPECT: int = 3
const KEY_RANGE: int = 4

## A candidate within this fraction of the best value wins if nearer the centre.
const CENTER_PULL: float = 0.03

const ANSWER_TTL_FRAMES: int = 64
const RESOLVE_CACHE_MAX: int = 1024
const PEN_QUANTUM_MM: float = 5.0

## Spread of the guarantee's moved shell, in ellipse half-axes: DamageModel GUAR_H_SD, GUAR_V_SD.
const GUARANTEE_SD := Vector2(0.577, 0.40)

## Main-battery damage that landed over what get_expected predicted, by shooter class, target class
## (BB, CA, DD) and range at CALIBRATION_BANDS_M; GunneryCalibration over 20 12v12 matches, bake 15, 2026-10-29.
## Bands with no salvos hold the last measured one.
const CALIBRATION_BANDS_M := [2500.0, 7500.0, 12500.0, 17500.0]
const CALIBRATION := [
	[[0.75, 0.66, 0.68, 0.64], [0.73, 0.74, 0.70, 0.79], [0.89, 0.76, 1.00, 0.76]],
	[[0.72, 0.59, 0.51, 0.51], [0.82, 0.82, 0.76, 0.76], [0.78, 0.84, 0.71, 0.71]],
	[[0.83, 0.86, 0.67, 0.67], [0.98, 0.99, 0.78, 0.78], [1.11, 1.29, 1.07, 1.07]],
]


## Share of get_expected's damage `shooter` lands on `target` at `range_m`: the learned table, else static.
static func calibration(shooter: Ship, target: Ship, range_m: float) -> float:
	return DamageExpectation.salvo_factor(shooter, target, range_m)


## CALIBRATION interpolated; CVs count as BB.
static func static_calibration(shooter: Ship, target: Ship, range_m: float) -> float:
	var row: Array = CALIBRATION[mini(shooter.ship_class, 2)][mini(target.ship_class, 2)]
	var bands: Array = CALIBRATION_BANDS_M
	if range_m <= bands[0]:
		return row[0]
	for i in range(1, bands.size()):
		if range_m <= bands[i]:
			return lerpf(row[i - 1], row[i], (range_m - bands[i - 1]) / (bands[i] - bands[i - 1]))
	return row[-1]

## scene path -> table Dictionary, or null when missing or stale.
static var _tables: Dictionary = {}
## gunnery.db head, read once.
const BAKE_SCENE := "res://tools/bake_gunnery.tscn"
const BAKE_LOCK := "user://gunnery_bake.lock"
const BAKE_LOCK_STALE_MS := 120000
static var _index: Dictionary = {}
## Hull scene paths (or "" for the whole db) this process already tried to bake.
static var _bake_tried: Dictionary = {}
## answer key -> {"frame", "ans"}
static var _answers: Dictionary = {}
## [table path, bucket key, pen quantum, overmatch, is_he] -> resolved codes
static var _resolved: Dictionary = {}
static var _range_edge_cache: Dictionary = {}
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
		"ev_shell": ans["payout"],
		"fire_ev": ans["fire_ev"],
		"hit_frac": ans["landed"],
		"fire_chance": ans["fire_chance"],
		"dps": ans["dps"],
		"salvo_ev": ans["salvo_ev"],
		"reload": ans["reload"],
		"options": ans["options"],
	}


# ------------------------------------------------------- expected damage

## The expected-damage summary is baked on every aspect bucket and every other descent bucket.
static func ev_bucket_index(i: int) -> int:
	return clampi(2 * roundi(i / 2.0), 0, 2 * ((mini(aspect_edges().size(), descent_edges().size()) - 1) / 2))


## Degrees off the target's bow of the bearing to `from`, as the buckets use it.
static func aspect_from(target: Ship, from: Vector3) -> float:
	var g := target.to_local(from)
	return rad_to_deg(atan2(absf(g.x), -g.z))


## Baked expected damage of `shooter`'s battery on `target`'s hull at `range_m`,
## seen `aspect_deg` off its bow: {ap_ev, he_ev, he_fire_ev, ap_dps, he_dps},
## ev per shell fired in HP. Full pools, one dispersion kernel for every gun,
## the nearest baked bucket; for what-if questions, not for aiming.
## `bearing_deg`: secondaries count only the guns that bear on the target there off our bow; NAN, all.
static func expected(shooter: Ship, target: Ship, range_m: float, aspect_deg: float,
		kind: int = KIND_MAIN, bearing_deg: float = NAN) -> Dictionary:
	if kind == KIND_MAIN and PointTables.point_tables_on():
		var pt := _expected_points(shooter, target, range_m, aspect_deg)
		if not pt.is_empty():
			return pt
	var table = _table(target)
	if table == null or not (table as Dictionary).has("ev"):
		return {}
	var ev: Dictionary = table["ev"]
	var pm := native_pm()
	var ai := aspect_index(aspect_deg)
	var lead := DamageExpectation.lead_sigmas(target)
	var value := [0.0, 0.0]
	var landed_he := 0.0
	var landed_ap := 0.0
	var fire := 0.0
	var total_rate := 0.0
	for m in batteries(shooter, kind, range_m, bearing_deg):
		var rate: float = m["rate"]
		total_rate += rate
		var hd := half_disp(m, range_m)
		for ammo in 2:
			var shell: ShellParams = m["shells"][ammo]
			if shell == null:
				continue
			var s := shell_at(shell_table(shell), range_m)
			if s.is_empty() or descent_index(s[0]) < 0:
				continue
			var chunk = ev.get(bucket_id(ai, ev_bucket_index(descent_index(s[0]))))
			if chunk == null:
				continue
			var is_he: bool = shell.type == ShellParams.ShellType.HE
			var sigma: float = m["sigma"]
			var miss := lead_axes(s[0], aspect_deg, range_m, lead) * sigma
			var wide := Vector2(Vector2(hd.x, miss.x).length(), Vector2(hd.y, miss.y).length())
			var r: Vector2 = pm.ev_lookup(chunk, s[2], shell.overmatch, is_he, shell.auto_bounce, wide, sigma)
			if r.x < 0.0:
				continue
			var medium: float = maxf(pm.ev_levels(chunk, s[2], shell.overmatch, is_he, shell.auto_bounce, wide, sigma).y, 0.0) * r.x
			var g: float = pm.ev_guarantee_share(float(m["guarantee"]), CITADEL_ELLIPSE, sigma)
			if g > 0.0:
				var gw := Vector2(Vector2(hd.x * CITADEL_ELLIPSE.x * GUARANTEE_SD.x * sigma, miss.x).length(),
					Vector2(hd.y * CITADEL_ELLIPSE.y * GUARANTEE_SD.y * sigma, miss.y).length())
				var q: Vector2 = pm.ev_lookup(chunk, s[2], shell.overmatch, is_he, shell.auto_bounce, gw, sigma)
				if q.x >= 0.0:
					medium = (1.0 - g) * medium + g * maxf(pm.ev_levels(chunk, s[2], shell.overmatch, is_he, shell.auto_bounce, gw, sigma).y, 0.0) * q.x
					r = (1.0 - g) * r + g * q
			var size: float = HPManager.size_mod(target.mass, shell.caliber)
			value[ammo] += (r.x - medium + medium * pen_scale(target, shell.damage * size)) * shell.damage * size * rate
			if ammo == 0:
				landed_ap += r.y * rate
			else:
				landed_he += r.y * rate
				fire += raw_fire_chance(shell, target) * r.y * rate
	if total_rate <= 0.0:
		return {}
	var ap_ev: float = value[0] / total_rate
	var burn: float = fire_burn_s(target)
	var burning: float = fire * burn
	var fire_ev: float = fire / total_rate * fire_dps(target) * burn * (minf(1.0, fire_zones(target) / burning) if burning > 0.0 else 1.0)
	var he_ev: float = value[1] / total_rate + fire_ev
	return {"ap_ev": ap_ev, "he_ev": he_ev, "he_fire_ev": fire_ev, "he_landed": landed_he / total_rate, "ap_landed": landed_ap / total_rate,
		"ap_dps": ap_ev * total_rate, "he_dps": he_ev * total_rate}


static var _model: DamageModel = null
## Ship instance id -> current_hp when its pools were last pushed to _model.
static var _pools_at: Dictionary = {}


## The shared native copy of expected(), with `ship` registered as both a
## shooter (main battery) and a hull. Re-register after upgrades change guns.
static func damage_model(ship: Ship = null) -> DamageModel:
	if _model == null:
		_model = DamageModel.new()
		_model.set_edges(aspect_edges(), descent_edges())
		_model.set_hp_rules(HPManager.DMG_MOD_REF_SHIP_PER_CAL_SQ, HPManager.DMG_MOD_SMALL, HPManager.DMG_MOD_SMALL_RATIO,
			HPManager.SECTION_SHARE, SATURATED_FLOOR, DMG_PENETRATION)
	if ship != null and is_instance_valid(ship):
		var id := ship.get_instance_id()
		if not _model.has_hull(id):
			_register(ship)
		var hp: float = ship.health_controller.current_hp
		if _pools_at.get(id, -1.0) != hp:
			_pools_at[id] = hp
			_model.set_pools(id, pool_state(ship))
	return _model


## Loads every hull and shell table the match will use, so the first sighting
## does not stall a frame decompressing them.
static func warm(ships: Array) -> void:
	var t_model := 0
	var t_shell := 0
	for ship in ships:
		if not (ship is Ship) or not is_instance_valid(ship):
			continue
		var t0 := Time.get_ticks_usec()
		damage_model(ship)
		t_model += Time.get_ticks_usec() - t0
		_warmed[ship.get_instance_id()] = true
		t0 = Time.get_ticks_usec()
		for kind in [KIND_MAIN, KIND_SECONDARY]:
			for m in batteries(ship, kind, 0.0):
				for shell in m["shells"]:
					if shell != null:
						shell_table(shell)
		t_shell += Time.get_ticks_usec() - t0
	for id in _warmed.keys():
		if not is_instance_id_valid(id):
			_warmed.erase(id)
			_pools_at.erase(id)
	var tg := Time.get_ticks_usec()
	damage_model().warm_grids(PackedInt64Array(_warmed.keys()))
	print("BotGunnery.warm: models %d ms, shell tables %d ms, grids %d ms" % [t_model / 1000, t_shell / 1000, (Time.get_ticks_usec() - tg) / 1000])

## Ship instance id -> true, for every ship warm() has seen.
static var _warmed: Dictionary = {}


static func _register(ship: Ship) -> void:
	var id := ship.get_instance_id()
	var table = _table(ship)
	var hp: float = ship.health_controller.max_hp
	var fm = ship.fire_manager
	var rp := fm.rparams.p() as ResistanceParams if fm != null and fm.rparams != null else null
	var fp := fm.fparams.p() as DOTParams if fm != null and fm.fparams != null else null
	_model.set_hull(id, table["ev"] if table != null and (table as Dictionary).has("ev") else {}, hp,
		rp.max_buildup if rp != null else 0.0, fire_dps(ship), fire_burn_s(ship), fire_zones(ship),
		DamageExpectation.lead_sigmas(ship), ship.mass)
	var hpp := ship.health_controller.params.p() as HPParams if ship.health_controller.params != null else null
	if hpp != null:
		_model.set_repair(id, hpp.light_repair, hpp.pen_repair, hpp.citadel_repair)
	var mounts := batteries(ship, KIND_MAIN, 0.0)
	if mounts.is_empty():
		return
	var m: Dictionary = mounts[0]
	var top: float = ship.artillery_controller.get_params()._range
	var curve := PackedFloat32Array()
	var ammo := PackedFloat32Array()
	var tables: Array = []
	for k in 2:
		var shell: ShellParams = m["shells"][k]
		tables.append(shell_table(shell) if shell != null else null)
		ammo.append_array([shell.overmatch if shell != null else 0.0,
			1.0 if shell != null and shell.type == ShellParams.ShellType.HE else 0.0,
			shell.damage if shell != null else 0.0, shell.fire_buildup if shell != null else 0.0,
			shell.caliber if shell != null else 0.0, shell.auto_bounce if shell != null else 0.0])
	var r: float = SHELL_RANGE_STEP_M
	while r <= top:
		for t in tables:
			var at: Array = shell_at(t, r) if t != null else []
			curve.append_array([at[0], at[2]] if not at.is_empty() else [NAN, NAN])
		var hd := half_disp(m, r)
		curve.append_array([hd.x, hd.y])
		r += SHELL_RANGE_STEP_M
	_model.set_shooter(id, SHELL_RANGE_STEP_M, curve, float(m["rate"]), float(m["sigma"]), float(m["guarantee"]),
		CITADEL_ELLIPSE, ammo, float(m["guns"]))


## How drawn-down the saturating sections are, quantised. An answer is recomputed
## when this moves, so a section emptying retargets the guns on the next tick
## instead of at the end of the answer's lifetime.
static func _saturation_sig(target: Ship) -> int:
	var hp = target.health_controller
	if hp == null:
		return 0
	var sig: int = 0
	for part in hp.parts():
		if part == null:
			continue
		sig = sig * (SATURATION_STEPS + 1) + clampi(
			int(SATURATION_STEPS * part.current_pool / maxf(part.pool, 1.0)), 0, SATURATION_STEPS)
	var fm = target.fire_manager
	if fm != null:
		for f in fm.fires:
			sig = sig * 2 + int(f != null and (f as Fire).lifetime > 0.0)
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
	BotBehavior._sec_dps_cache.clear()
	_warmed.clear()
	_answers.clear()
	_shell_tables.clear()
	_resolved.clear()


# ---------------------------------------------------------------- bucketing

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
		aspect_index(aspect),
		_range_index(kind, disp.length()),
		roundi(rad_to_deg(target.angular_velocity.y) * 2.0) if kind == KIND_MAIN and PointTables.point_tables_on() else 0,
	]


static func bucket_id(aspect_i: int, descent_i: int) -> int:
	return aspect_i * 64 + descent_i


# ---------------------------------------------------------------- lattice

# ------------------------------------------------------------------ tables

static func hull_md5(ship: Ship) -> String:
	var glb: String = ship.resolve_glb_path(ship.ship_model_glb_path) \
		if ship.has_method("resolve_glb_path") else ""
	return FileAccess.get_md5(glb) if not glb.is_empty() else ""


static func _db_index() -> Dictionary:
	if _index.is_empty():
		_index = GunneryDb.read_index(SOLVER_VERSION)
		if _index.is_empty():
			push_warning("BotGunnery: no gunnery.db, run `make bake`")
	return _index


static func _table(target: Ship) -> Variant:
	var path := target.scene_file_path
	if _tables.has(path):
		return _tables[path]
	var t = _fresh_table(target)
	if t == null and _rebake(path if int(_db_index().get("version", -1)) == SOLVER_VERSION else "", hull_md5(target)):
		t = _fresh_table(target)
	if t == null:
		push_warning("BotGunnery: no current gunnery table for %s, run `make bake`" % path)
	_tables[path] = t
	return t


static func _fresh_table(target: Ship) -> Variant:
	var idx := _db_index()
	if int(idx.get("version", -1)) != SOLVER_VERSION:
		return null
	var d = GunneryDb.read_hull(target.scene_file_path, idx)
	return d if d is Dictionary and String(d.get("glb_md5", "")) == hull_md5(target) else null


## Bakes `path` (every stale hull when empty) with the bake tool, blocking.
## One process bakes at a time; the rest wait on the lock, then reread.
static func _rebake(path: String, md5: String) -> bool:
	if _bake_tried.has(path) or not ResourceLoader.exists(BAKE_SCENE):
		return false
	_bake_tried[path] = true
	var lock := ProjectSettings.globalize_path(BAKE_LOCK)
	var t0 := Time.get_ticks_msec()
	while DirAccess.make_dir_absolute(lock) != OK:
		if Time.get_ticks_msec() - t0 > BAKE_LOCK_STALE_MS:
			DirAccess.remove_absolute(lock)
			t0 = Time.get_ticks_msec()
		OS.delay_msec(200)
	_index = {}
	if _baked_meanwhile(path, md5):
		DirAccess.remove_absolute(lock)
		return true
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), BAKE_SCENE, "--"]
	if not path.is_empty():
		args.append(path)
	print("BotGunnery: baking %s" % (path if not path.is_empty() else "every stale hull"))
	var out: Array = []
	var code := OS.execute(OS.get_executable_path(), args, out, true)
	DirAccess.remove_absolute(lock)
	_index = {}
	print("BotGunnery: bake exit %d in %.1f s" % [code, (Time.get_ticks_msec() - t0) / 1000.0])
	return code == 0


static func _baked_meanwhile(path: String, md5: String) -> bool:
	var idx := GunneryDb.read_index(SOLVER_VERSION)
	if idx.is_empty() or path.is_empty():
		return not idx.is_empty()
	var d = GunneryDb.read_hull(path, idx)
	return d is Dictionary and String(d.get("glb_md5", "")) == md5


static func _resolve(path: String, bid: int, blob: PackedByteArray, pen: float,
		overmatch: float, is_he: bool, bounce: float) -> PackedByteArray:
	var key := [path, bid, roundi(pen / PEN_QUANTUM_MM), roundi(overmatch), is_he, 0.0 if is_he else snappedf(bounce, 0.001)]
	var cached = _resolved.get(key)
	if cached != null:
		return cached
	if _resolved.size() >= RESOLVE_CACHE_MAX:
		_resolved.clear()
	var pm := native_pm()
	var codes: PackedByteArray = pm.lattice_resolve(blob, pen, overmatch, is_he, bounce)
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


static func bucket_edges(b: PackedByteArray) -> PackedFloat32Array:
	var ny: int = b.decode_u8(1)
	return b.slice(BLOB_HDR, BLOB_HDR + 4 * (ny + 1)).to_float32_array()


## Cell indices are a byte, or two once a bucket has more than 255 profiles.
static func bucket_cell_width(b: PackedByteArray) -> int:
	return 2 if b.decode_u16(2) > 255 else 1


static func bucket_cells_off(b: PackedByteArray) -> int:
	return BLOB_HDR + 4 * (b.decode_u8(1) + 1)


static func bucket_prof_off(b: PackedByteArray) -> int:
	var r := bucket_refine(b)
	return int(r["subs_off"]) + int(r["n_sub"]) * bucket_cell_width(b)


## The refine section: {kx, ky, cells, anchors, subs_off, n_sub}.
static func bucket_refine(b: PackedByteArray) -> Dictionary:
	var nx: int = b.decode_u8(0)
	var ny: int = b.decode_u8(1)
	var o: int = bucket_cells_off(b) + nx * ny * bucket_cell_width(b)
	var n_ref: int = b.decode_u16(o)
	var kx: int = b.decode_u8(o + 2)
	var ky := b.slice(o + 3, o + 3 + ny)
	o += 3 + ny
	var cells := PackedInt32Array()
	var n_sub := 0
	for i in n_ref:
		var c: int = b.decode_u16(o + 2 * i)
		cells.append(c)
		n_sub += kx * ky[c / nx]
	o += 2 * n_ref
	var anchors := PackedVector2Array()
	for i in b.decode_u8(o):
		anchors.append(Vector2(b.decode_float(o + 1 + 8 * i), b.decode_float(o + 5 + 8 * i)))
	o += 1 + 8 * anchors.size()
	return {"kx": kx, "ky": ky, "cells": cells, "anchors": anchors, "subs_off": o, "n_sub": n_sub}


static func bucket_cell(b: PackedByteArray, i: int) -> int:
	var off := bucket_cells_off(b)
	return b.decode_u16(off + 2 * i) if bucket_cell_width(b) == 2 else b.decode_u8(off + i)


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
	var mounts := batteries(shooter, kind, range_c)
	var ans := {}
	if not mounts.is_empty():
		if kind == KIND_MAIN and PointTables.point_tables_on():
			ans = _score_points(mounts, shooter, target)
		elif kind == KIND_SECONDARY and PointTables.point_tables_on():
			ans = _score_sec_points(shooter, target)
		if ans.is_empty() and not (kind == KIND_SECONDARY and PointTables.point_tables_on()):
			ans = _score(mounts, shooter, target, table)
	# Keyed by target instance, so the working set is bounded by the ships alive
	# rather than by the hulls in the game. Dropped wholesale when it grows.
	if _answers.size() >= ANSWER_CACHE_MAX:
		_answers.clear()
	_answers[key] = {"frame": frame, "sig": sig, "ans": ans}
	return ans


## {point, offset (target-local, shooter on +x), value, damage, landed, visited} of the best point, fire included
## for HE; {} without a table or while a bucket it needs is unbuilt.
static func _point_best(shooter: Ship, target: Ship, ammo: int, range_m: float, aspect_deg: float) -> Dictionary:
	var key := PointTables.table_key(shooter, target, ammo)
	if key == "":
		return {}
	var p: GunParams = shooter.artillery_controller.get_params()
	var shell: ShellParams = p.shell1 if ammo == 0 else p.shell2
	var live := PointTables.live_inputs(target, shell.damage)
	var he: bool = shell.type == ShellParams.ShellType.HE
	var q := PackedFloat64Array([range_m, aspect_deg, shell.damage, raw_fire_chance(shell, target) if he else 0.0,
		fire_dps(target) * fire_burn_s(target) if he else 0.0])
	var t0 := Time.get_ticks_usec()
	var r: PackedFloat32Array = native_pm().point_best(key, q, live[1], live[2])
	PointTables._rt["lookup_ms"] = float(PointTables._rt["lookup_ms"]) + (Time.get_ticks_usec() - t0) / 1000.0
	PointTables.note_query(not r.is_empty(), key)
	if r.is_empty():
		return {}
	return {"point": int(r[0]), "value": r[1], "damage": r[2], "landed": r[3], "visited": int(r[4]),
		"offset": Vector3(r[5], r[6], r[7]), "shell": shell}


## The shooter in the target's frame as it will be when the salvo lands: drifted by its velocity and turned by
## its yaw rate, faded over IMPACT_TURN_FADE_S, for one main-battery flight time in game seconds.
const IMPACT_TURN_FADE_S: float = 10.0

static func _impact_local(shooter: Ship, target: Ship) -> Vector3:
	var rel: Vector3 = shooter.global_position - target.global_position
	var tof: float = flight_time(shooter, Vector2(rel.x, rel.z).length())
	if not is_finite(tof):
		return target.to_local(shooter.global_position)
	tof /= maxf(ProjectileManager.get_shell_time_multiplier(), 0.01)
	var turn: float = target.angular_velocity.y * IMPACT_TURN_FADE_S * (1.0 - exp(-tof / IMPACT_TURN_FADE_S))
	var basis: Basis = Basis(Vector3.UP, turn) * target.global_basis
	var pos: Vector3 = target.global_position + target.linear_velocity * tof
	return basis.inverse() * (shooter.global_position - pos)


## expected() from the point tables: each shell's best point at this range and aspect under live pools and fires,
## scaled by HPManager.size_mod; empty when either shell's table is missing.
static func _expected_points(shooter: Ship, target: Ship, range_m: float, aspect_deg: float) -> Dictionary:
	var mounts := batteries(shooter, KIND_MAIN, range_m)
	if mounts.is_empty():
		return {}
	var rate: float = mounts[0]["rate"]
	var b := []
	for ammo in 2:
		var r := _point_best(shooter, target, ammo, range_m, aspect_deg)
		if r.is_empty():
			return {}
		r["size"] = HPManager.size_mod(target.mass, (r["shell"] as ShellParams).caliber)
		b.append(r)
	var ap_ev: float = float(b[0]["damage"]) * float(b[0]["size"])
	var he_fire: float = (float(b[1]["value"]) - float(b[1]["damage"])) \
		* salvo_fire_share(int(mounts[0]["guns"]), float(b[1]["landed"]), raw_fire_chance(b[1]["shell"], target))
	var he_ev: float = float(b[1]["damage"]) * float(b[1]["size"]) + he_fire
	return {"ap_ev": ap_ev, "he_ev": he_ev, "he_fire_ev": he_fire, "he_landed": b[1]["landed"], "ap_landed": b[0]["landed"],
		"ap_dps": ap_ev * rate, "he_dps": he_ev * rate}


## _expected_points at each of `aspects`, one native call per shell; {} where unanswered.
static func expected_points_row(shooter: Ship, target: Ship, range_m: float, aspects: PackedFloat64Array) -> Array:
	var ranges := PackedFloat64Array()
	ranges.resize(aspects.size())
	ranges.fill(range_m)
	return expected_points_pairs(shooter, target, ranges, aspects)


## _expected_points at each (ranges[i], aspects[i]), one native call per shell; {} where unanswered.
static func expected_points_pairs(shooter: Ship, target: Ship, ranges: PackedFloat64Array, aspects: PackedFloat64Array) -> Array:
	var n := ranges.size()
	var out := []
	out.resize(n)
	out.fill({})
	var mounts := batteries(shooter, KIND_MAIN, 0.0)
	if mounts.is_empty():
		return out
	var p: GunParams = shooter.artillery_controller.get_params()
	var any := false
	for i in n:
		any = any or ranges[i] <= p._range
	if not any:
		return out
	var rows := []
	var shells := []
	for ammo in 2:
		var key := PointTables.table_key(shooter, target, ammo)
		var shell: ShellParams = p.shell1 if ammo == 0 else p.shell2
		if key == "" or shell == null:
			for i in n:
				PointTables.note_query(false, key)
			return out
		var live := PointTables.live_inputs(target, shell.damage)
		var he: bool = shell.type == ShellParams.ShellType.HE
		var q := PackedFloat64Array([0.0, 0.0, shell.damage, raw_fire_chance(shell, target) if he else 0.0,
			fire_dps(target) * fire_burn_s(target) if he else 0.0])
		var t0 := Time.get_ticks_usec()
		var r: PackedFloat32Array = native_pm().point_best_pairs(key, q, ranges, aspects, live[1], live[2])
		PointTables._rt["lookup_ms"] = float(PointTables._rt["lookup_ms"]) + (Time.get_ticks_usec() - t0) / 1000.0
		for i in n:
			PointTables.note_query(r.size() > i * 8 and r[i * 8] >= 0.0, key)
		rows.append(r)
		shells.append(shell)
	var ap_size: float = HPManager.size_mod(target.mass, (shells[0] as ShellParams).caliber)
	var he_size: float = HPManager.size_mod(target.mass, (shells[1] as ShellParams).caliber)
	var fire_share_chance: float = raw_fire_chance(shells[1], target)
	var a: PackedFloat32Array = rows[0]
	var h: PackedFloat32Array = rows[1]
	for i in n:
		var o := i * 8
		if ranges[i] > p._range or a.size() <= o or h.size() <= o or a[o] < 0.0 or h[o] < 0.0:
			continue
		var rate: float = mounts[0]["rate"]
		var ap_ev: float = a[o + 2] * ap_size
		var he_fire: float = (h[o + 1] - h[o + 2]) * salvo_fire_share(int(mounts[0]["guns"]), h[o + 3], fire_share_chance)
		var he_ev: float = h[o + 2] * he_size + he_fire
		out[i] = {"ap_ev": ap_ev, "he_ev": he_ev, "he_fire_ev": he_fire, "he_landed": h[o + 3], "ap_landed": a[o + 3],
			"ap_dps": ap_ev * rate, "he_dps": he_ev * rate}
	return out


## SkillStance._fill_cells' inputs for ProjectileManager.stance_cells: expected_points_pairs' per (shooter, target)
## values, and the baked model as the fallback.
static func stance_cell_pack(shooter: Ship, target: Ship) -> Dictionary:
	var p: GunParams = shooter.artillery_controller.get_params()
	var d := {"model": damage_model(target), "shooter": shooter.get_instance_id(), "hull": target.get_instance_id(),
		"alpha_ap": p.shell1.damage if p.shell1 != null else 1.0, "alpha_he": p.shell2.damage if p.shell2 != null else 1.0,
		"keys": PackedStringArray(), "cal_row": PackedFloat64Array(CALIBRATION[mini(shooter.ship_class, 2)][mini(target.ship_class, 2)]),
		"cal_edges": PackedFloat64Array(CALIBRATION_BANDS_M), "cal_band_m": DamageExpectation.RANGE_BAND_M,
		"cal_ab": DamageExpectation.salvo_affine(shooter, target, int(p._range / DamageExpectation.RANGE_BAND_M) + 2)}
	damage_model(shooter)
	var mounts := batteries(shooter, KIND_MAIN, 0.0)
	if mounts.is_empty():
		return d
	d.rate = mounts[0]["rate"]
	d.guns = mounts[0]["guns"]
	d.max_range = p._range
	if not PointTables.point_tables_on():
		return d
	var shells := []
	for ammo in 2:
		var key := PointTables.table_key(shooter, target, ammo)
		var shell: ShellParams = p.shell1 if ammo == 0 else p.shell2
		if key == "" or shell == null:
			d.keys.append("")
			return d
		d.keys.append(key)
		var live := PointTables.live_inputs(target, shell.damage)
		var he: bool = shell.type == ShellParams.ShellType.HE
		d["q%d" % ammo] = PackedFloat64Array([0.0, 0.0, shell.damage, raw_fire_chance(shell, target) if he else 0.0,
			fire_dps(target) * fire_burn_s(target) if he else 0.0])
		d.sat = live[1]
		d.fires = live[2]
		shells.append(shell)
	d.ap_size = HPManager.size_mod(target.mass, (shells[0] as ShellParams).caliber)
	d.he_size = HPManager.size_mod(target.mass, (shells[1] as ShellParams).caliber)
	d.fire_chance = raw_fire_chance(shells[1], target)
	return d


## `n` PointTables.note_query calls on `key`, `served` of them served, the first as `first`.
static func _note_point_batch(n: int, served: int, first: bool, key: String) -> void:
	if n <= 0 or not PointTables.point_tables_on():
		return
	PointTables.note_query(first, key)
	PointTables._rt["queries"] = int(PointTables._rt["queries"]) + n - 1
	PointTables._rt["served"] = int(PointTables._rt["served"]) + served - int(first)
	PointTables._rt["fallback"] = int(PointTables._rt["fallback"]) + n - served - int(not first)


## _score's answer from the point tables; empty when either shell's table is missing.
static func _score_points(mounts: Array, shooter: Ship, target: Ship) -> Dictionary:
	var m: Dictionary = mounts[0]
	var g := _impact_local(shooter, target)
	var range_m: float = g.length()
	var aspect: float = rad_to_deg(atan2(absf(g.x), -g.z))
	# _solve mirrors by the side now; the offset must end on the side the shells meet.
	var flip: float = signf(g.x if g.x != 0.0 else 1.0) * _shooter_side(shooter, target)
	var options := [{}, {}]
	for ammo in 2:
		var b := _point_best(shooter, target, ammo, range_m, aspect)
		if b.is_empty():
			return {}
		var aim: Vector3 = b["offset"]
		var chance: float = fire_chance(b["shell"], target, aim) if ammo == 1 else 0.0
		var fire_ev: float = (float(b["value"]) - float(b["damage"])) * salvo_fire_share(int(m["guns"]), float(b["landed"]), chance)
		aim.x *= flip
		options[ammo] = {"offset": aim, "ammo": ammo, "payout": float(b["damage"]) + fire_ev, "landed": b["landed"],
			"fire_chance": chance, "fire_ev": fire_ev}
	var pick: int = 0 if float(options[0].get("payout", 0.0)) >= float(options[1].get("payout", 0.0)) else 1
	if options[pick].is_empty():
		return {}
	var ans: Dictionary = (options[pick] as Dictionary).duplicate()
	ans["options"] = options
	ans["dps"] = float(ans["payout"]) * float(m["rate"])
	ans["salvo_ev"] = float(ans["payout"]) * float(m["guns"])
	ans["reload"] = float(m["guns"]) / float(m["rate"])
	return ans


## _score_points for the secondaries: per shell, the role (PointTable's six) where every sub-battery in range together
## does most per second, aimed at that role's point of the one doing most there. Empty while a table cannot answer.
static func _score_sec_points(shooter: Ship, target: Ship) -> Dictionary:
	var sec = shooter.secondary_controller
	var g: Vector3 = target.to_local(shooter.global_position)
	var range_m: float = g.length()
	var aspect: float = rad_to_deg(atan2(absf(g.x), -g.z))
	var pm := native_pm()
	var bats := []
	var rate_all := 0.0
	var guns_all := 0
	for i in sec.sub_controllers.size():
		var m = sec_battery(shooter, i, range_m)
		if m != null:
			bats.append([i, m])
			rate_all += float(m["rate"])
			guns_all += int(m["guns"])
	if rate_all <= 0.0:
		return {}
	var options := [{}, {}]
	for ammo in 2:
		var roles := []
		for r in 6:
			roles.append({"ammo": ammo, "dps": 0.0, "fire_ev": 0.0, "salvo_ev": 0.0, "lead": -1.0})
		var any := false
		for im in bats:
			var m: Dictionary = im[1]
			var shell: ShellParams = m["shells"][ammo]
			if shell == null:
				continue
			var key := PointTables.sec_point_key(shooter, int(im[0]), ammo, target)
			if key == "":
				return {}
			var live := PointTables.live_inputs(target, shell.damage)
			var he: bool = shell.type == ShellParams.ShellType.HE
			var q := PackedFloat64Array([range_m, aspect, shell.damage, raw_fire_chance(shell, target) if he else 0.0,
				fire_dps(target) * fire_burn_s(target) if he else 0.0])
			var rows: PackedFloat32Array = pm.point_roles(key, q, live[1], live[2])
			if rows.is_empty():
				return {}
			any = true
			var rate: float = m["rate"]
			for r in 6:
				var o := r * 8
				if rows[o] < 0.0:
					continue
				var aim := Vector3(rows[o + 5], rows[o + 6], rows[o + 7])
				var chance: float = fire_chance(shell, target, aim) if he else 0.0
				var fire_ev: float = (rows[o + 1] - rows[o + 2]) * salvo_fire_share(int(m["guns"]), rows[o + 3], chance)
				var ev: float = rows[o + 2] + fire_ev
				var c: Dictionary = roles[r]
				c.dps += ev * rate
				c.fire_ev += fire_ev * rate
				c.salvo_ev += ev * int(m["guns"])
				if ev * rate > float(c.lead):
					c.lead = ev * rate
					c.offset = aim
					c.landed = rows[o + 3]
					c.fire_chance = chance
		if not any:
			continue
		for c in roles:
			if c.has("offset") and (options[ammo].is_empty() or float(c.dps) > float(options[ammo].dps)):
				options[ammo] = c
	var pick: int = 0 if float(options[0].get("dps", -1.0)) >= float(options[1].get("dps", -1.0)) else 1
	if options[pick].is_empty():
		return {}
	var ans: Dictionary = (options[pick] as Dictionary).duplicate()
	ans.erase("lead")
	ans["payout"] = float(ans["dps"]) / rate_all
	ans["fire_ev"] = float(ans["fire_ev"]) / rate_all
	ans["options"] = options
	ans["reload"] = guns_all / rate_all
	return ans


## Every candidate is scored in the lattice of its own bearing and range, so a
## near shooter sees the bow and the stern at their true aspects.
static func _score(mounts: Array, shooter: Ship, target: Ship, table: Dictionary) -> Dictionary:
	var pm := native_pm()
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
	var at := shell_at(shell_table(first_shell), range_c)
	if at.is_empty():
		return {}
	var desc_c := descent_index(at[0])
	if desc_c < 0:
		return {}
	var b0 = buckets.get(bucket_id(aspect_c, desc_c))
	if b0 == null:
		return {}
	var frame_c := lattice_frame(aspect_c)
	var cands := lattice_points(frame_c, bucket_rect(b0), bucket_nx(b0), bucket_edges(b0), CANDIDATE_STRIDE)
	for a in bucket_refine(b0)["anchors"]:
		cands.append(frame_c[1] * a.x + frame_c[2] * a.y)
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
	var chance := _zeros(n)
	var guns: float = 0.0
	var lead := DamageExpectation.lead_sigmas(target)

	for m in mounts:
		var rate: float = m["rate"]
		for ammo in 2:
			var shell: ShellParams = m["shells"][ammo]
			if shell == null:
				continue
			# Saturation is measured against THIS shell's damage: what a section
			# can still absorb only means something next to the hit it absorbs.
			var payouts := live_payouts(target, shell.damage)
			var st := shell_table(shell)
			var is_he: bool = shell.type == ShellParams.ShellType.HE
			var groups: Dictionary = {}
			for i in n:
				var s := shell_at(st, cand_range[i])
				if s.is_empty():
					continue
				var di := descent_index(s[0])
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
				var s := shell_at(st, mean_r)
				if s.is_empty():
					continue
				var codes := _resolve(path, gk, b, s[2], shell.overmatch, is_he, shell.auto_bounce)
				var frame := lattice_frame(int(gk) / 64)
				var b_dir := bucket_dir(b)
				var aims := PackedVector2Array()
				aims.resize(idx.size())
				for k in idx.size():
					aims[k] = to_plane(cands[idx[k]], b_dir, frame)
				# Shells land where the lead puts them as well as where the guns spread them.
				var hd := half_disp(m, mean_r)
				var miss := lead_axes(s[0], aspect_center(int(gk) / 64), mean_r, lead) * float(m["sigma"])
				hd = Vector2(Vector2(hd.x, miss.x).length(), Vector2(hd.y, miss.y).length())
				var res: PackedFloat64Array = pm.lattice_score(codes, bucket_nx(b), bucket_ny(b),
					bucket_rect(b), bucket_edges(b), aims, hd, m["sigma"],
					m["guarantee"], CITADEL_ELLIPSE, payouts, DMG_TURRET, b)
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
						var fc: float = fire_chance(shell, target, cands[ci])
						fire[ci] += fc * fire_dps(target) * fire_burn_s(target) * l * rate
						chance[ci] += fc * l * rate
	for ammo in 2:
		for ci in n:
			value[ammo][ci] /= total_rate
			landed[ammo][ci] /= total_rate
	for ci in n:
		fire[ci] /= total_rate
		chance[ci] /= total_rate
	for m in mounts:
		guns += float((m as Dictionary)["guns"])
	for ci in n:
		fire[ci] *= salvo_fire_share(int(guns), 1.0, chance[ci])
	var ans := _choose(cands, value, landed, fire, chance, total_rate, target)
	if not ans.is_empty():
		ans["dps"] = float(ans["payout"]) * total_rate
		ans["salvo_ev"] = float(ans["payout"]) * guns
		ans["reload"] = guns / total_rate
	return ans


## Per shell, the best aim with a mild pull toward the centre; the shell whose best aim pays more.
## Both answers are kept under "options" for the bot's shell policy.
static func _choose(cands: PackedVector3Array, value: Array, landed: Array,
		fire: PackedFloat64Array, chance: PackedFloat64Array, total_rate: float, target: Ship) -> Dictionary:
	var n := cands.size()
	var center := Vector3(0.0, (target.aabb.position.y + target.aabb.size.y) * 0.25, 0.0)
	var options := [{}, {}]
	for ammo in 2:
		var best: float = 0.0
		for ci in n:
			best = maxf(best, value[ammo][ci] + (fire[ci] if ammo == 1 else 0.0))
		if best <= 0.0:
			continue
		var best_ci: int = -1
		var best_dist: float = INF
		for ci in n:
			if value[ammo][ci] + (fire[ci] if ammo == 1 else 0.0) < best * (1.0 - CENTER_PULL):
				continue
			var dist: float = cands[ci].distance_to(center)
			if dist < best_dist:
				best_dist = dist
				best_ci = ci
		var fire_ev: float = fire[best_ci] if ammo == 1 else 0.0
		options[ammo] = {"offset": cands[best_ci], "ammo": ammo, "payout": value[ammo][best_ci] + fire_ev,
			"landed": landed[ammo][best_ci], "fire_chance": chance[best_ci] if ammo == 1 else 0.0, "fire_ev": fire_ev}
	var pick: int = 0 if float(options[0].get("payout", 0.0)) >= float(options[1].get("payout", 0.0)) else 1
	if options[pick].is_empty():
		return {}
	var ans: Dictionary = (options[pick] as Dictionary).duplicate()
	ans["options"] = options
	return ans


## Aspect bucket of the bearing from local point `p` to the gun at `g`.
static func _aspect_of(g: Vector3, p: Vector3) -> int:
	var d := g - p
	return aspect_index(rad_to_deg(atan2(absf(d.x), -d.z)))


static func _zeros(n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n)
	return out


# ----------------------------------------------------------------- mounts

## [weight, current pool] per HP section, the hull section first, weighted by pool size, in max_hp's units.
static func pool_state(target: Ship) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var hp = target.health_controller
	if hp == null or hp.hull == null:
		return out
	var mult: float = hp.params.p().mult
	for part in [hp.hull, hp.casemate, hp.bow, hp.stern, hp.superstructure]:
		if part != null and part.pool > 0.0:
			out.append_array([part.pool, maxf(part.current_pool, 0.0) * mult])
	return out


## What a penetration of an `alpha` shell pays on `target`'s pools as they stand, over full ones: DamageModel's
## pen_scale().
static func pen_scale(target: Ship, alpha: float) -> float:
	var pools := pool_state(target)
	if pools.size() < 2 or alpha <= 0.0:
		return 1.0
	var d: float = alpha * DMG_PENETRATION
	var hull: float = pools[1]
	var paid := 0.0
	var weight := 0.0
	for i in pools.size() / 2:
		var absorbed: float = minf(hull, d) if i == 0 else \
			minf(pools[2 * i + 1], d * HPManager.SECTION_SHARE) + minf(hull, d * (1.0 - HPManager.SECTION_SHARE))
		paid += pools[2 * i] * maxf(absorbed, alpha * SATURATED_FLOOR)
		weight += pools[2 * i]
	return paid / weight / d if weight > 0.0 else 1.0
