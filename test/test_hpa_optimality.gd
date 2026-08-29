extends SceneTree

## HpaGraph optimality + oscillation benchmark.
##
## Run headless (build BOTH gdextension targets first — a --script run loads
## template_debug, so `make e` alone measures stale code):
##
##   make -C gdextension/ships_core e && make -C gdextension/ships_core d
##   "$GODOT" --headless --path . --script res://test/test_hpa_optimality.gd
##
## Arm A — optimality. Routes a deterministic grid of from/to pairs through
## HpaGraph and through NavigationMap's full-grid cell A*, and reports the
## length ratio. This is the "are paths shorter" number.
##
## Arm B — oscillation. THIS IS THE GATE. Stickiness (HpaGraph::PathBias) exists
## because a ship that alternates between the two ways round an island steers at
## neither and can ground itself. Arm B simulates a ship advancing along its own
## route with a jittering destination, feeding each result back as the bias
## corridor, and counts how many times the route swaps sides. Any change that
## raises this number is wrong no matter what it does to Arm A.

const CELL_SIZE  := 50.0
const EXTENT     := 17500.0   # matches server.gd's Rect2(-17500,-17500,35000,35000)
const BUILD_CL   := 25.0      # NavigationMapManager.DEFAULT_MIN_SHIP_RADIUS
const QUERY_CL   := 120.0     # a capital ship's hull clearance
const HUG_CL      := 145.0    # + ShipNavigator.HUG_CLEARANCE_BUFFER
const CLUSTER_SZ := 16

# Arm B ship model
const TURN_RADIUS  := 400.0
const NEAR_FIELD   := TURN_RADIUS * 6.0   # ShipNavigator.PATH_NEAR_FIELD_TCR
const ADVANCE_STEP := 350.0               # metres sailed between replans
const GOAL_JITTER  := 250.0               # destination slide per replan
const TICKS        := 60

var _map: NavigationMap
var _hpa: HpaGraph


func _init() -> void:
	# Node3D.get_global_transform() only works once the tree is up, and
	# NavigationMap.build_from_collision_shapes() relies on it — running the
	# build straight out of _init() silently rasterises every island at the
	# origin. Defer one frame.
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	print("")
	print("========== HpaGraph benchmark (real map) ==========")
	_build_world()
	if _map == null or not _map.is_built() or not _hpa.is_built():
		push_error("[bench] world build failed")
		quit(1)
		return
	print("[bench] grid %dx%d, %d clusters, %d sub-clusters"
		% [_map.get_grid_width(), _map.get_grid_height(),
		   _hpa.get_cluster_count(), _hpa.get_sub_cluster_count()])

	_arm_a(false)
	print("")
	_arm_a(true)
	print("")
	_arm_b()
	print("==================================================")
	quit(0)


# ---------------------------------------------------------------------------
# World
# ---------------------------------------------------------------------------

func _build_world() -> void:
	## Loads the real map exactly as server.gd does, so the benchmark measures
	## the terrain and the map size the game actually plans over. A synthetic
	## map understates both: the real one is 35 km square, which is 700x700
	## cells, 1936 clusters and ~31k sub-clusters.
	var map_scene: Node = load("res://src/Maps/map.tscn").instantiate()
	root.add_child(map_scene)

	# map.gd fills `islands` in _ready(); it has run by now because the node was
	# added to a live tree above.
	var islands: Array = map_scene.islands
	if islands.is_empty():
		push_error("[bench] map.tscn exposed no islands")
		return
	print("[bench] real map: %d island bodies" % islands.size())

	var bodies: Array[Node3D] = []
	for b in islands:
		bodies.append(b)

	_map = NavigationMap.new()
	_map.set_bounds(-EXTENT, -EXTENT, EXTENT, EXTENT)
	_map.set_cell_size(CELL_SIZE)
	_map.build_from_collision_shapes(bodies)

	_hpa = HpaGraph.new()
	_hpa.build(_map, BUILD_CL, CLUSTER_SZ)
	_hpa.set_perf_tracking_enabled(true)
	_hpa.reset_perf_metrics()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func path_length(p: PackedVector2Array) -> float:
	var d := 0.0
	for i in range(p.size() - 1):
		d += p[i].distance_to(p[i + 1])
	return d


