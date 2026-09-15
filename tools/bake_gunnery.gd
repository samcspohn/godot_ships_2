class_name GunneryBake
extends Node3D

## Offline bake of BotGunnery lattices, one file per hull scene next to it:
##   make bake                       (all hulls under assets/Ships, skipping up-to-date)
##   make bake ARGS="--force res://assets/Ships/Yamato/Yamato.tscn"
##
## Runs inside one physics frame: headless boots get exactly one.

const SHIPS_DIR := "res://assets/Ships"
const COARSE_PENS := [30, 60, 100, 150, 200, 260, 330, 420, 520, 650, 800, 1000, 1300, 1700]
const BISECT_MM: float = 2.0
const HULL_SPACING_M: float = 3000.0
const RANGE_STEP_M: float = 250.0

## The survey space: the target's broadphase box and nothing else, so the
## terrain ray finds no turret colliders and no other hull is in the way.
static var _survey_space: RID = RID()
static var _survey_obbs: Dictionary = {}
static var _survey_shapes: Array = []

var _hulls: Array = []
var _to_bake: Array = []
var _owner: Ship = null
var _force: bool = false
var _done: bool = false
var _t0: int = Time.get_ticks_msec()


func _ready() -> void:
	var paths: Array = []
	for a in OS.get_cmdline_user_args():
		if a == "--force":
			_force = true
		elif String(a).ends_with(".tscn"):
			paths.append(String(a))
	# Every hull is loaded so the reference shell and speeds do not depend on
	# which hulls are being baked; only `paths` are written.
	var all := _all_hull_scenes()
	for p in all:
		var ship := _spawn(p, Vector3(_hulls.size() * HULL_SPACING_M, 0.0, 0.0))
		if ship != null:
			_hulls.append(ship)
			if paths.is_empty() or paths.has(p):
				_to_bake.append(ship)
	if not _hulls.is_empty():
		# The walk needs a real owner that is not the target, or it skips the OBB test.
		_owner = _spawn((_hulls[0] as Ship).scene_file_path, Vector3(-HULL_SPACING_M, 0.0, 0.0))
	set_physics_process(true)


func _spawn(path: String, at: Vector3) -> Ship:
	var ps = load(path)
	if ps == null or not (ps is PackedScene):
		return null
	var inst = (ps as PackedScene).instantiate()
	if not (inst is Ship):
		inst.free()
		return null
	add_child(inst)
	inst.freeze = true
	inst.global_position = at
	inst.set_physics_process(false)
	return inst


static func _all_hull_scenes() -> Array:
	var out: Array = []
	var dir := DirAccess.open(SHIPS_DIR)
	if dir == null:
		return out
	for sub in dir.get_directories():
		var d := DirAccess.open(SHIPS_DIR + "/" + sub)
		if d == null:
			continue
		for f in d.get_files():
			if f.ends_with(".tscn"):
				out.append(SHIPS_DIR + "/" + sub + "/" + f)
	out.sort()
	return out


func _physics_process(_delta: float) -> void:
	if _done:
		return
	_done = true
	if _hulls.is_empty():
		print("bake: no hull scenes")
		get_tree().quit(1)
		return
	for h in _hulls:
		_force_turrets(h)
	_force_turrets(_owner)
	survey_space_state(_hulls[0])
	var shells := _collect_shells()
	var ref := _reference_shell(shells)
	if ref == null:
		print("bake: no AP shell to use as reference")
		get_tree().quit(1)
		return
	var v_ref := _reference_speeds(shells)
	var om_max: float = 0.0
	for sh in shells:
		if (sh as ShellParams).type == ShellParams.ShellType.AP:
			om_max = maxf(om_max, float(sh.overmatch))
	print("bake: %d hulls, %d shells, reference %.0fmm %.0fkg, descent buckets %d" % [
		_hulls.size(), shells.size(), ref.caliber, ref.mass, v_ref.size()])
	var cols: PackedStringArray = []
	for i in v_ref.size():
		cols.append("%.1fdeg:%.0f" % [BotGunnery._descent_center(i), v_ref[i]])
	print("bake: reference speeds " + " ".join(cols))
	for h in _to_bake:
		_bake(h, ref, v_ref, om_max)
	_free_survey_space()
	print("bake: done in %.1f s" % ((Time.get_ticks_msec() - _t0) / 1000.0))
	get_tree().quit()


## Turret armour is set up deferred, which never runs in a one-frame boot.
static func _force_turrets(n: Node) -> void:
	if n is Turret and (n as Turret).armor_system == null:
		(n as Turret).initialize_armor_system()
	for c in n.get_children():
		_force_turrets(c)


## Every shell aboard the loaded hulls; main-battery shells first.
func _collect_shells() -> Array:
	var seen := {}
	var out: Array = []
	for main in [true, false]:
		for h in _hulls:
			var params: Array = []
			if main and h.artillery_controller != null:
				params.append(h.artillery_controller.get_params())
			if not main and h.secondary_controller != null:
				for sc in h.secondary_controller.sub_controllers:
					params.append(sc.get_params())
			for gp in params:
				if gp == null:
					continue
				for sh in [gp.shell1, gp.shell2]:
					if sh != null and not seen.has(sh.get_instance_id()):
						seen[sh.get_instance_id()] = true
						sh.set_meta("bake_main", main)
						out.append(sh)
	return out


