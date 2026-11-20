class_name PointTables
extends RefCounted
## Main and secondary point tables: keys, loading, the native build queue, live target inputs.

## "shooter|ammo|target" -> PointTable, or null once a load found nothing.
static var _point_tables: Dictionary = {}
static var _point_tables_on: int = -1
## Main-battery point tables: built in the match by the native worker unless SHIPS_POINT_TABLE=0. With
## --point-table-cache (sims) or SHIPS_POINT_TABLE=1, prebuilt user:// tables are used and any pair without one is
## built in the match and saved.
const PT_OFF := 0
const PT_FILES := 1
const PT_RUNTIME := 2


static func mode() -> int:
	if _point_tables_on < 0:
		var v := OS.get_environment("SHIPS_POINT_TABLE")
		if v == "0" or v == "off":
			_point_tables_on = PT_OFF
		elif v == "1" or v == "file" or CmdArgs.has("--point-table-cache"):
			_point_tables_on = PT_FILES
		else:
			_point_tables_on = PT_RUNTIME
	return _point_tables_on


static func point_tables_on() -> bool:
	return mode() != PT_OFF


static var _rt_keys: PackedStringArray = PackedStringArray()
## Keys with a user:// file not yet loaded, and keys built in the match that are to be saved when done.
static var _rt_pending_file: Dictionary = {}
static var _rt_save: Dictionary = {}
static var _rt_done: Dictionary = {}
## Per key: sim seconds after submit when its two longest ranges were ready.
static var _rt_open: Dictionary = {}
## Per range rank from the top: sim seconds after submit when every table had it.
static var _rt_rank_sim: PackedFloat64Array = PackedFloat64Array()
## Per key: sim seconds from its opening rows being ready to its first lookup (negative: looked up before).
static var _rt_margin: Dictionary = {}
static var _rt := {"threads": 0, "jobs": 0, "submit_sim": -1.0, "submit_wall_ms": 0, "submit_cost_ms": 0,
	"done_sim": -1.0, "done_wall_ms": -1.0, "first_query_sim": -1.0, "first_query_served": false,
	"queries": 0, "served": 0, "fallback": 0, "files": 0, "saved": 0, "poll_ms": 0.0, "lookup_ms": 0.0, "buckets": 0, "walks": 0}


## Queues every (shooter main battery shell, enemy hull) table for `ships` on the native worker. Called once
## the match's ships exist; repeat calls only add pairs not yet queued.
static func start_runtime_tables(ships: Array) -> void:
	var pm := GunneryModel.native_pm()
	if pm == null:
		return
	var t0 := Time.get_ticks_msec()
	var threads: int = int(OS.get_environment("SHIPS_POINT_THREADS")) if OS.has_environment("SHIPS_POINT_THREADS") else 4
	pm.point_worker_start(threads)
	_rt["threads"] = threads
	for shooter in ships:
		if not (shooter is Ship) or shooter.artillery_controller == null:
			continue
		for target in ships:
			if not (target is Ship) or target.team == null or shooter.team == null \
					or target.team.team_id == shooter.team.team_id:
				continue
			for ammo in 2:
				var key := point_key(shooter, target, ammo)
				# false = a file-mode miss from before queueing (v4 warm); still build it.
				if _point_tables.get(key, false) or _rt_pending_file.has(key):
					continue
				var path := PointTable.cache_path(key)
				if mode() == PT_FILES and FileAccess.file_exists(path):
					# Loaded on first use (table_key).
					_rt_pending_file[key] = true
					_rt_open[key] = 0.0
					_rt["files"] = int(_rt["files"]) + 1
					continue
				var job: Dictionary = PointTable.runtime_job(shooter, target, ammo)
				if job.is_empty() or not pm.point_job_submit(key, target, job["shell"], job):
					_point_tables[key] = false
					continue
				_point_tables[key] = true
				_rt_keys.append(key)
				if mode() == PT_FILES:
					_rt_save[key] = {"points": job["points"], "ranges": job["ranges"], "n_aspect": (job["aspects"] as PackedFloat64Array).size(),
						"path": path}
			_queue_secondary_tables(pm, shooter, target)
	_rt["jobs"] = _rt_keys.size()
	print("point tables (%s): %d jobs queued, %d from files, for %d ships" % [["off", "files", "runtime"][mode()], _rt_keys.size(), int(_rt["files"]), ships.size()])
	if float(_rt["submit_sim"]) < 0.0:
		_rt["submit_sim"] = SimClock.now()
		_rt["submit_wall_ms"] = Time.get_ticks_msec()
	_rt["submit_cost_ms"] = int(_rt["submit_cost_ms"]) + Time.get_ticks_msec() - t0
	if _rt_keys.is_empty() and CmdArgs.has("--point-tables-only"):
		print("point tables: all %d from files; quitting" % int(_rt["files"]))
		(Engine.get_main_loop() as SceneTree).quit()


