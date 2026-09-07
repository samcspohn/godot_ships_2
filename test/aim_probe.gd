extends Node3D

## Aim-point probe: runs the REAL armour walk against a real hull.
##
## BotGunnery models armour as oriented patches with one line of flight and no
## occlusion beyond what centroids imply. This rig instead calls
## ArmorInteraction.process_travel() - the same entry point the shells
## themselves go through, OBB broadphase into precision narrowphase into the
## plate-by-plate walk - so the approximation can be checked against the thing
## it approximates, and so a bucketed aim table can be generated from ground
## truth rather than from a model of it.
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
var _out: FileAccess
var _done: bool = false


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
	if OS.get_cmdline_user_args().has("--table"):
		_table_test()
	else:
		_run()


## Drive the solver the way a battle would. Real physics frames cannot be used
## here - this rig only ever gets one - so the frame boundary is simulated by
## refilling the budget and draining, which is exactly what _service_frame()
## does when a real frame ticks over.
func _table_test() -> void:
	_say("[%d ms] _table_test enter" % _ms())
	var G = load("res://src/ship/bot_behavior/bot_gunnery.gd").new()
	var a := deg_to_rad(90.0)
	_shooter.global_transform = Transform3D(Basis(),
		_target.global_position + Vector3(sin(a), 0.0, -cos(a)) * 9000.0)
	_shooter.force_update_transform()
	var key = G._bucket_key(_shooter, _target)

	_say("budget %d walks/frame; %d aim points x 2 shells = %d walks/bucket" % [
		G.SOLVER_BUDGET_PER_FRAME, G._aim_candidates(_target).size(),
		G._aim_candidates(_target).size() * 2])
	_say("[%d ms] grid built, entering solve loop" % _ms())
	_say("frame | bots asking | aim y | ammo | walks done | state")

	for frame in 6:
		# Twenty bots of one class all asking about the same contact. They
		# collapse onto one bucket, so this is one question, not twenty.
		var solution := {}
		for bot in 20:
			solution = G.solve(_shooter, _target)

		var progress = G._aim_progress.get(key, {})
		var done: int = int(progress.get("i", -1))
		var finished: bool = G._aim_table.has(key)
		_say("%5d | %11d | %5.2f | %4d | %10s | %s" % [
			frame, 20,
			(solution.get("offset", Vector3.ZERO) as Vector3).y,
			int(solution.get("ammo", -1)),
			"all" if finished else str(done),
			"SOLVED" if finished else "refining"])
		if finished:
			break
		# Simulate the next physics frame arriving.
		G._budget_left = G.SOLVER_BUDGET_PER_FRAME
		G._drain()

	# Geometry actually available to aim at, vs what the grid covers.
	var mc = _target.movement_controller
	var free: float = mc.ship_height - mc.ship_draft
	var top: float = _target.aabb.position.y + _target.aabb.size.y
	_say("")
	_say("ship_height=%.1f draft=%.1f -> freeboard=%.1f   length=%.0f" % [
		mc.ship_height, mc.ship_draft, free, mc.ship_length])
	_say("ship.aabb pos=(%.1f, %.1f, %.1f) size=(%.1f, %.1f, %.1f)  -> top y=%.1f" % [
		_target.aabb.position.x, _target.aabb.position.y, _target.aabb.position.z,
		_target.aabb.size.x, _target.aabb.size.y, _target.aabb.size.z,
		_target.aabb.position.y + _target.aabb.size.y])
	if _target.super_structure != null:
		var ss: Node3D = _target.super_structure
		var xf: Transform3D = ss.global_transform
		_say("super_structure '%s' world y=%.2f (ship y=%.2f)" % [
			ss.name, xf.origin.y, xf.origin.y - _target.global_position.y])
	else:
		_say("super_structure: null")
	_say("aim points: %d" % G._aim_candidates(_target).size())

	_say("[%d ms] solve loop done" % _ms())
	# The grid, split into hull and superstructure.
	var gp: GunParams = _shooter.artillery_controller.get_params()
	var ss: AABB = G._superstructure_bounds(_target)
	var pts: Array = G._aim_candidates(_target)
	var n_hull := 0
	for st in G.HULL_STATIONS:
		n_hull += (st[1] as Array).size()
	n_hull *= G.HULL_HEIGHT_FRACS.size()
	_say("")
	_say("grid: %d points = %d hull + %d superstructure   (%d walks/bucket)" % [
		pts.size(), n_hull, pts.size() - n_hull, pts.size() * 2])
	_say("superstructure bounds: pos=(%.1f, %.1f, %.1f) size=(%.1f, %.1f, %.1f)" % [
		ss.position.x, ss.position.y, ss.position.z, ss.size.x, ss.size.y, ss.size.z])

	var gpx: GunParams = _shooter.artillery_controller.get_params()
	_say("spread at 9000 m: %.0f x %.0f m over %d samples (first is exact)" % [
		G._dispersion_at(gpx, 9000.0).x, G._dispersion_at(gpx, 9000.0).y,
		G.SALVO_SAMPLES.size()])

	# What each aim point is worth, per shell, at a few geometries.
	var gpp: GunParams = _shooter.artillery_controller.get_params()
	var space2 := get_world_3d().direct_space_state
	var ssb: AABB = G._superstructure_bounds(_target)
	var pts2: Array = G._aim_candidates(_target)
	var disp_cache := {}
	_say("")
	_say("best aim point by geometry (mean of %d samples: 1 exact + %d dispersed)" % [
		G.SALVO_SAMPLES.size(), G.SALVO_SAMPLES.size() - 1])
	for pair2 in [[6000.0, 90.0], [12000.0, 90.0], [8000.0, 22.5], [15000.0, 22.5]]:
		var rng2: float = pair2[0]
		var asp2: float = pair2[1]
		var d2: Vector2 = G._dispersion_at(gpp, rng2)
		var best2 := -1.0
		var at2 := Vector3.ZERO
		var ammo2 := 0
		var ap_best := 0.0
		var he_best := 0.0
		for c2 in pts2:
			for am in [0, 1]:
				var sh2: ShellParams = gpp.shell1 if am == 0 else gpp.shell2
				var acc := 0.0
				for smp2 in G.SALVO_SAMPLES.size():
					acc += G._walk_payout(_target, _shooter, sh2, c2, smp2, asp2, rng2, d2, space2)
				acc /= G.SALVO_SAMPLES.size()
				if am == 0: ap_best = maxf(ap_best, acc)
				else: he_best = maxf(he_best, acc)
				if acc > best2:
					best2 = acc; at2 = c2; ammo2 = am
		var zone := "super" if (ssb.size.y > 0.0 and at2.y >= ssb.position.y) else "hull"
		_say("  %6.0f m %5.1f deg | spread %4.0fx%-4.0f | %s at x=%5.1f y=%5.2f z=%6.1f (%s) | AP %8.0f  HE %8.0f" % [
			rng2, asp2, d2.x, d2.y, "AP" if ammo2 == 0 else "HE",
			at2.x, at2.y, at2.z, zone, ap_best, he_best])

	_say("[%d ms] quitting" % _ms())
	_out.close()
	get_tree().quit()


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

	var res = ArmorInteraction.process_travel(
		proj, prev_pos, tof, get_world_3d().direct_space_state)
	if res == null:
		return "null"
	return _name_of(res.result_type)


func _name_of(result) -> String:
	var keys := ArmorInteraction.HitResult.keys()
	var values := ArmorInteraction.HitResult.values()
	var idx := values.find(int(result))
	return String(keys[idx]) if idx >= 0 else "?%d" % int(result)


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
	var steps: Array = []
	var res = ArmorInteraction.process_travel(proj, prev, launch[1],
		get_world_3d().direct_space_state, [], steps)
	if res == null:
		return "null"
	var plate := "?"
	if not steps.is_empty() and not (steps[0]["steps"] as Array).is_empty():
		plate = "%.0fmm" % float((steps[0]["steps"] as Array)[0]["armor_mm"])
	return "%s %s" % [_name_of(res.result_type).substr(0, 9), plate]


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
