extends Node3D

## Aim-point probe: runs the REAL armour walk against a real hull.
##
## Calls ProjectileManager.get_raw().sim_process_travel() - the NATIVE armour
## walk live shells go through - directly, and drives BotGunnery (which walks
## its lattices through the same path) to completion to inspect its answers.
##
## Not the GDScript ArmorInteraction autoload, which is the pre-port
## implementation and does not answer the same: a rig that measured THAT would be
## checking the solver against a walk no shell in the game has taken since the
## native cutover.
##
## Needs a live scene: the precision bodies only exist once a Ship has entered
## the tree and registered itself (Ship._ready), and the broadphase ray needs a
## real space state. Run it with
##
##   godot --headless --path . res://test/aim_probe.tscn -- <target.tscn> <shooter.tscn>
##
## Two things this rig knows that cost an afternoon to find out. The shell must
## have a non-null owner, because process_travel() treats an owner-less
## projectile as visual-only and returns null without touching a ship. And the
## work has to happen inside _physics_process on the first frame: awaiting
## several frames never returns, because something in the full headless boot
## stops the loop advancing after frame one.

const DEFAULT_TARGET := "res://assets/Ships/Bismarck/Bismarck3.tscn"
const DEFAULT_SHOOTER := "res://assets/Ships/Bismarck/Bismarck3.tscn"

## Aspect is measured the way BotGunnery measures it: 0 is bow-on, 90 abeam.
const ASPECTS_DEG := [90, 60, 30]
const RANGES_M := [3000.0, 9000.0, 16000.0]

## Candidate aim points: along the keel as a fraction of length, and up from the
## waterline in metres. Height is what decides belt versus upper belt versus
## superstructure, and how much of a salvo lands in the sea.
const ALONG_FRACS := [-0.2, 0.0, 0.2]
const HEIGHT_M := [0.5, 2.0, 4.0, 7.0, 11.0]

## Payouts by result, from ProjectileManager::process_hit.
const PAYOUT := {
	"CITADEL": 1.0, "CITADEL_OVERPEN": 0.5, "PENETRATION": 1.0 / 3.0,
	"PARTIAL_PEN": 0.0667, "OVERPENETRATION": 0.1,
	"SHATTER": 0.0, "RICOCHET": 0.0, "WATER": 0.0, "TERRAIN": 0.0,
}

var _target: Ship
var _shooter: Ship
## The solver script, loaded once. The walks below run in ITS space, not the
## live one - see BotGunnery._survey_space for why that is not the same world.
var _gunnery = load("res://src/ship/bot_behavior/bot_gunnery.gd")
var _out: FileAccess
var _done: bool = false


## How long to wait for deferred turret setup before giving up and reporting
## what is there. A bound rather than an open wait, so a hull whose turrets
## never register fails with a readable table instead of never finishing.
const MAX_STARTUP_FRAMES := 10
var _frames_waited: int = 0


## Run the turret's deferred armour setup NOW, if it has not run yet.
##
## Turret.initialize_armor_system() is call_deferred, so on the frame the ships
## are added a turret is still a raw GLB collider with no armour parts at all -
## and firing then measures the rig's own startup rather than the ship. Waiting
## for it is not an option: this rig gets exactly one physics frame in headless
## (see the note at the top of the file), so a loop that awaits until the parts
## appear waits forever and the test never runs.
##
## Calling it directly is safe here because the probe quits immediately after.
## In a real match the deferred call is the one that runs.
func _force_turret_setup(turrets: Array[Turret]) -> void:
	if _turrets_ready():
		return
	for t in turrets:
		if t.armor_system == null:
			t.initialize_armor_system()
	_say("forced deferred turret setup for %d turret(s)" % turrets.size())


## True once at least one turret on the target has had its GLB collider
## converted into an ArmorPart.
func _turrets_ready() -> bool:
	if _target == null:
		return false
	for p: ArmorPart in _target.armor_parts:
		if PrecisionPhysicsWorld.is_turret_part(p):
			return true
	return false


var _t0: int = Time.get_ticks_msec()
func _ms() -> int: return Time.get_ticks_msec() - _t0