static var _sec_shell_keys: Dictionary = {}

## shell_key for secondary sub-battery `i`'s `ammo`.
static func sec_shell_key(shooter: Ship, i: int, ammo: int) -> String:
	var iid: int = (shooter.get_instance_id() * 64 + i) * 2 + ammo
	if _sec_shell_keys.has(iid):
		return _sec_shell_keys[iid]
	var b = GunneryModel.sec_battery(shooter, i, 0.0)
	var sh: ShellParams = null if b == null else b["shells"][ammo]
	if sh == null:
		_sec_shell_keys[iid] = ""
		return ""
	var parts := ["sec"]
	for prop in _KEY_SHELL_PROPS:
		parts.append([prop, sh.get(prop)])
	for r in PointTable.RANGES_M:
		var m = GunneryModel.sec_battery(shooter, i, r)
		if m == null:
			break
		parts.append(GunneryModel.half_disp(m, r).snappedf(0.01))
		parts.append(snappedf(float(m["sigma"]), 0.001))
	var key := var_to_bytes(parts).hex_encode().md5_text()
	_sec_shell_keys[iid] = key
	return key


## The native key of `shooter`'s secondary sub-battery `i` `ammo` table against `target`, "" while none was queued.
static func sec_point_key(shooter: Ship, i: int, ammo: int, target: Ship) -> String:
	var sk := sec_shell_key(shooter, i, ammo)
	if sk == "":
		return ""
	var key := "%s|%s" % [sk, target.scene_file_path]
	return key if _point_tables.get(key, false) else ""


## Barrels bearing per sub-battery of `shooter`'s scene at every 0.5 degree of bearing 0..180, then all of them.
static var _sec_counts: Dictionary = {}

static func sec_counts(shooter: Ship) -> Array:
	var sec = shooter.secondary_controller
	var c = _sec_counts.get(shooter.scene_file_path)
	if c != null:
		return c
	var rows: Array = []
	for k in 361:
		rows.append(GunneryModel._sec_bearing(shooter, sec, k * 0.5))
	rows.append(GunneryModel._sec_bearing(shooter, sec, NAN))
	var out: Array = []
	for i in sec.sub_controllers.size():
		var col := PackedInt32Array()
		for row in rows:
			col.append((row as PackedInt32Array)[i] if i < (row as PackedInt32Array).size() else 0)
		out.append(col)
	_sec_counts[shooter.scene_file_path] = out
	return out


## SecCache's pack: `shooter`'s secondaries on `target` as it is now (SkillStance's native secondary dps).
static func sec_pack(shooter: Ship, target: Ship) -> Dictionary:
	var sec = shooter.secondary_controller
	var bats := []
	var counts := sec_counts(shooter)
	for i in sec.sub_controllers.size():
		var b = GunneryModel.sec_battery(shooter, i, 0.0)
		if b == null:
			continue
		var keys := PackedStringArray()
		var q := PackedFloat64Array()
		for ammo in 2:
			var sh: ShellParams = b["shells"][ammo]
			keys.append(sec_point_key(shooter, i, ammo, target) if sh != null else "")
			var he: bool = sh != null and sh.type == ShellParams.ShellType.HE
			var raw: float = GunneryModel.raw_fire_chance(sh, target) if he else 0.0
			q.append_array([sh.damage if sh != null else 0.0, raw, GunneryModel.fire_dps(target) * GunneryModel.fire_burn_s(target) if he else 0.0,
				HPManager.size_mod(target.mass, sh.caliber) if sh != null else 1.0, raw])
		var sc = sec.sub_controllers[i]
		bats.append({"keys": keys, "q": q, "reload": sc.get_params().reload_time, "range": sc.get_params()._range,
			"counts": counts[i]})
	var live := live_inputs(target, 0.0)
	return {"sat": live[1], "fires": live[2], "bats": bats}


