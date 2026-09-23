extends SceneTree

func _initialize() -> void:
	await process_frame
	await process_frame
	var map = load("res://src/Maps/map.tscn").instantiate()
	root.add_child(map)
	var nmm = root.get_node_or_null("/root/NavigationMapManager")
	nmm.build_map(map.islands, Rect2(-17500, -17500, 35000, 35000))
	var field: ReachField = nmm.get_reach_field()
	var key: int = hash([snappedf(850.0, 0.01), snappedf(2.2e-5, 1e-8), snappedf(15000.0, 1.0), 10.0])
	field.set_team_hulls(0, PackedInt64Array([key]), PackedFloat32Array([850.0]), PackedFloat32Array([2.2e-5]), PackedFloat32Array([15000.0]), PackedFloat32Array([10.0]))
	var n := 12
	var ids := PackedInt64Array(); var origins := PackedVector2Array()
	var speeds := PackedFloat32Array(); var drags := PackedFloat32Array(); var ranges := PackedFloat32Array(); var gh := PackedFloat32Array()
	var spreads := PackedFloat32Array(); var weights := PackedFloat32Array(); var fs := PackedFloat32Array()
	var danger := {}; var spot := {}; var value := {}; var reveal := {}
	for i in n:
		ids.append(100 + i)
		origins.append(Vector2(-9000.0 + 1500.0 * i, 6000.0 + 2500.0 * (i % 3)))
		speeds.append(850.0); drags.append(2.2e-5); ranges.append(15000.0); gh.append(10.0)
		spreads.append(0.0 if i % 2 == 0 else 800.0); weights.append(1.0 if i % 2 == 0 else 0.5); fs.append(0.0)
		danger[100 + i] = 1.0; spot[100 + i] = 12000.0; value[100 + i] = 1.0; reveal[100 + i] = 1.0
	var t0 := Time.get_ticks_usec()
	var st: Dictionary = field.update_team(0, ids, origins, speeds, drags, ranges, gh, spreads, weights, fs, 15000.0, 10.0, 50.0)
	print("update_team %.1f ms (rust total %.1f ms)" % [(Time.get_ticks_usec() - t0) / 1000.0, float(st.get("total_us", 0.0)) / 1000.0])
	var here := Vector2(-2000.0, -6000.0)
	var opts := {
		"enemy_danger": danger, "enemy_spot": spot, "enemy_value": value, "enemy_reveal": reveal,
		"target_near": 0.5, "target_alone": 0.5, "threat_sat": log(2.0),
		"gun_range": 15000.0, "radius": 13000.0, "fire_radius": 15000.0,
		"w_reach": 1.0, "w_reveal": 0.5, "w_close": 0.5, "w_threat": 1.0, "aversion": 1.0, "w_path": 0.5, "max_threat": 0.5,
		"held": Vector2(INF, INF), "avoid": PackedVector2Array([Vector2(-3000, -5000), Vector2(0, -7000)]), "avoid_radius": 300.0,
		"weights": PackedFloat32Array([1, 1, 1, 1, 1, 1, 1]), "toward": Vector2(0, 8000),
	}
	# focus / cover split check: one enemy near, 5 friends inside its fire, 2 claims that reach everything
	var near_e := 0
	origins[near_e] = here + Vector2(6000.0, 0.0)
	field.update_team(0, ids, origins, speeds, drags, ranges, gh, spreads, weights, fs, 15000.0, 10.0, 50.0)
	field.plan_ship(0, 7, here, 13000.0, 0.25, 60.0, 8000.0, 1, Vector2(0, 8000))
	var friends := PackedVector2Array()
	for k in 5:
		friends.append(here + Vector2(-1500.0 + 700.0 * k, 2500.0))
	var claims := PackedVector2Array([here + Vector2(-800.0, 0.0), here + Vector2(0.0, -900.0)])
	var ckeys := PackedInt64Array([key, key])
	for variant in [["none", 0.0, 0.0], ["focus", 1.0, 0.0], ["cover", 0.0, 1.0], ["both", 1.0, 1.0]]:
		var o := opts.duplicate()
		o["friends"] = friends; o["focus_split"] = variant[1]
		o["claims"] = claims; o["claim_keys"] = ckeys; o["cover_split"] = variant[2]
		var sc: Dictionary = field.score_utility(0, 7, key, o)
		var bt: Dictionary = sc.get("best_terms", {})
		var ht: Dictionary = sc.get("here_terms", {})
		print("%s: here threat %.2f value %.2f reach %.2f | best %s dist-to-near %.0f threat %.2f value %.2f reach %.2f util %.2f escaping %s" % [
			variant[0], float(ht.get("threat", 0)), float(ht.get("value", 0)), float(ht.get("reach", 0)),
			str(sc.get("best")), (sc.get("best") as Vector2).distance_to(origins[near_e]) if sc.has("best") else -1.0,
			float(bt.get("threat", 0)), float(bt.get("value", 0)), float(bt.get("reach", 0)), float(sc.get("best_score", 0)), str(sc.get("escaping"))])
	origins[near_e] = Vector2(-9000.0, 6000.0)
	field.update_team(0, ids, origins, speeds, drags, ranges, gh, spreads, weights, fs, 15000.0, 10.0, 50.0)
	for mode in [0, 1]:
		for rep in 3:
			t0 = Time.get_ticks_usec()
			var p: Dictionary = field.plan_ship(0, 7, here, 13000.0, 0.25, 60.0, 8000.0, mode, Vector2(0, 8000))
			var t1 := Time.get_ticks_usec()
			var sc: Dictionary = field.score_utility(0, 7, key, opts)
			var t2 := Time.get_ticks_usec()
			print("mode %d rep %d: plan_ship wall %.1f ms (rust %.1f, cached %s) | score_utility wall %.1f ms (rust %.1f) best %s" % [
				mode, rep, (t1 - t0) / 1000.0, float(p.get("us", 0.0)) / 1000.0, str(p.get("cached")), (t2 - t1) / 1000.0, float(sc.get("us", 0.0)) / 1000.0, str(sc.get("best"))])
			if rep == 0:
				# force plan cache miss next rep by nudging one enemy
				origins[0] += Vector2(120.0, 0.0)
				field.update_team(0, ids, origins, speeds, drags, ranges, gh, spreads, weights, fs, 15000.0, 10.0, 50.0)
	quit()