func _ready() -> void:
	_out = FileAccess.open("res://_aim_probe_out.txt", FileAccess.WRITE)
	var args := OS.get_cmdline_user_args()
	var target_path := DEFAULT_TARGET
	var shooter_path := DEFAULT_SHOOTER
	if args.size() >= 1 and String(args[0]).ends_with(".tscn"):
		target_path = args[0]
	if args.size() >= 2 and String(args[1]).ends_with(".tscn"):
		shooter_path = args[1]

	_target = load(target_path).instantiate()
	add_child(_target)
	_target.freeze = true
	_target.global_position = Vector3.ZERO
	_target.set_physics_process(false)

	_shooter = load(shooter_path).instantiate()
	add_child(_shooter)
	_shooter.freeze = true
	_shooter.global_position = Vector3(0.0, 0.0, 20000.0)
	_shooter.set_physics_process(false)

	_say("[%d ms] probe: %s  <-  %s  (instance %d)" % [_ms(), target_path.get_file(), shooter_path.get_file(), get_instance_id()])
	set_physics_process(true)


func _physics_process(_delta: float) -> void:
	if _done:
		return
	_done = true
	if OS.get_cmdline_user_args().has("--sec"):
		_secondary_test()
	elif OS.get_cmdline_user_args().has("--table"):
		_table_test()
	elif OS.get_cmdline_user_args().has("--turret"):
		_turret_test()
	else:
		_run()


## Drive the secondary solver to completion at a few geometries and report
## what it chose, per mount.
func _secondary_test() -> void:
	var G = load("res://src/ship/bot_behavior/bot_gunnery.gd").new()
	var sec = _shooter.secondary_controller
	if sec == null or sec.sub_controllers.is_empty():
		_say("shooter has no secondary battery")
		_out.close()
		get_tree().quit()
		return
	_say("")
	_say("secondary battery of %s:" % _shooter.scene_file_path.get_file())
	for sc in sec.sub_controllers:
		var sp: GunParams = sc.get_params()
		_say("  %2d x %5.0f mm  reload %5.2f s  range %5.0f m  ->  %.2f shells/s   AP %s / HE %s" % [
			(sc.guns as Array).size(), sp.shell1.caliber, sp.reload_time, sp._range,
			float((sc.guns as Array).size()) / sp.reload_time,
			"%.0f dmg" % sp.shell1.damage, "%.0f dmg" % sp.shell2.damage])
	for pr in [[1500.0, 90.0], [3500.0, 90.0], [4500.0, 90.0], [1500.0, 22.5], [3500.0, 22.5]]:
		var ang0 := deg_to_rad(float(pr[1]))
		_shooter.global_transform = Transform3D(Basis(),
			_target.global_position + Vector3(sin(ang0), 0.0, -cos(ang0)) * float(pr[0]))
		_shooter.force_update_transform()
		var kk = G._bucket_key(_shooter, _target, G.KIND_SECONDARY)
		var rng: float = G._range_center(G.KIND_SECONDARY, int(kk[G.KEY_RANGE]))
		var asp: float = G._aspect_center(int(kk[G.KEY_ASPECT]))
		var bats: Array = G._batteries(_shooter, G.KIND_SECONDARY, rng)
		_say("")
		_say("=== asked %.0f m %.1f deg -> bucket %.0f m %.1f deg : %d of %d mounts reach ===" % [
			float(pr[0]), float(pr[1]), rng, asp, bats.size(), sec.sub_controllers.size()])
		if bats.is_empty():
			_say("  nothing aboard reaches this far")
			continue
		var sol := _drive(G, G.KIND_SECONDARY, 4000)
		_say("  solver: %s at x=%5.1f y=%5.2f z=%6.1f  probed=%s  walks=%d in %.1f ms" % [
			"AP" if int(sol.get("ammo", 0)) == 0 else "HE",
			(sol.get("offset", Vector3.ZERO) as Vector3).x,
			(sol.get("offset", Vector3.ZERO) as Vector3).y,
			(sol.get("offset", Vector3.ZERO) as Vector3).z,
			sol.get("probed", false), _last_walks, _last_ms])
	var shells: Array = []
	for sc in sec.sub_controllers:
		shells.append((sc.get_params() as GunParams).shell1)
		shells.append((sc.get_params() as GunParams).shell2)
	_say("")
	_remap_report(G, G.KIND_SECONDARY, shells)
	_say("")
	_say("[%d ms] quitting" % _ms())
	_out.close()
	get_tree().quit()