## Records when tables open and finish (the worker writes buckets into the native store itself); the server calls
## this about once a second.
static func poll_runtime_tables() -> void:
	if _rt_keys.size() == _rt_done.size():
		return
	var pm := GunneryModel.native_pm()
	var t0 := Time.get_ticks_usec()
	for key in _rt_keys:
		if _rt_done.has(key):
			continue
		var st: PackedFloat64Array = pm.point_job_status(key)
		if st.size() >= 5 and st[4] >= 0.0 and not _rt_open.has(key):
			_rt_open[key] = SimClock.now() - float(_rt["submit_sim"])
		if st.size() >= 4 and st[1] > 0.0 and st[0] >= st[1]:
			_rt_done[key] = true
			if _rt_save.has(key):
				_save_built_table(key, _rt_save[key])
				_rt_save.erase(key)
			_rt["walks"] = int(_rt["walks"]) + int(st[3])
			_rt["buckets"] = int(_rt["buckets"]) + int(st[1])
	var ranks: PackedFloat64Array = pm.point_worker_stats().get("rank_ms", PackedFloat64Array())
	if _rt_rank_sim.size() < ranks.size():
		var at := _rt_rank_sim.size()
		_rt_rank_sim.resize(ranks.size())
		for k in range(at, ranks.size()):
			_rt_rank_sim[k] = -1.0
	for k in ranks.size():
		if ranks[k] >= 0.0 and _rt_rank_sim[k] < 0.0:
			_rt_rank_sim[k] = SimClock.now() - float(_rt["submit_sim"])
	_rt["poll_ms"] = float(_rt["poll_ms"]) + (Time.get_ticks_usec() - t0) / 1000.0
	if _rt_keys.size() == _rt_done.size():
		_rt["done_sim"] = SimClock.now() - float(_rt["submit_sim"])
		_rt["done_wall_ms"] = Time.get_ticks_msec() - int(_rt["submit_wall_ms"])
		if CmdArgs.has("--point-tables-only"):
			print("point tables: %d built and saved in %d ms, %d from files; quitting" % [int(_rt["saved"]),
				int(_rt["done_wall_ms"]), int(_rt["files"])])
			(Engine.get_main_loop() as SceneTree).quit()


## start_runtime_tables for `shooter`'s secondary sub-GunneryModel.batteries against `target`'s hull.
static func _queue_secondary_tables(pm, shooter: Ship, target: Ship) -> void:
	var sec = shooter.secondary_controller
	if sec == null or not is_instance_valid(sec):
		return
	sec_counts(shooter)
	for i in sec.sub_controllers.size():
		for ammo in 2:
			var sk := sec_shell_key(shooter, i, ammo)
			if sk == "":
				continue
			var key := "%s|%s" % [sk, target.scene_file_path]
			if _point_tables.has(key):
				continue
			var path := PointTable.cache_path(key)
			if mode() == PT_FILES and FileAccess.file_exists(path):
				var b = GunneryModel.sec_battery(shooter, i, 0.0)
				if b != null and _load_file(key, b["shells"][ammo], target):
					_point_tables[key] = true
					_rt["files"] = int(_rt["files"]) + 1
					continue
			var job: Dictionary = PointTable.runtime_job(shooter, target, ammo, 700, i)
			_point_tables[key] = not job.is_empty() and pm.point_job_submit(key, target, job["shell"], job)
			if _point_tables[key]:
				_rt_keys.append(key)
				if mode() == PT_FILES:
					_rt_save[key] = {"points": job["points"], "ranges": job["ranges"], "n_aspect": (job["aspects"] as PackedFloat64Array).size(),
						"path": path}


## Per table key: whether its first query found the buckets it needed.
static var _rt_first: Dictionary = {}

## Writes a table the worker built to user:// (unpruned), via a temporary file so a sim reading it never sees half.
static func _save_built_table(key: String, meta: Dictionary) -> void:
	var t = PointTable.new()
	t.points = meta["points"]
	t.ranges = meta["ranges"]
	t.n_aspect = meta["n_aspect"]
	t.buckets = GunneryModel.native_pm().point_table_export(key)
	var path: String = meta["path"]
	var tmp := "%s.%d.tmp" % [path, OS.get_process_id()]
	if t.save(tmp) and DirAccess.rename_absolute(tmp, path) == OK:
		_rt["saved"] = int(_rt["saved"]) + 1


