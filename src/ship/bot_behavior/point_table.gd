class_name PointTable
extends RefCounted
## Per (shell, target hull): for each (aspect, range) bucket, the expected damage per shot of aiming
## at each feature point under the gun's real dispersion, walked with the real shell. Values are split
## into what never saturates plus one component per (saturable section, pen result), so live pools
## rescale them exactly at query time.

const RANGES_M: Array[float] = [1000.0, 1500.0, 2000.0, 3000.0, 4000.0, 5000.0, 6000.0, 8000.0,
	10000.0, 12000.0, 14000.0, 16000.0, 18000.0, 20000.0, 22000.0, 24000.0, 26000.0]
const SAT_SECTIONS: Array[int] = [2, 3, 4, 5]
const PEN_CODES: Array[int] = [NativeArmorInteraction.PENETRATION, NativeArmorInteraction.PARTIAL_PEN,
	NativeArmorInteraction.CITADEL, NativeArmorInteraction.CITADEL_OVERPEN]
## Bump when anything that changes stored values changes.
const VERSION: int = 4
## Mean along-track aim error at impact by target class, per DamageExpectation.LEAD_BAND_M band (m, + ahead):
## bot aim in the 2026-11-04 point-table A/Bs, 200 12v12 matches. Shells land behind the aim point.
const LEAD_BIAS_ALONG := {
	"BB": [-5.3, -5.3, -5.6, -6.1],
	"CA": [-4.7, -6.3, -10.5, -32.0],
	"DD": [-7.2, -12.2, -24.0, -105.4],
}
const CACHE_DIR: String = "user://point_tables"
const N_COMP: int = 1 + 4 * 4
const STRIDE: int = N_COMP + 1
## Simulated shells per point per bucket, in salvos of DispersionCalculator.SHELL_COUNT.
const MC_SHELLS: int = 1500
## Side-face grid per part type: [type, along, up, x as a fraction of the box's half beam].
const FACE_GRID := [[ArmorPart.Type.CITADEL, 6, 3, 1.0], [ArmorPart.Type.CASEMATE, 6, 2, 1.0],
	[ArmorPart.Type.SUPERSTRUCTURE, 5, 3, 1.0], [ArmorPart.Type.BOW, 3, 3, 0.5], [ArmorPart.Type.STERN, 3, 3, 0.5]]

## "kernel" scores with the analytic truncated-Gaussian kernel; "mc" with DispersionCalculator samples.
var mode: String = "mc"
var dense: bool = true
## Grid cells before fine rows and sub-cells: 700 walks ~1300-1500 rays a bucket (BotGunnery's 192, ~800).
var cells: int = 700
## bucket -> PackedFloat32Array[n_points]: value per shot at full pools, the query's upper bound.
var full: Dictionary = {}

var shell: ShellParams
var points: PackedVector3Array
var ranges := PackedFloat32Array()
var n_aspect: int = 0
## bucket (range_i * n_aspect + aspect_i) -> PackedFloat32Array[n_points * STRIDE]
var buckets: Dictionary = {}
var stats := {"buckets": 0, "walks": 0, "walk_us": 0.0, "score_us": 0.0, "build_us": 0.0}


static func _comp_payouts() -> PackedFloat64Array:
	var base := BotGunnery._base_payouts()
	var n := BotGunnery.SECTION_COUNT * 16
	var out := PackedFloat64Array()
	out.resize(N_COMP * n)
	for sec in BotGunnery.SECTION_COUNT:
		for code in base.size():
			if base[code] <= 0.0:
				continue
			var k := _comp_of(sec, code)
			var v: float = BotGunnery.SATURATED_FLOOR if sec == BotGunnery.SEC_MODULE else base[code]
			out[k * n + sec * 16 + code] = v
	return out


## 0 for the fixed component, else 1 + section slot * 4 + pen code slot.
static func _comp_of(sec: int, code: int) -> int:
	var si := SAT_SECTIONS.find(sec)
	var ci := PEN_CODES.find(code)
	return 0 if si < 0 or ci < 0 else 1 + si * 4 + ci


