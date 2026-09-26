extends SceneTree

const GUN_H := 20.0
const TARGET_H := 0.0
const RANGE := 20000.0
const SHOOTERS := 6
const POINTS := 3000

func _initialize() -> void:
	await process_frame
	await process_frame
	var map = load("res://src/Maps/map.tscn").instantiate()
	root.add_child(map)
	var nmm = root.get_node_or_null("/root/NavigationMapManager")
	nmm.build_map(map.islands, Rect2(-17500, -17500, 35000, 35000))
	for i in 10:
		await physics_frame
	var field: ReachField = nmm.get_reach_field()
	var nav: NavigationMap = nmm.get_map()
	var space := root.get_world_3d().direct_space_state
	var shell := ShellParams.new()
	shell.speed = 780.0
	shell.drag = 1.8e-05
	shell._update_derived_values()

	var rng_cap := RANGE
	print("BENCH field ", field.get_field_info(), " range ", rng_cap)

	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var shooters: Array[Vector2] = []
	while shooters.size() < SHOOTERS:
		var p := Vector2(rng.randf_range(-15000, 15000), rng.randf_range(-15000, 15000))
		if nmm.get_distance(Vector3(p.x, 0, p.y)) > 300.0:
			shooters.append(p)

	var sweep_cold := 0.0
	var sweep_warm := 0.0
	var reach_q := 0.0
	var sim_grid := 0.0
	var sim_phys := 0.0
	var lv_us := 0.0
	var n := 0
	var agree_grid := 0
	var agree_phys := 0
	var sweep_cells := 0
	var info := field.get_field_info()
	for s in shooters.size():
		var o := shooters[s]
		var id := 1000 + s
		var t0 := Time.get_ticks_usec()
		field.sweep(id, o, GUN_H, TARGET_H, shell.speed, shell.drag, rng_cap)
		var dt := Time.get_ticks_usec() - t0
		if s == 0:
			sweep_cold += dt
		t0 = Time.get_ticks_usec()
		field.sweep(id, o, GUN_H, TARGET_H, shell.speed, shell.drag, rng_cap)
		sweep_warm += Time.get_ticks_usec() - t0
		var bytes := field.get_reach_bytes(id)
		for b in bytes:
			if b:
				sweep_cells += 1

		var pts: Array[Vector2] = []
		while pts.size() < POINTS:
			var a := rng.randf() * TAU
			var d := sqrt(rng.randf()) * rng_cap
			var p := o + Vector2(cos(a), sin(a)) * d
			if nmm.get_distance(Vector3(p.x, 0, p.y)) > 0.0:
				pts.append(p)

		var fire := Vector3(o.x, GUN_H, o.y)
		var sols := []
		t0 = Time.get_ticks_usec()
		for p in pts:
			sols.append(ProjectilePhysicsWithDragV2.calculate_launch_vector(fire, Vector3(p.x, TARGET_H, p.y), shell))
		lv_us += Time.get_ticks_usec() - t0

		var rq := []
		t0 = Time.get_ticks_usec()
		for p in pts:
			rq.append(field.can_reach(id, p))
		reach_q += Time.get_ticks_usec() - t0

		var g := []
		t0 = Time.get_ticks_usec()
		for sol in sols:
			if sol[0] == null:
				g.append(false)
				continue
			g.append(not ProjectilePhysicsWithDragV2.sim_can_shoot_over_terrain(fire, sol[0], sol[1], shell, nav, null, [], null).terrain_blocked)
		sim_grid += Time.get_ticks_usec() - t0

		var ph := []
		t0 = Time.get_ticks_usec()
		for sol in sols:
			if sol[0] == null:
				ph.append(false)
				continue
			ph.append(not ProjectilePhysicsWithDragV2.sim_can_shoot_over_terrain(fire, sol[0], sol[1], shell, nav, space, [], null).terrain_blocked)
		sim_phys += Time.get_ticks_usec() - t0

		for i in pts.size():
			agree_grid += int(rq[i] == g[i])
			agree_phys += int(rq[i] == ph[i])
		n += pts.size()

	var cells: int = info.w * info.h
	print("BENCH shooters %d, points %d, field cells %d, reachable cells/ship %d" % [SHOOTERS, n, cells, sweep_cells / SHOOTERS])
	print("BENCH sweep cold (incl table build) %.2f ms" % (sweep_cold / 1000.0))
	print("BENCH sweep warm per ship %.2f ms  => %.3f us per field cell, %.3f us per reachable cell" % [sweep_warm / SHOOTERS / 1000.0, sweep_warm / SHOOTERS / cells, sweep_warm / float(sweep_cells)])
	print("BENCH can_reach query %.3f us/pt" % (reach_q / n))
	print("BENCH launch vector solve %.3f us/pt" % (lv_us / n))
	print("BENCH sim height-grid %.3f us/pt (agree %.1f%%)" % [sim_grid / n, 100.0 * agree_grid / n])
	print("BENCH sim physics %.3f us/pt (agree %.1f%%)" % [sim_phys / n, 100.0 * agree_phys / n])
	print("BENCH breakeven: one warm sweep = %.0f physics sims = %.0f grid sims" % [sweep_warm / SHOOTERS / ((sim_phys + lv_us) / n), sweep_warm / SHOOTERS / ((sim_grid + lv_us) / n)])
	quit()
