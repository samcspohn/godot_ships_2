extends SceneTree

## Re-runs a logged slow plan against the same map, circles and bias, with stage timings.
## godot --headless --server --script res://tools/nav_replay.gd -- --run <dir> [--n 0] [--reps 20]

const BOUNDS := Rect2(-17500, -17500, 35000, 35000)


func _initialize() -> void:
	await process_frame
	var map = load("res://src/Maps/map.tscn").instantiate()
	root.add_child(map)
	var nmm = root.get_node("/root/NavigationMapManager")
	nmm.build_map(map.islands, BOUNDS)
	nmm.build_visibility()
	await physics_frame

	var run: String = CmdArgs.value("--run", "")
	var lines := FileAccess.get_file_as_string(run + "/spikes.jsonl").strip_edges().split("\n")
	var rec: Dictionary = JSON.parse_string(lines[int(CmdArgs.value("--n", "0"))])
	var reps := int(CmdArgs.value("--reps", "20"))
	var hpa: HpaGraph = nmm.get_hpa_graph()
	var from := Vector2(rec.pos[0], rec.pos[1])
	var to := Vector2(rec.target[0], rec.target[1])
	var circles := PackedVector3Array()
	for c in rec.circles:
		circles.append(Vector3(c[0], c[1], c[2]))
	var bias := PackedVector2Array()
	for p in rec.plan.get("bias", []):
		bias.append(Vector2(p[0], p[1]))
	var cl: float = rec.clearance
	var hug: float = rec.plan.get("hug_clearance", cl + 25.0)
	hpa.set_debug_legs(CmdArgs.has("--legs"))
	print("%s %s logged %.1f ms  stages %s" % [rec.ship, rec.get("skill", ""), rec.ms, rec.plan.get("stages", {})])

	for variant in [["as logged", circles, bias], ["no bias", circles, PackedVector2Array()],
			["no circles", PackedVector3Array(), bias]]:
		hpa.debug_stamp_circles(variant[1])
		hpa.find_path_biased_packed(from, to, cl, hug, variant[2])
		var best := INF
		var total := 0.0
		var path := PackedVector2Array()
		for _r in reps:
			var t0 := Time.get_ticks_usec()
			path = hpa.find_path_biased_packed(from, to, cl, hug, variant[2])
			var us := float(Time.get_ticks_usec() - t0)
			best = minf(best, us)
			total += us
		print("%-11s best %.2f ms  mean %.2f ms  waypoints %d  fail '%s'  stages %s" % [variant[0], best / 1000.0,
			total / reps / 1000.0, path.size(), hpa.get_last_fail_stage_name(), hpa.get_last_find_stages()])
	quit()
