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
	elif OS.get_cmdline_user_args().has("--validate"):
		_validate()
	else:
		_run()


const GEOMETRIES := [[6000.0, 90.0], [12000.0, 90.0], [8000.0, 22.5], [15000.0, 22.5],
	[3000.0, 5.0], [1200.0, 45.0]]
const SEC_GEOMETRIES := [[1500.0, 90.0], [3500.0, 90.0], [4500.0, 90.0], [1500.0, 22.5],
	[3500.0, 22.5]]


func _place(range_m: float, aspect_deg: float) -> void:
	var a := deg_to_rad(aspect_deg)
	_shooter.global_transform = Transform3D(Basis(),
		_target.global_position + Vector3(sin(a), 0.0, -cos(a)) * range_m)
	_shooter.force_update_transform()


func _fmt_sol(sol: Dictionary) -> String:
	var o: Vector3 = sol.get("offset", Vector3.ZERO)
	return "%s  x=%6.1f y=%5.2f z=%6.1f  probed=%s" % [
		"AP" if int(sol.get("ammo", 0)) == 0 else "HE", o.x, o.y, o.z, sol.get("probed", false)]


## Secondary battery answers at a few geometries.
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
		_say("  %2d x %5.0f mm  reload %5.2f s  range %5.0f m  AP %.0f / HE %.0f dmg" % [
			(sc.guns as Array).size(), sp.shell1.caliber, sp.reload_time, sp._range,
			sp.shell1.damage, sp.shell2.damage])
	for pr in SEC_GEOMETRIES:
		_place(pr[0], pr[1])
		var t0 := Time.get_ticks_usec()
		var sol: Dictionary = G.solve_secondary(_shooter, _target)
		var dt := Time.get_ticks_usec() - t0
		_say("  %6.0f m %5.1f deg -> %s  (%d us)" % [pr[0], pr[1], _fmt_sol(sol), dt])
	_say("[%d ms] quitting" % _ms())
	_out.close()
	get_tree().quit()


## Main battery answers and solve cost, cold and cached.
func _table_test() -> void:
	var G = load("res://src/ship/bot_behavior/bot_gunnery.gd").new()
	var table = G._table(_target)
	if table == null:
		_say("no gunnery table for %s; run `make bake`" % _target.scene_file_path)
		_out.close()
		get_tree().quit()
		return
	_say("table %s: %d buckets, ref %.0fmm" % [G.table_path(_target),
		(table["buckets"] as Dictionary).size(), float(table["ref_caliber"])])
	_say("")
	_say("solver answers (cold us / cached us):")
	for pr in GEOMETRIES:
		_place(pr[0], pr[1])
		G.clear_all()
		var t0 := Time.get_ticks_usec()
		var sol: Dictionary = G.solve(_shooter, _target)
		var dt := Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		G.solve(_shooter, _target)
		var dt2 := Time.get_ticks_usec() - t0
		_say("  %6.0f m %5.1f deg -> %s  (%d / %d us)" % [pr[0], pr[1], _fmt_sol(sol), dt, dt2])
	_say("[%d ms] quitting" % _ms())
	_out.close()
	get_tree().quit()


const CELL_GLYPH := {0: "P", 1: "p", 2: "R", 3: "O", 4: "S", 5: "C", 6: "c", 7: "~", 8: "#"}


## The range at which `shell` arrives at `descent_deg`, off its range table.
func _range_for_descent(G, shell: ShellParams, descent_deg: float) -> float:
	var t: Dictionary = G._shell_table(shell)
	var rs: PackedFloat32Array = t["r"]
	var ds: PackedFloat32Array = t["desc"]
	for i in range(1, rs.size()):
		if ds[i] >= descent_deg:
			var f: float = clampf((descent_deg - ds[i - 1]) / maxf(ds[i] - ds[i - 1], 1e-6), 0.0, 1.0)
			return lerpf(rs[i - 1], rs[i], f)
	return rs[rs.size() - 1] if not rs.is_empty() else 1000.0