## Per range bucket: fall angle, striking speed, and which bucket's lattice
## answers for it after BotGunnery merges alike trajectories.
func _remap_report(G, kind: int, shells: Array) -> void:
	for sh in shells:
		if sh == null:
			continue
		var edges: PackedFloat64Array = G._range_edges(kind)
		var cols: PackedStringArray = []
		for i in edges.size():
			var r: float = G._range_center(kind, i)
			var l: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(
				Vector3(0, G.GUN_HEIGHT_M, 0), Vector3(r, 0, 0), sh)
			var desc := "-"
			if not l.is_empty() and l[0]:
				var v: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(l[0], l[1], sh)
				desc = "%.0fdeg/%.0fm/s" % [rad_to_deg(atan2(-v.y, Vector2(v.x, v.z).length())), v.length()]
			cols.append("%d(%.0fm %s)>%d" % [i, r, desc, G._canonical_range(sh, kind, i)])
		_say("range remap %.0fmm %s:" % [sh.caliber, "AP" if sh.type == ShellParams.ShellType.AP else "HE"])
		_say("   " + " ".join(cols))


var _last_walks: int = 0
var _last_ms: float = 0.0

## Ask and drain until the answer is complete, simulating physics ticks.
func _drive(G, kind: int, max_ticks: int) -> Dictionary:
	var sol := {}
	var t_total: int = 0
	_last_walks = 0
	for tick in max_ticks:
		var before := _walked_total(G)
		var t0 := Time.get_ticks_usec()
		if kind == G.KIND_SECONDARY:
			sol = G.solve_secondary(_shooter, _target)
		else:
			sol = G.solve(_shooter, _target)
		G._budget_frame = -1
		G._drain()
		t_total += Time.get_ticks_usec() - t0
		_last_walks += _walked_total(G) - before
		if bool(sol.get("probed", false)):
			break
	_last_ms = t_total / 1000.0
	return sol


func _walked_total(G) -> int:
	var n := 0
	for id in G._slabs:
		for bk in G._slabs[id]["buckets"]:
			n += int(G._slabs[id]["buckets"][bk]["walked"])
	return n


## Convergence and cost of one main-battery answer, then the answers at a few
## geometries, then an ASCII dump of one lattice.
func _table_test() -> void:
	_say("[%d ms] _table_test enter" % _ms())
	var G = load("res://src/ship/bot_behavior/bot_gunnery.gd").new()
	var a := deg_to_rad(90.0)
	_shooter.global_transform = Transform3D(Basis(),
		_target.global_position + Vector3(sin(a), 0.0, -cos(a)) * 9000.0)
	_shooter.force_update_transform()
	_say("budget %d cells/bucket/tick, cap %d walks/tick, ~%d cells/lattice" % [
		G.CELLS_PER_BUCKET_PER_TICK, G.WALKS_PER_TICK_CAP, G.LATTICE_CELLS])
	_say("tick | aim y | ammo | walked | state")
	var sol := {}
	var walks := 0
	var t_walks := 0
	for tick in 2000:
		for bot in 20:
			sol = G.solve(_shooter, _target)
		var done: bool = bool(sol.get("probed", false))
		if done or tick < 2 or tick % 5 == 0:
			_say("%4d | %5.2f | %4d | %6d | %s" % [tick,
				(sol.get("offset", Vector3.ZERO) as Vector3).y, int(sol.get("ammo", -1)),
				_walked_total(G), "SOLVED" if done else "refining"])
		if done:
			break
		var before := _walked_total(G)
		var t0 := Time.get_ticks_usec()
		G._budget_frame = -1
		G._drain()
		t_walks += Time.get_ticks_usec() - t0
		walks += _walked_total(G) - before
	if walks > 0:
		_say("")
		_say("cost: %d walks in %.1f ms = %.1f us/walk" % [walks, t_walks / 1000.0,
			float(t_walks) / walks])

	_say("")
	_say("solver answers:")
	for pr in [[6000.0, 90.0], [12000.0, 90.0], [8000.0, 22.5], [15000.0, 22.5], [3000.0, 5.0]]:
		var ang := deg_to_rad(float(pr[1]))
		_shooter.global_transform = Transform3D(Basis(),
			_target.global_position + Vector3(sin(ang), 0.0, -cos(ang)) * float(pr[0]))
		_shooter.force_update_transform()
		var s2 := _drive(G, G.KIND_MAIN, 2000)
		_say("  %6.0f m %5.1f deg -> %s  x=%5.1f y=%5.2f z=%6.1f  probed=%s  walks=%d in %.1f ms" % [
			float(pr[0]), float(pr[1]), "AP" if int(s2.get("ammo", 0)) == 0 else "HE",
			(s2.get("offset", Vector3.ZERO) as Vector3).x,
			(s2.get("offset", Vector3.ZERO) as Vector3).y,
			(s2.get("offset", Vector3.ZERO) as Vector3).z,
			s2.get("probed", false), _last_walks, _last_ms])

	_say("")
	var gp: GunParams = _shooter.artillery_controller.get_params()
	_remap_report(G, G.KIND_MAIN, [gp.shell1, gp.shell2])
	_say("")
	_dump_lattices(G)
	_say("cache files:")
	for id in G._slabs:
		var path: String = G.CACHE_DIR + id + ".bin"
		G._save_slab(G._slabs[id])
		_say("  %s  %d bytes  %d buckets" % [path, FileAccess.get_file_as_bytes(path).size(),
			(G._slabs[id]["buckets"] as Dictionary).size()])
	_say("[%d ms] quitting" % _ms())
	_out.close()
	get_tree().quit()