## The main-battery AP shell of median calibre: its T/D deflection and fuse
## stand in for every shell.
static func _reference_shell(shells: Array) -> ShellParams:
	var ap: Array = []
	for sh in shells:
		if (sh as ShellParams).type == ShellParams.ShellType.AP and sh.caliber > 0.0 \
				and sh.get_meta("bake_main", false):
			ap.append(sh)
	if ap.is_empty():
		for sh in shells:
			if (sh as ShellParams).type == ShellParams.ShellType.AP and sh.caliber > 0.0:
				ap.append(sh)
	if ap.is_empty():
		return null
	ap.sort_custom(func(a, b): return a.caliber < b.caliber)
	return ap[ap.size() / 2]


## Median striking speed per descent bucket over every shell's real trajectory.
static func _reference_speeds(shells: Array) -> PackedFloat32Array:
	var edges := BotGunnery.descent_edges()
	var samples: Array = []
	for i in edges.size():
		samples.append([])
	for sh in shells:
		var r: float = RANGE_STEP_M
		while r <= BotGunnery.RANGE_TOP_M:
			var l: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(
				Vector3(0.0, BotGunnery.GUN_HEIGHT_M, 0.0), Vector3(r, 0.0, 0.0), sh)
			if l.is_empty() or not l[0]:
				break
			var v: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(l[0], l[1], sh)
			var di := BotGunnery._descent_index(rad_to_deg(atan2(-v.y, Vector2(v.x, v.z).length())))
			if di >= 0:
				samples[di].append(v.length())
			r += RANGE_STEP_M
	var out := PackedFloat32Array()
	out.resize(edges.size())
	for i in edges.size():
		var s: Array = samples[i]
		if s.is_empty():
			out[i] = -1.0
			continue
		s.sort()
		out[i] = s[s.size() / 2]
	for i in edges.size():
		if out[i] > 0.0:
			continue
		var best := -1.0
		var best_d := 1 << 30
		for j in edges.size():
			if out[j] > 0.0 and absi(j - i) < best_d:
				best_d = absi(j - i)
				best = out[j]
		out[i] = best if best > 0.0 else 500.0
	return out


static func _up_to_date(path: String, md5: String) -> bool:
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return false
	var d = f.get_var()
	return d is Dictionary and int(d.get("version", -1)) == BotGunnery.SOLVER_VERSION \
		and String(d.get("glb_md5", "")) == md5


func _bake(hull: Ship, ref: ShellParams, v_ref: PackedFloat32Array, om_max: float) -> void:
	var path := BotGunnery.table_path(hull)
	var md5 := BotGunnery.hull_md5(hull)
	if not _force and _up_to_date(path, md5):
		print("bake: %s up to date" % path)
		return
	var pm = ProjectileManager.get_raw()
	var space := survey_space_state(hull)
	if space == null:
		print("bake: %s has no survey space (armour not registered?)" % hull.scene_file_path)
		return
	var aspects := BotGunnery._aspect_edges().size()
	var descents := BotGunnery.descent_edges().size()
	var table := {
		"version": BotGunnery.SOLVER_VERSION,
		"glb_md5": md5,
		"hull": hull.scene_file_path,
		"aspect_edges": BotGunnery._aspect_edges(),
		"descent_edges": BotGunnery.descent_edges(),
		"ref_caliber": ref.caliber,
		"ref_mass": ref.mass,
		"v_ref": v_ref,
		"om_max": om_max,
		"buckets": {},
	}
	var t0 := Time.get_ticks_msec()
	var walks: int = 0
	for ai in aspects:
		for di in descents:
			var geo := BotGunnery.build_lattice(hull, ai, di)
			if geo.is_empty():
				continue
			var res: Dictionary = pm.survey_sweep(hull, _owner, ref,
				hull.global_basis * (geo["dir"] as Vector3), v_ref[di], geo["points"], space,
				PackedFloat32Array(COARSE_PENS), BISECT_MM, om_max)
			if res.is_empty():
				continue
			walks += int(res["walks"])
			table["buckets"][BotGunnery.bucket_id(ai, di)] = {
				"nx": geo["nx"], "ny": geo["ny"], "rect": geo["rect"], "dir": geo["dir"],
				"cells": res["cells"], "prof_off": res["prof_off"], "bp_mm": res["bp_mm"],
				"bp_code": res["bp_code"], "prof_off_om": res["prof_off_om"],
				"bp_mm_om": res["bp_mm_om"], "bp_code_om": res["bp_code_om"],
				"first_mm": res["first_mm"],
				"first_flags": res["first_flags"],
			}
		print("  %s aspect %2d/%d  %.1f s  %d walks" % [hull.scene_file_path.get_file(),
			ai + 1, aspects, (Time.get_ticks_msec() - t0) / 1000.0, walks])
	if (table["buckets"] as Dictionary).is_empty():
		print("bake: %s produced no lattices (no armour or AABB?); not written" % path)
		return
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		print("bake: cannot write %s" % path)
		return
	f.store_var(table)
	f.close()
	print("bake: %s  %d buckets  %d walks  %.1f s  %d bytes" % [path,
		(table["buckets"] as Dictionary).size(), walks,
		(Time.get_ticks_msec() - t0) / 1000.0, FileAccess.get_file_as_bytes(path).size()])


# ----------------------------------------------------------- survey space

## Null on the call that creates the space; call again.
static func survey_space_state(target: Ship) -> PhysicsDirectSpaceState3D:
	if not is_instance_valid(target):
		return null
	if not _survey_space.is_valid():
		_survey_space = PhysicsServer3D.space_create()
		PhysicsServer3D.space_set_active(_survey_space, true)
		return null
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
	PhysicsServer3D.body_set_collision_layer(body, PrecisionPhysicsWorld.OBB_COLLISION_LAYER)
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
