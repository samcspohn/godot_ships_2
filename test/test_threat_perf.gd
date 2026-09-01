extends SceneTree

## Per-ship threat stamping benchmark.
##
## The question binning existed to answer: is it affordable for every ship to
## carry its own threat circle list, sized to its own detection radius, instead
## of sharing one rounded up to the nearest kilometre?
##
## Three arms, on the real map:
##   A  ThreatRegistry.update_team  — the global publish, once per 4 frames.
##   B  per-ship rebuild + use      — what binning used to amortise away.
##   C  per-ship cluster sweep      — always was per ship per query; the arm
##                                    that decides whether any of this matters.
##
## Run headless (build BOTH gdextension targets first):
##   make -C gdextension/ships_core e && make -C gdextension/ships_core d
##   "$GODOT" --headless --path . --script res://test/test_threat_perf.gd

const CELL_SIZE  := 50.0
const EXTENT     := 17500.0
const BUILD_CL   := 25.0
const CLUSTER_SZ := 16

const SHIPS_PER_TEAM := 12
const ENEMIES        := 12
const UPDATE_TICKS   := 200
const QUERY_TICKS    := 100
const STAMP_TICKS    := 20

## Detection radii across a plausible lineup: DD low, CA mid, BB high, each plus
## the turning-circle margin bot_controller_v4 adds. These are exactly what used
## to collapse into a handful of shared bins.
const RADII: Array[float] = [
	2800.0, 3100.0, 3400.0, 5600.0, 5900.0, 6200.0,
	6500.0, 6800.0, 7100.0, 7400.0, 7700.0, 8000.0,
]

var _map: NavigationMap
var _hpa: HpaGraph


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	print("")
	print("========== per-ship threat stamping ==========")
	_build_world()
	if _map == null or not _map.is_built() or not _hpa.is_built():
		push_error("[threat] world build failed")
		quit(1)
		return
	print("[threat] grid %dx%d, %d clusters, %d ships/team, %d enemies"
		% [_map.get_grid_width(), _map.get_grid_height(),
		   _hpa.get_cluster_count(), SHIPS_PER_TEAM, ENEMIES])

	var reg := ThreatRegistry.new()
	var ids := PackedInt32Array()
	for i in ENEMIES:
		ids.append(1000 + i)

	# ── Arm A ───────────────────────────────────────────────────────────────
	var t0 := Time.get_ticks_usec()
	for tick in UPDATE_TICKS:
		reg.update_team(0, ids, _positions(tick), _force_spots(tick))
		reg.update_team(1, ids, _positions(tick + 7), _force_spots(tick + 7))
	var a_us := float(Time.get_ticks_usec() - t0) / float(UPDATE_TICKS)
	print("")
	print("A  update_team x2 (per publish tick) : %8.1f us" % a_us)
	print("   -> 1 publish / 4 frames @ 60fps   : %8.3f ms per second" % (a_us * 15.0 / 1000.0))

	var navs: Array = []
	for i in SHIPS_PER_TEAM:
		var nav := ShipNavigator.new()
		nav.set_map(_map)
		nav.set_hpa_graph(_hpa)
		nav.set_threat_source(reg, 0, RADII[i % RADII.size()])
		navs.append(nav)

	# ── Arm B ───────────────────────────────────────────────────────────────
	t0 = Time.get_ticks_usec()
	for tick in QUERY_TICKS:
		reg.update_team(0, ids, _positions(tick), _force_spots(tick))
		for nav in navs:
			nav.get_threat_circle_count()   # refresh only — the isolated rebuild
	var b_us := float(Time.get_ticks_usec() - t0) / float(QUERY_TICKS)
	print("")
	print("B  publish + %d ships rebuild        : %8.1f us" % [SHIPS_PER_TEAM, b_us])
	print("   -> rebuild alone, per ship        : %8.2f us"
		% ((b_us - a_us * 0.5) / float(SHIPS_PER_TEAM)))
	print("   -> circles held per ship          : %8d" % int(navs[0].get_threat_circle_count()))

	# Arm C — the real stamp path, measured twice: with the radar/hydro circles
	# this pass introduces, and without, so the cost of modelling force-spot is
	# separable from the cost that was always there.
	var c_cold := _time_stamp(reg, navs, ids, false)
	var c_hot := _time_stamp(reg, navs, ids, true)
	print("")
	print("C  stamp_threats, no force-spot      : %8.1f us / ship" % c_cold)
	print("C+ stamp_threats, radar+hydro live   : %8.1f us / ship" % c_hot)

	_check_force_spot()

	print("")
	print("A and B are the whole cost of dropping bins. C was already per ship")
	print("and is unchanged — if B/ship is small next to C, binning was saving")
	print("nothing worth the rounding it cost.")
	print("==============================================")
	quit(0)