const CELL_GLYPH := {0: "P", 1: "p", 2: "r", 3: "o", 4: "s", 5: "C", 6: "c", 7: "~", 8: "#"}

## Every finished lattice as text: rows top-down, one glyph per cell.
func _dump_lattices(G) -> void:
	for id in G._slabs:
		var slab: Dictionary = G._slabs[id]
		for bk in slab["buckets"]:
			var b: Dictionary = slab["buckets"][bk]
			if int(b["nx"]) == 0:
				continue
			var r: Vector4 = b["rect"]
			_say("%s  aspect %.1f  range %.0f  %dx%d  u[%.0f,%.0f] v[%.0f,%.0f]  walked %d/%d" % [
				id, G._aspect_center(b["aspect"]), G._range_center(b["kind"], b["range"]),
				b["nx"], b["ny"], r.x, r.z, r.y, r.w, b["walked"], int(b["nx"]) * int(b["ny"])])
			var cells: PackedByteArray = b["cells"]
			for iy in range(int(b["ny"]) - 1, -1, -1):
				var line := ""
				for ix in int(b["nx"]):
					var c: int = cells[iy * int(b["nx"]) + ix]
					if c == G.CELL_MISS:
						line += "."
					elif c == G.CELL_UNWALKED:
						line += " "
					else:
						var g: String = CELL_GLYPH.get(c & G.CELL_CODE_MASK, "?")
						line += g.to_upper() if (c & G.CELL_TURRET) == 0 else "T"
				_say("   |" + line + "|")


func _run() -> void:
	_say("target parts=%d precision_bodies=%d registered=%s" % [
		_target.armor_parts.size(),
		PrecisionPhysicsWorld.get_precision_body_count(_target),
		PrecisionPhysicsWorld.is_ship_registered(_target)])

	var gp: GunParams = _shooter.artillery_controller.get_params()
	_probe("AP", gp.shell1)
	_probe("HE", gp.shell2)

	_out.close()
	get_tree().quit()


func _probe(label: String, shell: ShellParams) -> void:
	if shell == null:
		return
	_say("")
	_say("--- %s: %.0fmm %.0fkg  overmatch=%dmm  arms>%dmm  bounce=%.0f deg ---" % [
		label, shell.caliber, shell.mass, shell.overmatch,
		shell.arming_threshold, rad_to_deg(shell.auto_bounce)])

	var length: float = _target.movement_controller.ship_length
	for range_m in RANGES_M:
		for aspect_deg in ASPECTS_DEG:
			_say("  range %5.0f m, aspect %2d deg" % [range_m, aspect_deg])
			var best_pay: float = -1.0
			var best_desc: String = "none"
			for h in HEIGHT_M:
				var cells: PackedStringArray = []
				for along in ALONG_FRACS:
					var aim := Vector3(0.0, h, along * length)
					var r := _walk(shell, aspect_deg, range_m, aim)
					cells.append("%-7s" % r)
					var pay: float = PAYOUT.get(r, 0.0)
					if pay > best_pay:
						best_pay = pay
						best_desc = "y=%.1f z=%+.2fL (%s)" % [h, along, r]
				_say("      y=%5.1f   %s" % [h, " ".join(cells)])
			_say("      best: %s   payout %.3f" % [best_desc, best_pay])