func build(shooter: Ship, target: Ship, shell_index: int) -> bool:
	var t_build := Time.get_ticks_usec()
	var pm = ProjectileManager.get_raw()
	var p: GunParams = shooter.artillery_controller.get_params()
	shell = p.shell1 if shell_index == 0 else p.shell2
	if shell == null:
		return false
	points = candidate_points(target) if dense else BotGunnery.feature_points(target)
	n_aspect = BotGunnery._aspect_edges().size() - 1
	var st: Dictionary = BotGunnery._shell_table(shell)
	var comp := _comp_payouts()
	var lead := DamageExpectation.lead_sigmas(target)
	var mc := _mc_samples(BotGunnery._batteries(shooter, BotGunnery.KIND_MAIN, RANGES_M[0]))
	for r in RANGES_M:
		var mounts: Array = BotGunnery._batteries(shooter, BotGunnery.KIND_MAIN, r)
		var at: Array = BotGunnery._shell_at(st, r)
		if mounts.is_empty() or at.is_empty():
			break
		var m: Dictionary = mounts[0]
		var ri := ranges.size()
		ranges.append(r)
		for ai in n_aspect:
			var geo: Dictionary = BotGunnery.build_lattice_at(target, ai, at[0], cells)
			if geo.is_empty():
				continue
			var frame: Array = BotGunnery.lattice_frame(ai)
			var a := deg_to_rad(BotGunnery._aspect_center(ai))
			var gun := Vector3(sin(a), 0.0, -cos(a)) * r
			var pts: PackedVector3Array = geo["points"]
			var dirs := PackedVector3Array()
			var speeds := PackedFloat32Array()
			dirs.resize(pts.size())
			speeds.resize(pts.size())
			for i in pts.size():
				var hv := Vector3(pts[i].x - gun.x, 0.0, pts[i].z - gun.z)
				var s: Array = BotGunnery._shell_at(st, hv.length())
				if s.is_empty():
					s = at
				var d := deg_to_rad(s[0])
				dirs[i] = hv.normalized() * cos(d) + Vector3.DOWN * sin(d)
				speeds[i] = s[1]
			var aims := PackedVector2Array()
			var bias := Vector3(0.0, 0.0, -lead_bias_along(target, r))
			for fp in points:
				aims.append(BotGunnery._to_plane(fp + bias, geo["dir"], frame))
			var hd: Vector2 = BotGunnery.table_half_disp(shooter, m, r)
			var lead_sd: Vector2 = BotGunnery.lead_axes(at[0], BotGunnery._aspect_center(ai), r, lead)
			var opts := {"nx": geo["nx"], "ny": geo["ny"], "rect": geo["rect"], "v_edges": geo["edges"],
				"refine": geo["refine"], "sigma": m["sigma"], "guarantee": m["guarantee"],
				"ellipse": BotGunnery.CITADEL_ELLIPSE, "n_comp": N_COMP, "turret_cap": BotGunnery.DMG_TURRET}
			if mode == "mc":
				opts.merge({"half_disp": hd, "mc_off": mc[0], "mc_lead": mc[1], "lead_sd": lead_sd})
			else:
				var miss: Vector2 = lead_sd * float(m["sigma"])
				opts["half_disp"] = Vector2(Vector2(hd.x, miss.x).length(), Vector2(hd.y, miss.y).length())
			var res: PackedFloat32Array = pm.point_bucket(target, shell, pts, dirs, speeds, aims, comp, opts)
			if res.size() < points.size() * STRIDE + 2:
				continue
			stats["walk_us"] += res[points.size() * STRIDE]
			stats["score_us"] += res[points.size() * STRIDE + 1]
			stats["walks"] += pts.size()
			stats["buckets"] += 1
			buckets[ri * n_aspect + ai] = res.slice(0, points.size() * STRIDE)
			var f := PackedFloat32Array()
			f.resize(points.size())
			for k in points.size():
				for c in N_COMP:
					f[k] += maxf(res[k * STRIDE + c], 0.0)
			full[ri * n_aspect + ai] = f
	stats["build_us"] = Time.get_ticks_usec() - t_build
	return not buckets.is_empty()