func _glyph(c: int) -> String:
	if c == BotGunnery.CELL_MISS:
		return "."
	if c == BotGunnery.CELL_UNWALKED:
		return " "
	if (c & BotGunnery.CELL_TURRET) != 0:
		return "T"
	return CELL_GLYPH.get(c & BotGunnery.CELL_CODE_MASK, "?")


## Baked table resolved at the shooter's real shells versus a live walk of those
## shells along the same lattice, cell by cell.
func _validate() -> void:
	var G = load("res://src/ship/bot_behavior/bot_gunnery.gd").new()
	var table = G._table(_target)
	if table == null:
		_say("no gunnery table for %s; run `make bake`" % _target.scene_file_path)
		_out.close()
		get_tree().quit()
		return
	var pm = ProjectileManager.get_raw()
	var gp: GunParams = _shooter.artillery_controller.get_params()
	GunneryBake._force_turrets(_target)
	var space := GunneryBake.survey_space_state(_target)
	space = GunneryBake.survey_space_state(_target)
	_say("descent buckets: %d, table ref %.0fmm" % [BotGunnery.descent_edges().size(),
		float(table["ref_caliber"])])
	var totals := {}
	for shell in [gp.shell1, gp.shell2]:
		if shell == null:
			continue
		var label := "%.0fmm %s" % [shell.caliber, "AP" if shell.type == ShellParams.ShellType.AP else "HE"]
		var agree_all := 0
		var agree_c_all := 0
		var count_all := 0
		for pr in GEOMETRIES:
			var range_m: float = pr[0]
			var a := deg_to_rad(float(pr[1]))
			var g := Vector3(sin(a), 0.0, -cos(a)) * range_m
			var aspect_i: int = G._aspect_of(g, Vector3.ZERO)
			var at: Array = G._shell_at(G._shell_table(shell), range_m)
			if at.is_empty():
				_say("%s %6.0f m %5.1f deg: out of range" % [label, range_m, pr[1]])
				continue
			var di: int = G._descent_index(at[0])
			var bid: int = G.bucket_id(aspect_i, di)
			var b = table["buckets"].get(bid)
			if b == null:
				_say("%s %6.0f m %5.1f deg: no bucket %d" % [label, range_m, pr[1], bid])
				continue
			var frame: Array = G.lattice_frame(aspect_i)
			var pts: PackedVector3Array = G.lattice_points(frame, b["rect"], b["nx"], b["ny"])
			var baked: PackedByteArray = G._resolve(_target.scene_file_path, bid, b, at[2],
				shell.overmatch, shell.type == ShellParams.ShellType.HE)
			var from: Vector3 = _target.global_position + (_target.global_basis * g) 				+ Vector3(0.0, BotGunnery.GUN_HEIGHT_M, 0.0)
			_shooter.global_position = Vector3(from.x, 0.0, from.z)
			_shooter.force_update_transform()
			var live: PackedByteArray = pm.survey_walk(_target, _shooter, shell, from, pts, space)
			# Same shell fired from the bucket's own centre: aspect at the centre,
			# range where this shell's descent equals the bucket's.
			var ac := deg_to_rad(G._aspect_center(aspect_i))
			var rc := _range_for_descent(G, shell, G._descent_center(di))
			var gc := Vector3(sin(ac), 0.0, -cos(ac)) * rc
			var from_c: Vector3 = _target.global_position + (_target.global_basis * gc) \
				+ Vector3(0.0, BotGunnery.GUN_HEIGHT_M, 0.0)
			_shooter.global_position = Vector3(from_c.x, 0.0, from_c.z)
			_shooter.force_update_transform()
			var live_c: PackedByteArray = pm.survey_walk(_target, _shooter, shell, from_c, pts, space)
			var at_c: Array = G._shell_at(G._shell_table(shell), rc)
			var baked_c: PackedByteArray = G._resolve(_target.scene_file_path, bid, b,
				at_c[2] if not at_c.is_empty() else at[2], shell.overmatch,
				shell.type == ShellParams.ShellType.HE)
			var agree := 0
			var agree_c := 0
			var count := 0
			for i in pts.size():
				if baked[i] == BotGunnery.CELL_MISS and live[i] == BotGunnery.CELL_MISS \
						and live_c[i] == BotGunnery.CELL_MISS:
					continue
				count += 1
				if baked[i] == live[i]:
					agree += 1
				if baked_c[i] == live_c[i]:
					agree_c += 1
			agree_all += agree
			agree_c_all += agree_c
			count_all += count
			_say("")
			_say("%s  %6.0f m %5.1f deg  bucket aspect %.1f descent %.1f  pen %.0f mm  v %.0f  desc %.1f  %dx%d  agree asked %d/%d  centre %d/%d (at %.0f m)" % [
				label, range_m, pr[1], G._aspect_center(aspect_i), G._descent_center(di),
				at[2], at[1], at[0], b["nx"], b["ny"], agree, count, agree_c, count, rc])
			_say("   baked | live at asked geometry | live at bucket centre")
			var nx: int = b["nx"]
			if shell.type == ShellParams.ShellType.AP:
				var shown := 0
				for i in pts.size():
					if baked_c[i] == live_c[i] or shown >= 3:
						continue
					shown += 1
					var pi: int = (b["cells"] as PackedInt32Array)[i]
					var bps: PackedStringArray = []
					for k in range((b["prof_off"] as PackedInt32Array)[pi], (b["prof_off"] as PackedInt32Array)[pi + 1]):
						bps.append("%.0f:%s" % [(b["bp_mm"] as PackedFloat32Array)[k], _glyph((b["bp_code"] as PackedByteArray)[k])])
					_say("   cell %d (%d,%d): baked %s  live %s  first plate %.0fmm  breakpoints [%s]  live walk: %s" % [
						i, i % nx, i / nx, _glyph(baked_c[i]), _glyph(live_c[i]),
						(b["first_mm"] as PackedFloat32Array)[pi], " ".join(bps),
						_detail(shell, pts[i], G._aspect_center(aspect_i), rc)])
			for iy in range(int(b["ny"]) - 1, -1, -1):
				var lb := ""
				var ll := ""
				var lc := ""
				for ix in nx:
					lb += _glyph(baked[iy * nx + ix])
					ll += _glyph(live[iy * nx + ix])
					lc += _glyph(live_c[iy * nx + ix])
				_say("   |%s|  |%s|  |%s|" % [lb, ll, lc])
		totals[label] = [agree_all, agree_c_all, count_all]
	_say("")
	for label in totals:
		var t: Array = totals[label]
		_say("agreement %s: asked geometry %d/%d = %.1f%%   bucket centre %d/%d = %.1f%%" % [
			label, t[0], t[2], 100.0 * t[0] / maxf(t[2], 1.0),
			t[1], t[2], 100.0 * t[1] / maxf(t[2], 1.0)])
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
					GunneryBake.survey_space_state(_target))
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
		proj, prev_pos, tof, GunneryBake.survey_space_state(_target))
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
	var from: Vector3 = _target.global_position + bearing * rng + Vector3(0.0, BotGunnery.GUN_HEIGHT_M, 0.0)
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
		GunneryBake.survey_space_state(_target), true)
	if not bool(res.get("hit", false)):
		return "null"
	var steps: Array = res.get("log_steps", [])
	var plate := "?"
	if not steps.is_empty():
		var st: Dictionary = steps[0]
		plate = "%.0fmm eff %.0f at %.0fdeg pen %.0f -> %s" % [float(st["armor_mm"]),
			float(st["effective_mm"]), rad_to_deg(float(st["impact_angle"])), float(st["pen"]),
			["ric", "over", "pen", "partial", "shatter"][int(st["result"])]]
	return "%s %s (%d steps)" % [_name_of(res["result_type"]).substr(0, 9), plate, steps.size()]


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