## Shoot every main turret in the face and report what the shell actually met.
##
## The other modes sample a grid and take what they get, which means a turret is
## only ever hit by accident and a turret that stops being hittable fails
## silently. This one is unconditional by construction: it aims at the middle of
## the turret's own geometry, so a miss is a real finding rather than a grid
## that happened to straddle it.
##
## Every shot is fired TWICE, once in the live world and once in the solver's
## survey space, because the two disagree about what a turret is and the
## disagreement is the thing worth watching:
##
##   - live: the terrain ray is collision_mask 1 with no exclude, and the GLB
##     import puts a turret's collider on layer 1. While that collider still has
##     its shape - before Turret._ready clears the layer, or forever if that is
##     disabled - the shell reads TERRAIN, which carries no ship and no armour
##     part, so it pays nothing.
##   - survey: BotGunnery's space holds the target's OBB and nothing else, so
##     there is no layer-1 body to find and the narrowphase answers instead.
##
## A healthy result is the same armour verdict in both columns, on a part that
## is_turret_part() agrees is a turret, paying DMG_TURRET rather than a full
## penetration.
func _turret_test() -> void:
	var ac = _target.artillery_controller
	if ac == null or (ac.weapons as Array).is_empty():
		_say("target has no main battery")
		_out.close()
		get_tree().quit()
		return
	var shell: ShellParams = (ac.get_params() as GunParams).shell1
	var turrets: Array[Turret] = ac.weapons
	_force_turret_setup(turrets)

	_say("")
	_say("turret hits on %s, AP %.0fmm  (payout capped at DMG_TURRET = %.3f)" % [
		_target.scene_file_path.get_file(), shell.caliber, _gunnery.DMG_TURRET])
	var turret_parts := 0
	for p: ArmorPart in _target.armor_parts:
		if PrecisionPhysicsWorld.is_turret_part(p):
			turret_parts += 1
	_say("armor_parts=%d (turret=%d)  precision_bodies=%d" % [
		_target.armor_parts.size(), turret_parts,
		PrecisionPhysicsWorld.get_precision_body_count(_target)])

	# What the live column is really hitting. A body only reads as terrain if it
	# is on layer 1 AND still owns a shape - Turret._ready clears the layer and
	# initialize_armor_system moves the shape out into an ArmorPart, so if either
	# has done its job this list is empty.
	var on_terrain_layer: Array[String] = []
	_collect_terrain_layer(_target, on_terrain_layer)
	_say("ship colliders still answering on the terrain layer: %d" % on_terrain_layer.size())
	for o in on_terrain_layer:
		_say("   %s" % o)

	for t in turrets:
		var aim := _turret_center(t)
		var world: Vector3 = _target.to_global(aim)
		_say("")
		_say("--- %s: origin y=%.1f, aim at ship-local (%.1f, %.1f, %.1f), %.1f m over the water [%s] ---" % [
			t.name, _target.to_local(t.global_position).y,
			aim.x, aim.y, aim.z, world.y, _turret_center_source(t)])
		_say("   %-9s %-7s | %-26s | %-26s" % ["aspect", "range", "live world", "survey space"])
		for aspect_deg in ASPECTS_DEG:
			for range_m in [3000.0, 9000.0]:
				var live := _turret_walk(shell, float(aspect_deg), range_m, aim,
					get_world_3d().direct_space_state)
				var surv := _turret_walk(shell, float(aspect_deg), range_m, aim,
					_gunnery.survey_space_state(_target))
				_say("   %6.0f deg %5.0f m | %-26s | %-26s" % [
					float(aspect_deg), range_m, _fmt(live), _fmt(surv)])

	_out.close()
	get_tree().quit()


## One line of _turret_test's table.
func _fmt(r: Dictionary) -> String:
	if not r.has("result"):
		return String(r.get("error", "?"))
	return "%-15s %s %.3f" % [r["result"],
		"T" if r["turret"] else ("h" if r["part"] != "" else "-"), r["payout"]]