static func lead_bias_along(target: Ship, range_m: float) -> float:
	var rows: Array = LEAD_BIAS_ALONG.get(DamageExpectation.class_name_of(target), [])
	if rows.is_empty():
		return 0.0
	var t := clampf(range_m / DamageExpectation.LEAD_BAND_M - 0.5, 0.0, rows.size() - 1)
	var i := mini(int(t), rows.size() - 1)
	return lerpf(rows[i], rows[mini(i + 1, rows.size() - 1)], t - i)


static func cache_path(key: String) -> String:
	return "%s/%s.pt" % [CACHE_DIR, ("%s|v%d" % [key, VERSION]).md5_text()]


func save(path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return false
	var enc := {}
	for key in buckets:
		enc[key] = _encode(buckets[key])
	f.store_var({"version": VERSION, "points": points, "ranges": ranges, "n_aspect": n_aspect, "enc": enc})
	f.close()
	return true


## Per point: landed, the count of non-zero components, then (component, value) pairs; every value sqrt-coded in a u8.
func _encode(b: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	for k in points.size():
		out.append(_q(b[k * STRIDE + N_COMP]))
		var at := out.size()
		out.append(0)
		for c in N_COMP:
			var q := _q(b[k * STRIDE + c])
			if q > 0:
				out.append(c)
				out.append(q)
				out[at] += 1
	return out


func _decode(e: PackedByteArray) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(points.size() * STRIDE)
	var o := 0
	for k in points.size():
		b[k * STRIDE + N_COMP] = _dq(e[o])
		var n: int = e[o + 1]
		o += 2
		for i in n:
			b[k * STRIDE + e[o]] = _dq(e[o + 1])
			o += 2
	return b


static func _q(v: float) -> int:
	return clampi(roundi(255.0 * sqrt(maxf(v, 0.0))), 0, 255)


static func _dq(q: int) -> float:
	return (q / 255.0) * (q / 255.0)


func _refresh_full() -> void:
	full.clear()
	for key in buckets:
		var b: PackedFloat32Array = buckets[key]
		var f := PackedFloat32Array()
		f.resize(points.size())
		for k in points.size():
			for c in N_COMP:
				f[k] += maxf(b[k * STRIDE + c], 0.0)
		full[key] = f


## The table at `path` for `shell`, or null when missing or from another VERSION.
static func load_from(path: String, for_shell: ShellParams) -> RefCounted:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return null
	var d = f.get_var()
	if not (d is Dictionary) or int(d.get("version", -1)) != VERSION:
		return null
	var t = load("res://src/ship/bot_behavior/point_table.gd").new()
	t.shell = for_shell
	t.points = d["points"]
	t.ranges = d["ranges"]
	t.n_aspect = d["n_aspect"]
	for key in d["enc"]:
		t.buckets[key] = t._decode(d["enc"][key])
	t._refresh_full()
	return t


## Component weights for the pool states pruning must keep answers for: fresh, each saturable section drained
## alone, all but each one drained, and all drained.
static func _prune_scenarios() -> Array:
	var base := BotGunnery._base_payouts()
	var n := SAT_SECTIONS.size()
	var masks: Array = [0, (1 << n) - 1]
	for si in n:
		masks.append(1 << si)
		masks.append(((1 << n) - 1) & ~(1 << si))
	var out := []
	for mask in masks:
		var w := PackedFloat32Array()
		w.resize(N_COMP)
		w.fill(1.0)
		for si in n:
			if mask & (1 << si):
				for ci in PEN_CODES.size():
					var code: int = PEN_CODES[ci]
					w[1 + si * 4 + ci] = BotGunnery.SATURATED_FLOOR / base[code] if base[code] > 0.0 else 0.0
		out.append(w)
	return out


## Drops points never within `tol` of their bucket's best under any pruning scenario, with and without HE fire.
## Returns how many are kept.
func prune(target: Ship, tol: float = 0.03) -> int:
	var n := points.size()
	var keep := PackedByteArray()
	keep.resize(n)
	var is_he := shell.type == ShellParams.ShellType.HE
	var fire_k: float = BotGunnery._raw_fire_chance(shell, target) * BotGunnery.fire_dps(target) \
		* BotGunnery.fire_burn_s(target) if is_he else 0.0
	var scen := _prune_scenarios()
	var vals := PackedFloat32Array()
	vals.resize(n)
	for key in buckets:
		var b: PackedFloat32Array = buckets[key]
		for w in scen:
			for fire in ([0.0, fire_k] if is_he else [0.0]):
				var top := 0.0
				for k in n:
					var v := 0.0
					for c in N_COMP:
						v += maxf(b[k * STRIDE + c], 0.0) * w[c]
					vals[k] = v * shell.damage + fire * maxf(b[k * STRIDE + N_COMP], 0.0)
					top = maxf(top, vals[k])
				if top <= 0.0:
					continue
				for k in n:
					if vals[k] >= top * (1.0 - tol):
						keep[k] = 1
	var idx := PackedInt32Array()
	for k in n:
		if keep[k]:
			idx.append(k)
	var pts := PackedVector3Array()
	for k in idx:
		pts.append(points[k])
	for key in buckets:
		var b: PackedFloat32Array = buckets[key]
		var nb := PackedFloat32Array()
		nb.resize(idx.size() * STRIDE)
		for j in idx.size():
			for c in STRIDE:
				nb[j * STRIDE + c] = b[idx[j] * STRIDE + c]
		buckets[key] = nb
	points = pts
	_refresh_full()
	return idx.size()


## The native job for `shooter`'s `ammo` against `target` (_ProjectileManager.point_job_submit), or {} without
## a shell or a range to build at.
static func runtime_job(shooter: Ship, target: Ship, ammo: int, cells: int = 700) -> Dictionary:
	var p: GunParams = shooter.artillery_controller.get_params()
	var sh: ShellParams = p.shell1 if ammo == 0 else p.shell2
	if sh == null:
		return {}
	var st: Dictionary = BotGunnery._shell_table(sh)
	var rs := PackedFloat32Array()
	var hd := PackedVector2Array()
	for r in RANGES_M:
		var mounts: Array = BotGunnery._batteries(shooter, BotGunnery.KIND_MAIN, r)
		if mounts.is_empty() or BotGunnery._shell_at(st, r).is_empty():
			break
		rs.append(r)
		hd.append(BotGunnery.table_half_disp(shooter, mounts[0], r))
	if rs.is_empty():
		return {}
	var mc := _mc_samples(BotGunnery._batteries(shooter, BotGunnery.KIND_MAIN, rs[0]))
	var aspects := PackedFloat64Array()
	for ai in BotGunnery._aspect_edges().size() - 1:
		aspects.append(BotGunnery._aspect_center(ai))
	return {"shell": sh, "shell_r": st["r"], "shell_desc": st["desc"], "shell_v": st["v"],
		"shell_step": BotGunnery.SHELL_RANGE_STEP_M, "ranges": rs, "half_disp": hd,
		"bias": PackedFloat32Array(LEAD_BIAS_ALONG.get(DamageExpectation.class_name_of(target), [])),
		"lead": DamageExpectation.lead_sigmas(target), "lead_band": DamageExpectation.LEAD_BAND_M, "aspects": aspects,
		"points": candidate_points(target), "sections": candidate_sections(target), "sat_w": sat_weights(),
		"features": BotGunnery.feature_points(target), "mc_off": mc[0], "mc_lead": mc[1],
		"comp": _comp_payouts(), "n_comp": N_COMP, "turret_cap": BotGunnery.DMG_TURRET,
		"consts": PackedFloat64Array([BotGunnery.LATTICE_CELLS, BotGunnery.LATTICE_MIN, BotGunnery.LATTICE_MAX,
			BotGunnery.FINE_Y_LO_M, BotGunnery.FINE_Y_HI_M, BotGunnery.FINE_ROW_M, BotGunnery.FINE_ROWS_MAX,
			BotGunnery.FINE_DESCENT_MAX_DEG, BotGunnery.SUB_CELL_M, BotGunnery.SUB_MAX, BotGunnery.ANCHOR_GAP_COLS,
			BotGunnery.ANCHOR_GAP_V_M, cells])}


## An empty table for `job`, filled bucket by bucket through absorb().
static func runtime_table(job: Dictionary) -> RefCounted:
	var t = load("res://src/ship/bot_behavior/point_table.gd").new()
	t.shell = job["shell"]
	t.points = job["points"]
	t.ranges = job["ranges"]
	t.n_aspect = (job["aspects"] as PackedFloat64Array).size()
	return t


## Takes finished buckets (index -> values) from the native worker.
func absorb(d: Dictionary) -> void:
	for key in d:
		var b: PackedFloat32Array = d[key]
		buckets[key] = b
		var f := PackedFloat32Array()
		f.resize(points.size())
		for k in points.size():
			for c in N_COMP:
				f[k] += maxf(b[k * STRIDE + c], 0.0)
		full[key] = f


## Normalised shell offsets from the game's DispersionCalculator (citadel guarantee included) and one
## standard-normal lead draw per salvo, seeded so every bucket and table sees the same shells.
static func _mc_samples(mounts: Array) -> Array:
	var off := PackedVector2Array()
	var lz := PackedVector2Array()
	if mounts.is_empty():
		return [off, lz]
	var sigma: float = mounts[0]["sigma"]
	seed(4242)
	var calc := DispersionCalculator.new(sigma)
	var l := Vector2.ZERO
	for k in MC_SHELLS:
		if calc._shell_index >= DispersionCalculator.SHELL_COUNT:
			calc._new_salvo(sigma)
			l = Vector2(randfn(0.0, 1.0), randfn(0.0, 1.0))
		off.append(Vector2(calc._h_offsets[calc._shell_index], calc._v_offsets[calc._shell_index]))
		lz.append(l)
		calc._shell_index += 1
	return [off, lz]


## Aim candidates, ship-local with the shooter on +x: a grid on each armour zone's side face, plus the
## bow and stern tips.
static func candidate_points(target: Ship) -> PackedVector3Array:
	var boxes := {}
	for part in target.armor_parts:
		var mesh := part.get_parent() as MeshInstance3D
		if mesh == null or part.type == ArmorPart.Type.MODULE:
			continue
		var box: AABB = target._node_to_ship_transform(mesh) * mesh.get_aabb()
		boxes[part.type] = (boxes[part.type] as AABB).merge(box) if boxes.has(part.type) else box
	var out := PackedVector3Array()
	for g in FACE_GRID:
		var b = boxes.get(g[0])
		if b == null:
			continue
		var bb: AABB = b
		var y0: float = maxf(bb.position.y, -2.0)
		for i in int(g[1]):
			for j in int(g[2]):
				out.append(Vector3(bb.end.x * float(g[3]), lerpf(y0, bb.end.y, (j + 0.5) / g[2]),
					lerpf(bb.position.z, bb.end.z, (i + 0.5) / g[1])))
	for t in [ArmorPart.Type.BOW, ArmorPart.Type.STERN]:
		var b = boxes.get(t)
		if b == null:
			continue
		var bb: AABB = b
		var z: float = bb.position.z if t == ArmorPart.Type.BOW else bb.end.z
		for y in [0.25, 0.5, 0.75]:
			out.append(Vector3(0.0, lerpf(maxf(bb.position.y, -2.0), bb.end.y, y), z))
	return out


## candidate_points' sections (ArmorPart.Type), point for point.
static func candidate_sections(target: Ship) -> PackedInt32Array:
	var types := {}
	for part in target.armor_parts:
		if part.get_parent() is MeshInstance3D and part.type != ArmorPart.Type.MODULE:
			types[part.type] = true
	var out := PackedInt32Array()
	for g in FACE_GRID:
		if types.has(g[0]):
			for i in int(g[1]) * int(g[2]):
				out.append(g[0])
	for t in [ArmorPart.Type.BOW, ArmorPart.Type.STERN]:
		if types.has(t):
			out.append_array([t, t, t])
	return out


## Each of `pts` (candidate points, pruned or not) as its section; -1 for none.
static func sections_of(target: Ship, pts: PackedVector3Array) -> PackedInt32Array:
	var cand := candidate_points(target)
	var secs := candidate_sections(target)
	var out := PackedInt32Array()
	for p in pts:
		var s := -1
		for i in cand.size():
			if cand[i].distance_squared_to(p) < 1e-4:
				s = secs[i]
				break
		out.append(s)
	return out


## Per PEN_CODES slot, a drained section's component weight: what the hull pool alone still pays, floored.
static func sat_weights() -> PackedFloat64Array:
	var base := BotGunnery._base_payouts()
	var out := PackedFloat64Array()
	for code in PEN_CODES:
		var b: float = base[code]
		out.append(maxf(1.0 - HPManager.SECTION_SHARE, BotGunnery.SATURATED_FLOOR / b) if b > 0.0 else 0.0)
	return out


## Live weight per component: what `target`'s pools pay now over full.
static func comp_weights(target: Ship, shell_damage: float) -> PackedFloat32Array:
	var base := BotGunnery._base_payouts()
	var live := BotGunnery._payouts(target, shell_damage)
	var w := PackedFloat32Array()
	w.resize(N_COMP)
	w[0] = 1.0
	for si in SAT_SECTIONS.size():
		for ci in PEN_CODES.size():
			var code: int = PEN_CODES[ci]
			w[1 + si * 4 + ci] = live[SAT_SECTIONS[si] * 16 + code] / base[code] if base[code] > 0.0 else 0.0
	return w


## Per point [value per shot in payout units, landed], bilinear over aspect and range.
func values(range_m: float, aspect_deg: float, w: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(points.size() * 2)
	if ranges.is_empty():
		return out
	var rf := _frac(ranges, range_m)
	var centers := PackedFloat32Array()
	for ai in n_aspect:
		centers.append(BotGunnery._aspect_center(ai))
	var af := _frac(centers, aspect_deg)
	for corner in 4:
		var ri: int = int(rf.x) + (corner & 1)
		var ai: int = int(af.x) + (corner >> 1)
		var wt: float = (rf.y if corner & 1 else 1.0 - rf.y) * (af.y if corner >> 1 else 1.0 - af.y)
		var b = buckets.get(mini(ri, ranges.size() - 1) * n_aspect + mini(ai, n_aspect - 1))
		if b == null or wt <= 0.0:
			continue
		var vals: PackedFloat32Array = b
		for k in points.size():
			var v := 0.0
			for c in N_COMP:
				v += maxf(vals[k * STRIDE + c], 0.0) * w[c]
			out[2 * k] += v * wt
			out[2 * k + 1] += maxf(vals[k * STRIDE + N_COMP], 0.0) * wt
	return out


## (lower index, fraction to the next) of `x` in ascending `xs`, clamped.
static func _frac(xs: PackedFloat32Array, x: float) -> Vector2:
	if xs.size() < 2 or x <= xs[0]:
		return Vector2(0, 0)
	if x >= xs[xs.size() - 1]:
		return Vector2(xs.size() - 1, 0)
	var i: int = xs.bsearch(x) - 1
	return Vector2(i, (x - xs[i]) / (xs[i + 1] - xs[i]))


## {point index, value per shot in damage, landed} of the best point, fire included for HE.
func best(target: Ship, range_m: float, aspect_deg: float) -> Dictionary:
	var v := values(range_m, aspect_deg, comp_weights(target, shell.damage))
	var is_he := shell.type == ShellParams.ShellType.HE
	var bi := -1
	var bv := -INF
	for k in points.size():
		var val: float = v[2 * k] * shell.damage
		if is_he:
			val += BotGunnery._fire_chance(shell, target, points[k]) * BotGunnery.fire_dps(target) \
				* BotGunnery.fire_burn_s(target) * v[2 * k + 1]
		if val > bv:
			bv = val
			bi = k
	return {"point": bi, "value": bv, "damage": v[2 * bi] * shell.damage if bi >= 0 else 0.0,
		"landed": v[2 * bi + 1] if bi >= 0 else 0.0}


func raw_bytes() -> int:
	return buckets.size() * points.size() * STRIDE * 4


## Bytes if every value were a u8 (the shipping encoding to aim for).
func u8_bytes() -> int:
	return buckets.size() * points.size() * STRIDE


## Points within `tol` of their bucket's best for this shell at full pools: how many the table needs.
func useful(target: Ship, tol: float) -> PackedInt32Array:
	var keep := PackedInt32Array()
	keep.resize(points.size())
	var w := comp_weights(target, shell.damage)
	for ri in ranges.size():
		for ai in n_aspect:
			var v := values(ranges[ri], BotGunnery._aspect_center(ai), w)
			var top := 0.0
			for k in points.size():
				top = maxf(top, v[2 * k])
			if top <= 0.0:
				continue
			for k in points.size():
				if v[2 * k] >= top * (1.0 - tol):
					keep[k] += 1
	return keep


## The four (bucket, weight) corners around (range, aspect).
func _corners(range_m: float, aspect_deg: float) -> Array:
	var out := []
	if ranges.is_empty():
		return out
	var rf := _frac(ranges, range_m)
	var centers := PackedFloat32Array()
	for ai in n_aspect:
		centers.append(BotGunnery._aspect_center(ai))
	var af := _frac(centers, aspect_deg)
	for corner in 4:
		var wt: float = (rf.y if corner & 1 else 1.0 - rf.y) * (af.y if corner >> 1 else 1.0 - af.y)
		var key: int = mini(int(rf.x) + (corner & 1), ranges.size() - 1) * n_aspect + mini(int(af.x) + (corner >> 1), n_aspect - 1)
		if wt <= 0.0:
			continue
		# A bucket still being built leaves the answer to the solver rather than a skewed blend.
		if not buckets.has(key):
			return []
		out.append([key, wt])
	return out


## best(), but points are visited by full-pool value and the walk stops once the next point's full value
## cannot beat the best saturated one. Returns best()'s dict plus "visited".
func best_sorted(target: Ship, range_m: float, aspect_deg: float) -> Dictionary:
	var cs := _corners(range_m, aspect_deg)
	if cs.is_empty():
		return {"point": -1, "value": 0.0, "damage": 0.0, "landed": 0.0, "visited": 0}
	var n := points.size()
	var is_he := shell.type == ShellParams.ShellType.HE
	var fire_k: float = BotGunnery.fire_dps(target) * BotGunnery.fire_burn_s(target) if is_he else 0.0
	var raw_fire: float = BotGunnery._raw_fire_chance(shell, target) if is_he else 0.0
	var ub := PackedFloat32Array()
	ub.resize(n)
	var landed := PackedFloat32Array()
	landed.resize(n)
	for c in cs:
		var f: PackedFloat32Array = full[c[0]]
		var b: PackedFloat32Array = buckets[c[0]]
		for k in n:
			ub[k] += f[k] * c[1]
			landed[k] += maxf(b[k * STRIDE + N_COMP], 0.0) * c[1]
	var order := range(n)
	var key := PackedFloat32Array()
	key.resize(n)
	for k in n:
		key[k] = ub[k] * shell.damage + raw_fire * fire_k * landed[k]
	order.sort_custom(func(a, b): return key[a] > key[b])
	var w := comp_weights(target, shell.damage)
	var bi := -1
	var bv := -INF
	var bd := 0.0
	var visited := 0
	for k in order:
		if key[k] <= bv:
			break
		visited += 1
		var v := 0.0
		for c in cs:
			var b: PackedFloat32Array = buckets[c[0]]
			var acc := 0.0
			for ci in N_COMP:
				acc += maxf(b[k * STRIDE + ci], 0.0) * w[ci]
			v += acc * c[1]
		var dmg: float = v * shell.damage
		var val: float = dmg + (BotGunnery._fire_chance(shell, target, points[k]) * fire_k * landed[k] if is_he else 0.0)
		if val > bv:
			bv = val
			bi = k
			bd = dmg
	return {"point": bi, "value": bv, "damage": bd, "landed": landed[bi] if bi >= 0 else 0.0, "visited": visited}
