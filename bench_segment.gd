extends SceneTree

const GUN_H := 20.0
const TARGET_H := 0.0
const RANGE := 20000.0
const PAIRS := 20000

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

	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var starts: Array[Vector2] = []
	var ends: Array[Vector2] = []
	while starts.size() < PAIRS:
		var a := Vector2(rng.randf_range(-17000, 17000), rng.randf_range(-17000, 17000))
		var ang := rng.randf() * TAU
		var b := a + Vector2(cos(ang), sin(ang)) * sqrt(rng.randf()) * RANGE
		if absf(b.x) > 17000 or absf(b.y) > 17000:
			continue
		if nmm.get_distance(Vector3(a.x, 0, a.y)) > 100.0 and nmm.get_distance(Vector3(b.x, 0, b.y)) > 0.0:
			starts.append(a)
			ends.append(b)

	var t0 := Time.get_ticks_usec()
	field.segment_clear(starts[0], ends[0], GUN_H, TARGET_H, shell.speed, shell.drag, RANGE)
	var cold := Time.get_ticks_usec() - t0

	var rb := []
	t0 = Time.get_ticks_usec()
	for i in PAIRS:
		rb.append(field.segment_clear(starts[i], ends[i], GUN_H, TARGET_H, shell.speed, shell.drag, RANGE))
	var rb_us := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	for i in PAIRS:
		field.is_built()
	var call_us := Time.get_ticks_usec() - t0

	var sols := []
	t0 = Time.get_ticks_usec()
	for i in PAIRS:
		var a := starts[i]
		var b := ends[i]
		sols.append(ProjectilePhysicsWithDragV2.calculate_launch_vector(Vector3(a.x, GUN_H, a.y), Vector3(b.x, TARGET_H, b.y), shell))
	var lv_us := Time.get_ticks_usec() - t0

	var g := []
	t0 = Time.get_ticks_usec()
	for i in PAIRS:
		var sol = sols[i]
		if sol[0] == null:
			g.append(false)
			continue
		var a := starts[i]
		g.append(not ProjectilePhysicsWithDragV2.sim_can_shoot_over_terrain(Vector3(a.x, GUN_H, a.y), sol[0], sol[1], shell, nav, null, [], null).terrain_blocked)
	var grid_us := Time.get_ticks_usec() - t0

	var ph := []
	t0 = Time.get_ticks_usec()
	for i in PAIRS:
		var sol = sols[i]
		if sol[0] == null:
			ph.append(false)
			continue
		var a := starts[i]
		ph.append(not ProjectilePhysicsWithDragV2.sim_can_shoot_over_terrain(Vector3(a.x, GUN_H, a.y), sol[0], sol[1], shell, nav, space, [], null).terrain_blocked)
	var phys_us := Time.get_ticks_usec() - t0

	var agree_rb := 0
	var agree_grid := 0
	var tight := 0
	var loose := 0
	var clear := 0
	for i in PAIRS:
		agree_rb += int(rb[i] == ph[i])
		agree_grid += int(g[i] == ph[i])
		tight += int(ph[i] and not rb[i])
		loose += int(rb[i] and not ph[i])
		clear += int(ph[i])
	var n := float(PAIRS)
	print("BENCH pairs %d, clear by physics %.1f%%" % [PAIRS, 100.0 * clear / n])
	print("BENCH gdscript call overhead %.3f us" % (call_us / n))
	print("BENCH segment_clear first call (table build) %.2f ms" % (cold / 1000.0))
	print("BENCH segment_clear %.3f us/pair  vs physics: agree %.1f%%, too tight %.2f%%, too loose %.2f%%" % [rb_us / n, 100.0 * agree_rb / n, 100.0 * tight / n, 100.0 * loose / n])
	print("BENCH launch vector %.3f us/pair" % (lv_us / n))
	print("BENCH sim height-grid %.3f us/pair (+lv %.3f)  vs physics: agree %.1f%%" % [grid_us / n, (grid_us + lv_us) / n, 100.0 * agree_grid / n])
	print("BENCH sim physics %.3f us/pair (+lv %.3f)" % [phys_us / n, (phys_us + lv_us) / n])
	quit()