## Where the middle of a turret is, in the TARGET's local space.
##
## A turret's origin is the bottom of it - the barbette ring - and the whole
## gunhouse sits above that, so a shell aimed at the origin passes under the
## turret and into the deck. The middle of its bounds is inside it.
##
## Measured off the `*_col` mesh when the GLB has one, because that mesh IS the
## turret's armour proxy and its centre is inside the gunhouse by definition.
## Merging every mesh instead would drag the centre forward into the barrels,
## which stick out well past the front plate and are not something to aim at.
func _turret_center(t: Turret) -> Vector3:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(t, meshes)
	var chosen: Array[MeshInstance3D] = []
	for m in meshes:
		if m.name.to_lower().ends_with("_col"):
			chosen.append(m)
	if chosen.is_empty():
		chosen = meshes
	if chosen.is_empty():
		return _target.to_local(t.global_position)

	var to_turret: Transform3D = t.global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for m in chosen:
		var b: AABB = (to_turret * m.global_transform) * m.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	return _target.to_local(t.global_transform * (box.position + box.size * 0.5))


func _turret_center_source(t: Turret) -> String:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(t, meshes)
	for m in meshes:
		if m.name.to_lower().ends_with("_col"):
			return m.name
	return "%d meshes merged" % meshes.size() if not meshes.is_empty() else "origin"


## Ship-owned bodies that a terrain raycast can still find: layer 1 with at
## least one shape still attached.
func _collect_terrain_layer(n: Node, out: Array[String]) -> void:
	if n is CollisionObject3D:
		var c := n as CollisionObject3D
		if (c.collision_layer & 1) != 0 and c.get_shape_owners().size() > 0:
			out.append("%s under %s (layer %d, %d shape owners)" % [
				n.name, n.get_parent().name if n.get_parent() else "-",
				c.collision_layer, c.get_shape_owners().size()])
	for ch in n.get_children():
		_collect_terrain_layer(ch, out)


func _collect_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n as MeshInstance3D)
	for c in n.get_children():
		_collect_meshes(c, out)


## The same shot _walk() fires, reported in full rather than as a bare verdict,
## and in whichever space the caller names.
func _turret_walk(shell: ShellParams, aspect_deg: float, range_m: float,
		local_aim: Vector3, space: PhysicsDirectSpaceState3D) -> Dictionary:
	if space == null:
		return {"error": "no space"}
	var a := deg_to_rad(aspect_deg)
	var bearing := Vector3(sin(a), 0.0, -cos(a))
	var from: Vector3 = _target.global_position \
		+ (_target.global_basis * bearing) * range_m \
		+ Vector3(0.0, maxf(_shooter.movement_controller.ship_draft * 0.5, 5.0), 0.0)
	_shooter.global_position = Vector3(from.x, 0.0, from.z)
	_shooter.force_update_transform()

	var to: Vector3 = _target.to_global(local_aim)
	var launch: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(from, to, shell)
	if launch.is_empty() or not launch[0]:
		return {"error": "no launch"}
	var tof: float = launch[1]
	var impact_vel: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
		launch[0], tof, shell)
	var dir: Vector3 = impact_vel.normalized()
	var prev_pos: Vector3 = to - dir * 60.0
	if prev_pos.y <= 1.0:
		return {"error": "starts underwater"}

	var proj := ProjectileData.new()
	proj.initialize(to + dir * 80.0, launch[0], 0.0, shell, _shooter, [])
	proj.set_frame_count(1)
	var res: Dictionary = ProjectileManager.get_raw().sim_process_travel(proj, prev_pos, tof, space)
	if not bool(res.get("hit", false)):
		return {"error": "no hit"}

	var part = res.get("armor_part")
	var is_turret: bool = part != null and PrecisionPhysicsWorld.is_turret_part(part)
	var payout: float = float(PAYOUT.get(_name_of(res["result_type"]), 0.0))
	if is_turret:
		payout = minf(payout, _gunnery.DMG_TURRET)
	return {
		"result": _name_of(res["result_type"]),
		"part": String(part.armor_path) if part != null else "",
		"turret": is_turret,
		"payout": payout,
	}