static func note_query(served: bool, key: String = "") -> void:
	if not point_tables_on():
		return
	if key != "" and not _rt_first.has(key):
		_rt_first[key] = served
		var now: float = SimClock.now() - float(_rt["submit_sim"])
		_rt_margin[key] = now - float(_rt_open[key]) if _rt_open.has(key) else -now
	_rt["queries"] = int(_rt["queries"]) + 1
	_rt[("served" if served else "fallback")] = int(_rt["served" if served else "fallback"]) + 1
	if float(_rt["first_query_sim"]) < 0.0:
		_rt["first_query_sim"] = SimClock.now() - float(_rt["submit_sim"])
		_rt["first_query_served"] = served


## Runtime-table timing for the match metrics; {} unless SHIPS_POINT_TABLE=runtime.
static func point_table_summary() -> Dictionary:
	if not point_tables_on():
		return {}
	var out := _rt.duplicate()
	out["mode"] = ["off", "files", "runtime"][mode()]
	var pm := GunneryModel.native_pm()
	if pm != null:
		out.merge(pm.point_worker_stats(), true)
	out["done_jobs"] = _rt_done.size()
	out["pairs_queried"] = _rt_first.size()
	out["pairs_first_served"] = _rt_first.values().count(true)
	# Sim seconds; the poll runs about once a sim second, so each is good to about a second.
	out["rank_ready_sim"] = Array(_rt_rank_sim)
	var m: Array = _rt_margin.values()
	m.sort()
	if not m.is_empty():
		out["margin_sim"] = {"min": m[0], "p10": m[int(0.1 * (m.size() - 1))], "median": m[m.size() / 2], "max": m[m.size() - 1]}
	var o: Array = _rt_open.values()
	o.sort()
	if not o.is_empty():
		out["opening_ready_sim"] = {"median": o[o.size() / 2], "max": o[o.size() - 1]}
	return out


## What a point table depends on from the shooter: the shell's ballistics and armour-walk inputs (not damage or
## fire chance, which apply at lookup) and the gun's spread at every table range after mods, plus grouping. Ships
## whose guns hash alike share tables. Cached per instance, so a mod that changes the guns mid-match is not seen.
static var _shell_keys: Dictionary = {}
const _KEY_SHELL_PROPS := ["type", "speed", "drag", "mass", "caliber", "penetration_modifier", "fuze_delay",
	"arming_threshold", "auto_bounce", "overmatch"]

static func shell_key(shooter: Ship, ammo: int) -> String:
	var iid: int = shooter.get_instance_id() * 2 + ammo
	if _shell_keys.has(iid):
		return _shell_keys[iid]
	var p: GunParams = shooter.artillery_controller.get_params()
	var sh: ShellParams = p.shell1 if ammo == 0 else p.shell2
	if sh == null:
		return ""
	var parts := []
	for prop in _KEY_SHELL_PROPS:
		parts.append([prop, sh.get(prop)])
	for r in PointTable.RANGES_M:
		var mounts := GunneryModel.batteries(shooter, GunneryModel.KIND_MAIN, r)
		if mounts.is_empty():
			break
		# Rounded: taking a toggled skill factor out and back in leaves last-bit differences.
		parts.append(GunneryModel.table_half_disp(shooter, mounts[0], r).snappedf(0.01))
		parts.append(snappedf(float(mounts[0]["sigma"]), 0.001))
	var key := var_to_bytes(parts).hex_encode().md5_text()
	_shell_keys[iid] = key
	return key


## Whether every point table `shooter` has against `target` is built, so answers from it no longer change; true
## without tables (the baked summary answers for good).
static func point_tables_ready(shooter: Ship, target: Ship) -> bool:
	if mode() == PT_OFF or shooter.artillery_controller == null:
		return true
	for ammo in 2:
		var key := point_key(shooter, target, ammo)
		if key.begins_with("|"):
			continue
		var known = _point_tables.get(key)
		if known == null:
			return false
		if known and mode() == PT_RUNTIME and not _rt_done.has(key):
			return false
	return true