static func truncate_path(p: PackedVector2Array, max_len: float) -> PackedVector2Array:
	## Mirrors ShipNavigator::truncate_path — the bias corridor is clipped to the
	## near field, and that clip is part of what bounds the discount.
	var out := PackedVector2Array()
	if p.size() < 2:
		return out
	out.append(p[0])
	var acc := 0.0
	for i in range(1, p.size()):
		var seg := p[i - 1].distance_to(p[i])
		if acc + seg >= max_len:
			var t: float = (max_len - acc) / maxf(seg, 0.001)
			out.append(p[i - 1].lerp(p[i], clampf(t, 0.0, 1.0)))
			return out
		acc += seg
		out.append(p[i])
	return out


static func advance_along(p: PackedVector2Array, dist: float) -> Vector2:
	if p.size() < 2:
		return p[0] if p.size() == 1 else Vector2.ZERO
	var acc := 0.0
	for i in range(1, p.size()):
		var seg := p[i - 1].distance_to(p[i])
		if acc + seg >= dist:
			var t: float = (dist - acc) / maxf(seg, 0.001)
			return p[i - 1].lerp(p[i], clampf(t, 0.0, 1.0))
		acc += seg
	return p[p.size() - 1]


static func winding_about(p: PackedVector2Array, c: Vector2) -> float:
	## Total signed angle the route sweeps around c. Sign is which side of the
	## island the route takes; magnitude is how committed it is. Robust to the
	## endpoints moving between replans, which a signed-area measure is not.
	var total := 0.0
	for i in range(p.size() - 1):
		var a := p[i] - c
		var b := p[i + 1] - c
		if a.length() < 1.0 or b.length() < 1.0:
			continue
		total += a.angle_to(b)
	return total


static func percentile(vals: Array, q: float) -> float:
	if vals.is_empty():
		return 0.0
	var v := vals.duplicate()
	v.sort()
	var idx := int(clampf(q * (v.size() - 1), 0, v.size() - 1))
	return v[idx]


# ---------------------------------------------------------------------------
# Arm A — optimality
# ---------------------------------------------------------------------------

func _arm_a(biased: bool) -> void:
	## biased=true is the mode that matters. ShipNavigator ALWAYS passes the
	## route it is already following (ship_navigator.cpp:1566), which scales the
	## A* heuristic by PATH_BIAS_FACTOR to stay admissible — a 25% weaker
	## heuristic, and so a far larger search. Measuring only the unbiased path
	## understates the cost the game actually pays.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260829

	_hpa.reset_perf_metrics()
	var ratios: Array = []
	var pairs := 0
	var hpa_fail_ref_ok := 0
	var both_fail := 0
	var t0 := Time.get_ticks_usec()
	var hpa_us := 0

	var attempts := 0
	while pairs < 200 and attempts < 4000:
		attempts += 1
		var a := Vector2(rng.randf_range(-16000.0, 16000.0), rng.randf_range(-16000.0, 16000.0))
		var b := Vector2(rng.randf_range(-16000.0, 16000.0), rng.randf_range(-16000.0, 16000.0))
		if a.distance_to(b) < 6000.0:
			continue
		if not _map.is_navigable(a.x, a.y, QUERY_CL):
			continue
		if not _map.is_navigable(b.x, b.y, QUERY_CL):
			continue
		if not _map.is_reachable(a, b, QUERY_CL):
			continue
		# Only pairs the straight line cannot serve. Without this most samples
		# are answered by find_path's direct-LOS shortcut and the ratio measures
		# nothing but open water.
		var ray: Dictionary = _map.raycast(a, b, QUERY_CL)
		if not bool(ray.get("hit", false)):
			continue

		var ref_path: PackedVector2Array = _map.find_path(a, b, QUERY_CL, 0.0)
		if ref_path.size() < 2:
			continue

		var hpa_path: PackedVector2Array
		if biased:
			# Prime a corridor the way a ship following a route would have one,
			# then measure the replan that follows it.
			var seed_path: PackedVector2Array = _hpa.find_path_packed(a, b, QUERY_CL, HUG_CL)
			if seed_path.size() < 2:
				pairs += 1
				hpa_fail_ref_ok += 1
				continue
			var bias := truncate_path(seed_path, NEAR_FIELD)
			var h0 := Time.get_ticks_usec()
			hpa_path = _hpa.find_path_biased_packed(a, b, QUERY_CL, HUG_CL, bias)
			hpa_us += Time.get_ticks_usec() - h0
		else:
			var h0 := Time.get_ticks_usec()
			hpa_path = _hpa.find_path_packed(a, b, QUERY_CL, HUG_CL)
			hpa_us += Time.get_ticks_usec() - h0

		pairs += 1
		if hpa_path.size() < 2:
			hpa_fail_ref_ok += 1
			continue

		var rl := path_length(ref_path)
		var hl := path_length(hpa_path)
		if rl < 1.0:
			continue
		ratios.append(hl / rl)

	var wall := (Time.get_ticks_usec() - t0) / 1000.0

	var mean := 0.0
	for r in ratios:
		mean += r
	if not ratios.is_empty():
		mean /= ratios.size()

	print("[Arm A] %s — optimality vs full-grid cell A*" % ("BIASED (as the navigator calls it)" if biased else "unbiased"))
	print("  pairs routed        : %d (%.0f ms wall, %.0f us/query in HpaGraph)"
		% [pairs, wall, float(hpa_us) / maxf(pairs, 1)])
	print("  mean length ratio   : %.4f" % mean)
	print("  p50 / p95 / max     : %.4f / %.4f / %.4f"
		% [percentile(ratios, 0.50), percentile(ratios, 0.95), percentile(ratios, 1.0)])
	print("  HPA failed, ref ok  : %d   <-- must not rise" % hpa_fail_ref_ok)
	var perf: Dictionary = _hpa.get_perf_metrics()
	print("  avg_abstract_us     : %.1f" % float(perf.get("avg_abstract_us", 0.0)))
	print("  avg_refine_us       : %.1f" % float(perf.get("avg_refine_us", 0.0)))
	print("  max_total_us        : %.1f" % float(perf.get("max_total_us", 0.0)))