## Fire one real shell from (aspect, range) at one aim point and report the
## HitResult by name.
func _walk(shell: ShellParams, aspect_deg: float, range_m: float,
		local_aim: Vector3) -> String:
	# Aspect 0 is bow-on. The hull faces -Z, so a shooter at aspect A sits on a
	# bearing A off the target's bow.
	var a := deg_to_rad(aspect_deg)
	var bearing := Vector3(sin(a), 0.0, -cos(a))
	var gun_height: float = _shooter.movement_controller.ship_draft * 0.5
	var from: Vector3 = _target.global_position + bearing * range_m \
		+ Vector3(0.0, gun_height, 0.0)
	_shooter.global_position = Vector3(from.x, 0.0, from.z)

	var to: Vector3 = _target.to_global(local_aim)
	var launch: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(from, to, shell)
	if launch.is_empty() or not launch[0]:
		return "OUT"
	var tof: float = launch[1]
	var impact_vel: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
		launch[0], tof, shell)
	var dir: Vector3 = impact_vel.normalized()

	# Straddle the aim point so the swept segment definitely crosses the hull,
	# and start it clear of the sea so the water ray does not win.
	var prev_pos: Vector3 = to - dir * 60.0
	if prev_pos.y <= 1.0:
		return "LOW"

	var proj := ProjectileData.new()
	# Owner must be a real Ship: an owner-less projectile is treated as
	# visual-only and returns null without resolving armour at all.
	proj.initialize(to + dir * 80.0, launch[0], 0.0, shell, _shooter, [])
	proj.set_frame_count(1)

	var res: Dictionary = ProjectileManager.get_raw().sim_process_travel(
		proj, prev_pos, tof, _gunnery.survey_space_state(_target))
	if not bool(res.get("hit", false)):
		return "null"
	return _name_of(res["result_type"])


## The native walk reports its result as a bare int; this is its name.
func _name_of(result) -> String:
	return String(NativeArmorInteraction.result_name(int(result)))


func _say(line: String) -> void:
	print(line)
	if _out != null:
		_out.store_line(line)
		_out.flush()




## One walk, reported as result and the plate it first met.
func _detail(shell: ShellParams, local_aim: Vector3, asp: float, rng: float) -> String:
	var a := deg_to_rad(asp)
	var bearing: Vector3 = _target.global_basis * Vector3(sin(a), 0.0, -cos(a))
	var from: Vector3 = _target.global_position + bearing * rng + Vector3(0.0, 12.0, 0.0)
	var to: Vector3 = _target.to_global(local_aim)
	var launch: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(from, to, shell)
	if launch.is_empty() or not launch[0]:
		return "no-solution"
	var vel: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(launch[0], launch[1], shell)
	var dir: Vector3 = vel.normalized()
	var prev: Vector3 = to - dir * 60.0
	if prev.y <= 1.0:
		return "low"
	var proj := ProjectileData.new()
	proj.initialize(to + dir * 80.0, launch[0], 0.0, shell, _shooter, [])
	proj.set_frame_count(1)
	# log_armor on, so the walk reports the plates it met. The native log is a
	# FLAT array of steps, where the old GDScript struct_out nested one array of
	# steps per ship crossed.
	var res: Dictionary = ProjectileManager.get_raw().sim_process_travel(proj, prev, launch[1],
		_gunnery.survey_space_state(_target), true)
	if not bool(res.get("hit", false)):
		return "null"
	var steps: Array = res.get("log_steps", [])
	var plate := "?"
	if not steps.is_empty():
		plate = "%.0fmm" % float((steps[0] as Dictionary)["armor_mm"])
	return "%s %s" % [_name_of(res["result_type"]).substr(0, 9), plate]


func freeboard_min(pts: Array, ss: AABB) -> float:
	var v := INF
	for p in pts:
		if ss.size.y <= 0.0 or (p as Vector3).y < ss.position.y:
			v = minf(v, (p as Vector3).y)
	return v

func freeboard_max(pts: Array, ss: AABB) -> float:
	var v := -INF
	for p in pts:
		if ss.size.y <= 0.0 or (p as Vector3).y < ss.position.y:
			v = maxf(v, (p as Vector3).y)
	return v

func lateral_max(pts: Array, ss: AABB) -> float:
	var v := 0.0
	for p in pts:
		if ss.size.y <= 0.0 or (p as Vector3).y < ss.position.y:
			v = maxf(v, absf((p as Vector3).x))
	return v
