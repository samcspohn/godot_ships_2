extends SceneTree

## godot --headless --server --script res://tools/vis_probe.gd [--cell 300] [--pairs 20000]

const BOUNDS := Rect2(-17500, -17500, 35000, 35000)
const NEAR_M := 16000.0


func _initialize() -> void:
	await process_frame
	var map = load("res://src/Maps/map.tscn").instantiate()
	root.add_child(map)
	var nmm = root.get_node("/root/NavigationMapManager")
	nmm.build_map(map.islands, BOUNDS)
	await physics_frame
	await physics_frame

	var cell := float(CmdArgs.value("--cell", "300"))
	var pairs := int(CmdArgs.value("--pairs", "20000"))
	var vis := VisibilityGrid.new()
	vis.build(nmm.get_map(), cell)
	var info: Dictionary = vis.get_info()
	print("build %.0f ms  cell %.0f  grid %dx%d  water cells %d  %.1f MB" % [info.build_ms, info.cell,
		info.width, info.height, info.cells, info.bytes / 1048576.0])

	var space := root.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = 1
	q.hit_from_inside = false
	var truth := func(a: Vector2, b: Vector2) -> bool:
		q.from = Vector3(a.x, 1.0, a.y)
		q.to = Vector3(b.x, 1.0, b.y)
		return space.intersect_ray(q).is_empty()

	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var n: int = info.cells

	var c := _Tally.new()
	for _k in pairs:
		var a: Vector2 = vis.cell_centre(rng.randi_range(0, n - 1))
		var b: Vector2 = vis.cell_centre(rng.randi_range(0, n - 1))
		c.add(vis.visible(a, b), truth.call(a, b), a.distance_to(b))
	c.report("centre pairs (model error)")

	var r := _Tally.new()
	var p := _Tally.new()
	var by_frac := {"edge": _Tally.new(), "firm": _Tally.new()}
	for _k in pairs:
		var a := _water_point(nmm, rng)
		var b := _water_point(nmm, rng)
		var t: bool = truth.call(a, b)
		r.add(vis.ray_clear(a, b), t, a.distance_to(b))
		p.add(vis.visible(a, b), t, a.distance_to(b))
		var f: float = vis.visible_frac(a, b)
		by_frac["edge" if f > 0.0 and f < 1.0 else "firm"].add(vis.visible(a, b), t, a.distance_to(b))
	r.report("ray_clear, random points (terrain model)")
	p.report("grid, random points (model + cell)")
	by_frac["firm"].report("  frac 0 or 1")
	by_frac["edge"].report("  frac between")

	var pts := PackedVector2Array()
	for _k in 2000:
		pts.append(_water_point(nmm, rng))
	var t0 := Time.get_ticks_usec()
	var hits := 0
	for i in 100000:
		hits += int(vis.visible(pts[i % 2000], pts[(i * 7 + 3) % 2000]))
	print("visible(): %.2f us/call from GDScript (%d seen)" % [(Time.get_ticks_usec() - t0) / 100000.0, hits])
	quit()


func _water_point(nmm, rng: RandomNumberGenerator) -> Vector2:
	while true:
		var p := Vector2(rng.randf_range(BOUNDS.position.x, BOUNDS.end.x), rng.randf_range(BOUNDS.position.y, BOUNDS.end.y))
		if nmm.get_distance(Vector3(p.x, 0, p.y)) > 60.0:
			return p
	return Vector2.ZERO


class _Tally:
	var n := 0
	var agree := 0
	var loose := 0
	var strict := 0
	var near_n := 0
	var near_agree := 0

	func add(guess: bool, truth: bool, dist: float) -> void:
		n += 1
		agree += int(guess == truth)
		loose += int(guess and not truth)
		strict += int(truth and not guess)
		if dist <= NEAR_M:
			near_n += 1
			near_agree += int(guess == truth)

	func report(label: String) -> void:
		var d := maxf(n, 1)
		print("%s: n %d  agree %.1f%%  says-visible-wrongly %.1f%%  says-hidden-wrongly %.1f%%  | within 16 km %.1f%% of %d" % [
			label, n, 100.0 * agree / d, 100.0 * loose / d, 100.0 * strict / d,
			100.0 * near_agree / maxf(near_n, 1), near_n])