# ---------------------------------------------------------------------------
# Arm B — oscillation gate
# ---------------------------------------------------------------------------

func _arm_b() -> void:
	# Runs that must cross the central island, so there really are two ways round.
	# Straddle the largest island on the real map, so there genuinely are two
	# ways round for the bias to have to choose between.
	var isl: Dictionary = _map.get_nearest_island(Vector2(0.0, 0.0))
	var island_c := Vector2(0.0, 0.0)
	var reach := 9000.0
	if isl.has("center"):
		var c = isl["center"]
		island_c = Vector2(c.x, c.y) if c is Vector2 else Vector2(c.x, c.z)
	var scenarios := [
		[island_c + Vector2(-reach, -400.0),  island_c + Vector2( reach,  400.0)],
		[island_c + Vector2(-300.0,  -reach), island_c + Vector2( 300.0,  reach)],
		[island_c + Vector2(-reach * 0.8, -reach * 0.8), island_c + Vector2(reach * 0.8, reach * 0.8)],
		[island_c + Vector2( reach * 0.8, -reach * 0.8), island_c + Vector2(-reach * 0.8, reach * 0.8)],
	]

	var rng := RandomNumberGenerator.new()
	rng.seed = 7717

	var total_flips := 0
	var total_ticks := 0
	var total_failures := 0

	for si in range(scenarios.size()):
		var ship: Vector2 = scenarios[si][0]
		var goal: Vector2 = scenarios[si][1]
		var prev_route := PackedVector2Array()
		var prev_side := 0
		var flips := 0
		var ticks := 0

		for t in range(TICKS):
			var jittered := goal + Vector2(
				rng.randf_range(-GOAL_JITTER, GOAL_JITTER),
				rng.randf_range(-GOAL_JITTER, GOAL_JITTER))

			var bias := truncate_path(prev_route, NEAR_FIELD)
			var route: PackedVector2Array = _hpa.find_path_biased_packed(
				ship, jittered, QUERY_CL, HUG_CL, bias)

			if route.size() < 2:
				total_failures += 1
				break

			ticks += 1
			var w := winding_about(route, island_c)
			# Only count a side once the route is actually committed to one;
			# a route that has not reached the island yet has near-zero winding
			# and its sign is noise.
			var side := 0
			if absf(w) > 0.35:
				side = int(signf(w))
			if side != 0 and prev_side != 0 and side != prev_side:
				flips += 1
			if side != 0:
				prev_side = side

			prev_route = route
			ship = advance_along(route, ADVANCE_STEP)
			if ship.distance_to(goal) < 1200.0:
				break

		total_flips += flips
		total_ticks += ticks
		print("  scenario %d: %2d replans, %d side flips" % [si, ticks, flips])

	print("[Arm B] oscillation gate (side-of-island flips under fed-back bias)")
	print("  replans simulated   : %d" % total_ticks)
	print("  route failures      : %d" % total_failures)
	print("  TOTAL SIDE FLIPS    : %d   <-- MUST NOT RISE" % total_flips)