## Buckets built so far across `shooter`'s main and secondary tables against `target`'s hull.
static func pair_progress(shooter: Ship, target: Ship) -> int:
	var pm := GunneryModel.native_pm()
	var keys := PackedStringArray()
	for ammo in 2:
		keys.append(point_key(shooter, target, ammo))
	var sec = shooter.secondary_controller
	if sec != null and is_instance_valid(sec):
		for i in sec.sub_controllers.size():
			for ammo in 2:
				keys.append(sec_point_key(shooter, i, ammo, target))
	var n := 0
	for key in keys:
		if key == "" or key.begins_with("|"):
			continue
		var st: PackedFloat64Array = pm.point_job_status(key)
		n += int(st[0]) if st.size() >= 1 else 0
	return n


static func point_key(shooter: Ship, target: Ship, ammo: int) -> String:
	return "%s|%s" % [shell_key(shooter, ammo), target.scene_file_path]


## The native store key of `shooter`'s `ammo` table against `target`, or "" without one. File mode loads the
## table from user:// into the store on first use.
static func table_key(shooter: Ship, target: Ship, ammo: int) -> String:
	var key := point_key(shooter, target, ammo)
	var known = _point_tables.get(key)
	if known != null:
		return key if known else ""
	if mode() == PT_RUNTIME:
		return ""
	_rt_pending_file.erase(key)
	var p: GunParams = shooter.artillery_controller.get_params()
	var shell: ShellParams = p.shell1 if ammo == 0 else p.shell2
	if not _load_file(key, shell, target):
		push_warning("PointTables: no point table for %s" % key)
		_point_tables[key] = false
		return ""
	_point_tables[key] = true
	return key


## Puts the user:// table for `key` into the native store; false without a readable one.
static func _load_file(key: String, shell: ShellParams, target: Ship) -> bool:
	var t = PointTable.load_from(PointTable.cache_path(key), shell) if shell != null else null
	if t == null:
		return false
	var aspects := PackedFloat64Array()
	for ai in t.n_aspect:
		aspects.append(GunneryModel.aspect_center(ai))
	GunneryModel.native_pm().point_table_put(key, t.ranges, aspects, t.points, PointTable.N_COMP, t.buckets,
		PointTable.sections_of(target, t.points), PointTable.sat_weights())
	return true


## Per (target, shell damage, saturation signature): [component weights, fire array] for point_best.
static var _pt_live: Dictionary = {}

## Bit i set: PointTable.SAT_SECTIONS[i]'s pool is spent.
static func saturation_mask(target: Ship) -> int:
	var hp = target.health_controller
	if hp == null:
		return 0
	var mask := 0
	for i in PointTable.SAT_SECTIONS.size():
		var part: HpPartMod = null
		match PointTable.SAT_SECTIONS[i]:
			int(ArmorPart.Type.CASEMATE): part = hp.casemate
			int(ArmorPart.Type.BOW): part = hp.bow
			int(ArmorPart.Type.STERN): part = hp.stern
			int(ArmorPart.Type.SUPERSTRUCTURE): part = hp.superstructure
		if part != null and part.current_pool <= 0.0:
			mask |= 1 << i
	return mask


## What a point-table answer depends on in `target`: its saturation mask and which fires burn.
static func point_sig(target: Ship) -> int:
	var sig := saturation_mask(target)
	var fm = target.fire_manager
	if fm != null:
		for f in fm.fires:
			sig = sig * 2 + int(f != null and (f as Fire).lifetime > 0.0)
	return sig


static func live_inputs(target: Ship, damage: float) -> Array:
	var sig := point_sig(target)
	var ck := "%d|%d" % [target.get_instance_id(), roundi(damage)]
	var c: Array = _pt_live.get(ck, [])
	if not c.is_empty() and int(c[0]) == sig:
		return c
	var fires := PackedFloat32Array()
	if target.fire_manager != null:
		for f in target.fire_manager.fires:
			if f != null:
				var pos: Vector3 = (f as Fire).position
				fires.append_array([pos.x, pos.y, pos.z, 1.0 if (f as Fire).lifetime > 0.0 else 0.0])
	c = [sig, saturation_mask(target), fires]
	if _pt_live.size() > 512:
		_pt_live.clear()
	_pt_live[ck] = c
	return c