## Correctness, not speed: does an enemy's radar actually enlarge the circle a
## ship routes against?
##
## One enemy at the origin, one observer whose own detection radius is 2800 m,
## and a destination 5000 m away — comfortably outside 2800, comfortably inside
## a radar bubble of 8000. It must be left alone with the radar off and pushed
## out with it on. This is the whole point of the pass: without it a destroyer
## sizes its standoff on its own concealment and walks into a bubble it cannot
## hide in.
func _check_force_spot() -> void:
	var reg := ThreatRegistry.new()
	var ids := PackedInt32Array([4242])
	var at := PackedVector3Array([Vector3(0.0, 0.0, 1.0)])   # origin, no decay
	var nav := ShipNavigator.new()
	nav.set_map(_map)
	nav.set_hpa_graph(_hpa)
	nav.set_threat_source(reg, 0, 2800.0)

	# The bearing has to be chosen, not assumed: a threat whose line of sight is
	# blocked by terrain correctly does NOT push a destination, so picking a
	# direction with an island in it tests nothing. Scan for open water.
	var dest := Vector2.ZERO
	for deg in range(0, 360, 5):
		var probe := Vector2(sin(deg_to_rad(deg)), cos(deg_to_rad(deg))) * 5000.0
		if not bool(_map.raycast(probe, Vector2.ZERO, 0.0)["hit"]):
			dest = probe
			break
	if dest == Vector2.ZERO:
		push_error("[threat] no clear bearing at 5000 m from the origin")
		return

	reg.update_team(0, ids, at, PackedFloat32Array([0.0]))
	var quiet: Dictionary = nav.adjust_destination_for_threats(dest * 2.4, dest)
	reg.update_team(0, ids, at, PackedFloat32Array([8000.0]))
	var radar: Dictionary = nav.adjust_destination_for_threats(dest * 2.4, dest)

	var quiet_adj: bool = bool(quiet.get("adjusted", false))
	var radar_adj: bool = bool(radar.get("adjusted", false))
	var pushed_to: Vector2 = radar.get("position", dest)
	print("")
	print("D  clear bearing at (%.0f, %.0f)" % [dest.x, dest.y])
	print("   radar off -> adjusted=%s (want false)" % quiet_adj)
	print("   radar on  -> adjusted=%s (want true), pushed to %.0f m out"
		% [radar_adj, pushed_to.length()])
	if quiet_adj or not radar_adj:
		push_error("[threat] force-spot not honoured")
	elif pushed_to.length() < 8000.0:
		push_error("[threat] pushed inside the radar bubble: %.0f m" % pushed_to.length())
	else:
		print("   OK — force-spot reach drives the circle")


## Average microseconds per ship for one full refresh + stamp round.
func _time_stamp(reg: ThreatRegistry, navs: Array, ids: PackedInt32Array,
		with_force_spot: bool) -> float:
	var t0 := Time.get_ticks_usec()
	var n := 0
	for tick in STAMP_TICKS:
		var fs := _force_spots(tick * 3) if with_force_spot else _no_force_spots()
		reg.update_team(0, ids, _positions(tick * 3), fs)
		for nav in navs:
			nav.debug_stamp_threats()
			n += 1
	return float(Time.get_ticks_usec() - t0) / float(n)


func _no_force_spots() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in ENEMIES:
		out.append(0.0)
	return out


func _positions(tick: int) -> PackedVector3Array:
	## Enemies drifting, so every publish genuinely bumps the version — the
	## worst case for consumers, since none of them can skip a rebuild.
	var out := PackedVector3Array()
	for i in ENEMIES:
		var ang := TAU * float(i) / float(ENEMIES) + float(tick) * 0.01
		out.append(Vector3(
			cos(ang) * 9000.0,
			6000.0 + sin(ang) * 3000.0,
			1.0 if i % 3 != 0 else 0.55))
	return out


func _force_spots(tick: int) -> PackedFloat32Array:
	## One radar cruiser and one hydro ship live at any moment.
	var out := PackedFloat32Array()
	for i in ENEMIES:
		if i == int(tick / 20.0) % ENEMIES:
			out.append(8000.0)
		elif i == (int(tick / 20.0) + 5) % ENEMIES:
			out.append(4000.0)
		else:
			out.append(0.0)
	return out


func _build_world() -> void:
	var map_scene: Node = load("res://src/Maps/map.tscn").instantiate()
	root.add_child(map_scene)
	var bodies: Array[Node3D] = []
	for b in map_scene.islands:
		bodies.append(b)
	_map = NavigationMap.new()
	_map.set_bounds(-EXTENT, -EXTENT, EXTENT, EXTENT)
	_map.set_cell_size(CELL_SIZE)
	_map.build_from_collision_shapes(bodies)
	_hpa = HpaGraph.new()
	_hpa.build(_map, BUILD_CL, CLUSTER_SZ)
