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


## The secondary battery, which is the same solver asked a different question.
##
## Reported per MOUNT as well as combined, because the combining is the whole
## point: with two calibres firing at once a point is worth what the ship does
## there, and the ship is a 150mm penetration and a 105mm shatter arriving at
## different rates. The per-mount columns are what the combined column is made
## of, so a wrong answer can be traced to which gun disagreed.
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

	var space: PhysicsDirectSpaceState3D = _gunnery.survey_space_state(_target)
	var pts: Array = G._aim_candidates(_target)
	var ssb: AABB = G._superstructure_bounds(_target)
	_say("")
	_say("grid: %d aim points" % pts.size())

	for pr in [[1500.0, 90.0], [3500.0, 90.0], [4500.0, 90.0], [1500.0, 22.5], [3500.0, 22.5]]:
		# Put the shooter where the request says, then take the geometry back OUT
		# of the bucket key. The solver answers at the middle of a bucket, not at
		# the range and aspect it was asked about - 90 degrees lands in the
		# 90-105 bucket and is solved at 97.5 - so a scan run at the requested
		# aspect is answering a different question and the two cannot be
		# compared. Everything below uses the bucket's own geometry.
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
		var total_rate := 0.0
		for b in bats:
			total_rate += float(b["rate"])

		# Score every point the way _slot_value does, and show the mounts.
		var best := -1.0
		var best_pt := Vector3.ZERO
		var best_ammo := 0
		var best_parts: Array = []
		for c in pts:
			for am in [0, 1]:
				var combined := 0.0
				var parts: Array = []
				for b in bats:
					var sh: ShellParams = b["shell1"] if am == 0 else b["shell2"]
					if sh == null:
						parts.append(0.0)
						continue
					var offs: Array = b["offsets"]
					var acc := 0.0
					for off in offs:
						acc += G._walk_payout(_target, _shooter, sh, c, off, asp,
							rng, b["dispersion"], space).x
					acc /= offs.size()
					parts.append(acc)
					combined += acc * float(b["rate"])
				combined /= total_rate
				if combined > best:
					best = combined
					best_pt = c
					best_ammo = am
					best_parts = parts
		var zone := "super" if (ssb.size.y > 0.0 and best_pt.y >= ssb.position.y) else "hull"
		var cols: PackedStringArray = []
		for i in best_parts.size():
			cols.append("%5.0fmm %7.0f x %.2f/s" % [
				(bats[i]["shell1"] as ShellParams).caliber,
				float(best_parts[i]), float(bats[i]["rate"])])
		# Direct damage only. The solver additionally credits an HE slot with the
		# fire it would start (scaled against measured AP), so an HE row here can
		# legitimately come out below the solver's answer - see BotGunnery._best_of.
		_say("  best point: %s at x=%5.1f y=%5.2f z=%6.1f (%s)  combined %7.0f/shell  %7.0f dps  [direct only]" % [
			"AP" if best_ammo == 0 else "HE", best_pt.x, best_pt.y, best_pt.z, zone,
			best, best * total_rate])
		_say("    mounts: %s" % " | ".join(cols))

		# And what the solver itself lands on, through the budgeted service.
		var sol := {}
		for i in 2000:
			sol = G.solve_secondary(_shooter, _target)
			G._drain()
			if G._aim_table.has(kk):
				break
		var ans = G._aim_table.get(kk, {})
		var off: Vector3 = ans.get("offset", Vector3.ZERO)
		# Re-walk the exhaustive scan's winner AFTER the solver moved the
		# shooter, to see whether the two disagree about the same point.
		var recheck := 0.0
		for b2 in bats:
			var sh2: ShellParams = b2["shell1"] if best_ammo == 0 else b2["shell2"]
			if sh2 == null:
				continue
			var offs2: Array = b2["offsets"]
			var acc2 := 0.0
			for off2 in offs2:
				acc2 += G._walk_payout(_target, _shooter, sh2, best_pt, off2, asp,
					rng, b2["dispersion"], space).x
			recheck += (acc2 / offs2.size()) * float(b2["rate"])
		recheck /= total_rate
		_say("    same point re-walked after the solve: %7.0f (scan said %7.0f)" % [recheck, best])
		_say("    solver:  %s at x=%5.1f y=%5.2f z=%6.1f  payout %7.0f" % [
			"AP" if int(ans.get("ammo", 0)) == 0 else "HE",
			off.x, off.y, off.z, float(ans.get("payout", 0.0))])

	_say("")
	_say("[%d ms] quitting" % _ms())
	_out.close()
	get_tree().quit()


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

	_say("budget %d passes/bucket/frame; %d aim points x 2 shells = %d walks/pass, x %d shells = %d walks/bucket" % [
		G.PASSES_PER_BUCKET_PER_FRAME, G._aim_candidates(_target).size(),
		G._aim_candidates(_target).size() * 2, G.SHELLS_PER_SLOT,
		G._aim_candidates(_target).size() * 2 * G.SHELLS_PER_SLOT])
	_say("[%d ms] grid built, entering solve loop" % _ms())
	_say("frame | bots asking | aim y | ammo | walks done | state")

	# Wall clock across the whole survey, so the per-walk cost below is measured
	# on the real armour walk and not estimated from it. PASSES_PER_BUCKET_PER_FRAME
	# times this is what one active bucket adds to a physics frame.
	var t_walks: int = 0
	var walks_timed: int = 0
	for frame in 40:
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
		var total: int = G._aim_candidates(_target).size() * 2 * G.SHELLS_PER_SLOT
		var before: int = int(G._aim_progress.get(key, {}).get("i", 0))
		var t0: int = Time.get_ticks_usec()
		G._drain()
		t_walks += Time.get_ticks_usec() - t0
		# The bucket's state is erased on the frame it finishes, so read the
		# walk count off the total rather than off a state that has gone.
		walks_timed += int(G._aim_progress.get(key, {}).get("i", total)) - before
	if walks_timed > 0:
		var per_walk: float = float(t_walks) / float(walks_timed)
		var per_frame: float = per_walk * G.PASSES_PER_BUCKET_PER_FRAME \
			* float(G._aim_candidates(_target).size() * 2)
		_say("")
		_say("cost: %d walks in %.1f ms = %.1f us/walk" % [
			walks_timed, t_walks / 1000.0, per_walk])
		_say("      one active bucket = %.2f ms/frame; 24 of them = %.1f ms/frame" % [
			per_frame / 1000.0, per_frame * 24.0 / 1000.0])
		_say("      (a 60 Hz physics frame is 16.7 ms)")

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

	var bx: Array = G._batteries(_shooter, G.KIND_MAIN, 9000.0)
	if not bx.is_empty():
		var dx: Vector2 = (bx[0] as Dictionary)["dispersion"]
		_say("spread at 9000 m: %.0f x %.0f m over %d drawn shells" % [
			dx.x, dx.y, ((bx[0] as Dictionary)["offsets"] as Array).size()])

	# What each aim point is worth, per shell, at a few geometries.
	var gpp: GunParams = _shooter.artillery_controller.get_params()
	var space2: PhysicsDirectSpaceState3D = _gunnery.survey_space_state(_target)
	var ssb: AABB = G._superstructure_bounds(_target)
	var pts2: Array = G._aim_candidates(_target)
	var disp_cache := {}
	_say("")
	_say("best aim point by geometry (mean of %d shells drawn from the real calculator)" % G.SHELLS_PER_SLOT)
	for pair2 in [[6000.0, 90.0], [12000.0, 90.0], [8000.0, 22.5], [15000.0, 22.5]]:
		var rng2: float = pair2[0]
		var asp2: float = pair2[1]
		var bats2: Array = G._batteries(_shooter, G.KIND_MAIN, rng2)
		if bats2.is_empty():
			_say("  %6.0f m %5.1f deg | no mount reaches" % [rng2, asp2])
			continue
		var bat2: Dictionary = bats2[0]
		var d2: Vector2 = bat2["dispersion"]
		var offs3: Array = bat2["offsets"]
		var best2 := -1.0
		var at2 := Vector3.ZERO
		var ammo2 := 0
		var ap_best := 0.0
		var he_best := 0.0
		for c2 in pts2:
			for am in [0, 1]:
				var sh2: ShellParams = gpp.shell1 if am == 0 else gpp.shell2
				var acc := 0.0
				for off3 in offs3:
					acc += G._walk_payout(_target, _shooter, sh2, c2, off3, asp2, rng2, d2, space2).x
				acc /= offs3.size()
				if am == 0: ap_best = maxf(ap_best, acc)
				else: he_best = maxf(he_best, acc)
				if acc > best2:
					best2 = acc; at2 = c2; ammo2 = am
		var zone := "super" if (ssb.size.y > 0.0 and at2.y >= ssb.position.y) else "hull"
		_say("  %6.0f m %5.1f deg | spread %4.0fx%-4.0f | %s at x=%5.1f y=%5.2f z=%6.1f (%s) | AP %8.0f  HE %8.0f" % [
			rng2, asp2, d2.x, d2.y, "AP" if ammo2 == 0 else "HE",
			at2.x, at2.y, at2.z, zone, ap_best, he_best])

	# Ask the solver for a few geometries and report what it actually chose,
	# with the measured AP rate the fire bonus is now weighed against.
	_say("")
	_say("solver answers (fire bonus scaled by measured AP, not nominal):")
	for pr in [[6000.0, 90.0], [12000.0, 90.0], [8000.0, 22.5], [15000.0, 22.5]]:
		var rr: float = pr[0]
		var aa: float = pr[1]
		var ang := deg_to_rad(aa)
		_shooter.global_transform = Transform3D(Basis(),
			_target.global_position + Vector3(sin(ang), 0.0, -cos(ang)) * rr)
		_shooter.force_update_transform()
		var kk = G._bucket_key(_shooter, _target)
		var sol2 := {}
		for i in 400:
			sol2 = G.solve(_shooter, _target)
			G._drain()
			if G._aim_table.has(kk):
				break
		var ans2 = G._aim_table.get(kk, {})
		_say("  %6.0f m %5.1f deg -> %s  x=%5.1f y=%5.2f z=%6.1f  payout %8.0f" % [
			rr, aa, "AP" if int(ans2.get("ammo", 0)) == 0 else "HE",
			(ans2.get("offset", Vector3.ZERO) as Vector3).x,
			(ans2.get("offset", Vector3.ZERO) as Vector3).y,
			(ans2.get("offset", Vector3.ZERO) as Vector3).z,
			float(ans2.get("payout", 0.0))])

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
	var res = ArmorInteraction.process_travel(proj, prev_pos, tof, space)
	if res == null:
		return {"error": "no hit"}

	var part = res.armor_part
	var is_turret: bool = part != null and PrecisionPhysicsWorld.is_turret_part(part)
	var payout: float = float(PAYOUT.get(_name_of(res.result_type), 0.0))
	if is_turret:
		payout = minf(payout, _gunnery.DMG_TURRET)
	return {
		"result": _name_of(res.result_type),
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

	var res = ArmorInteraction.process_travel(
		proj, prev_pos, tof, _gunnery.survey_space_state(_target))
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
		_gunnery.survey_space_state(_target), [], steps)
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
