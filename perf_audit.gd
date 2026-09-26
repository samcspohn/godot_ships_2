extends SceneTree

func _ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0

func _initialize() -> void:
	await process_frame
	await process_frame
	var map = load("res://src/Maps/map.tscn").instantiate()
	root.add_child(map)
	var nmm = root.get_node_or_null("/root/NavigationMapManager")
	nmm.build_map(map.islands, Rect2(-17500, -17500, 35000, 35000))
	var field: ReachField = nmm.get_reach_field()
	var hpa: HpaGraph = nmm.get_hpa_graph()
	print("field ", field.get_field_info(), " hpa nodes ", hpa.get_node_count(), " clusters ", hpa.get_cluster_count())
	var keys := PackedInt64Array(); var hs := PackedFloat32Array(); var hd := PackedFloat32Array(); var hr := PackedFloat32Array(); var hh := PackedFloat32Array()
	for k in 4:
		var sp := 800.0 + 50.0 * k; var rg := 11000.0 + 3000.0 * k
		keys.append(hash([sp, rg])); hs.append(sp); hd.append(2.2e-5); hr.append(rg); hh.append(10.0)
	field.set_team_hulls(0, keys, hs, hd, hr, hh)
	var n := 12
	var ids := PackedInt64Array(); var origins := PackedVector2Array()
	var speeds := PackedFloat32Array(); var drags := PackedFloat32Array(); var ranges := PackedFloat32Array(); var gh := PackedFloat32Array()
	var spreads := PackedFloat32Array(); var weights := PackedFloat32Array(); var fs := PackedFloat32Array()
	var danger := {}; var spot := {}; var value := {}; var reveal := {}
	for i in n:
		ids.append(100 + i)
		origins.append(Vector2(-9000.0 + 1500.0 * i, 6000.0 + 2500.0 * (i % 3)))
		speeds.append(850.0); drags.append(2.2e-5); ranges.append(11000.0 + 1000.0 * (i % 5)); gh.append(10.0)
		spreads.append(0.0 if i % 3 else 800.0); weights.append(1.0 if i % 2 == 0 else 0.5); fs.append(0.0)
		danger[100 + i] = 1.0; spot[100 + i] = 9000.0; value[100 + i] = 1.0; reveal[100 + i] = 1.0
	var t0 := Time.get_ticks_usec()
	var st: Dictionary = field.update_team(0, ids, origins, speeds, drags, ranges, gh, spreads, weights, fs, 12000.0, 10.0, 100.0)
	print("update_team cold: %.1f ms, jobs %d" % [_ms(t0), st.jobs])
	# one enemy moves: the common case
	for rep in 3:
		origins[rep] += Vector2(150, 0)
		t0 = Time.get_ticks_usec()
		st = field.update_team(0, ids, origins, speeds, drags, ranges, gh, spreads, weights, fs, 12000.0, 10.0, 100.0)
		var u := _ms(t0)
		t0 = Time.get_ticks_usec(); field.get_cone_bytes(0); var c := _ms(t0)
		t0 = Time.get_ticks_usec(); field.get_detect_grid(0); var dg := _ms(t0)
		t0 = Time.get_ticks_usec(); hpa.debug_stamp_fire(field, 0, 0.5); var fire := _ms(t0)
		t0 = Time.get_ticks_usec(); hpa.debug_stamp_fire(field, 0, 0.5); var fire2 := _ms(t0)
		t0 = Time.get_ticks_usec(); hpa.debug_stamp_detection(field, 0, 7000.0, 0.5); var ex := _ms(t0)
		t0 = Time.get_ticks_usec(); hpa.debug_stamp_detection(field, 0, 7000.0, 0.5); var ex2 := _ms(t0)
		print("1 enemy moved: update_team %.1f (jobs %d) | cone %.1f | detect %.1f | fire stats %.1f (cached %.2f) | exposure stats %.1f (cached %.2f)" % [u, st.jobs, c, dg, fire, fire2, ex, ex2])
	var here := Vector2(-2000.0, -6000.0)
	var uopts := {
		"enemy_danger": danger, "enemy_spot": spot, "enemy_value": value, "enemy_reveal": reveal,
		"target_near": 0.5, "target_alone": 0.5, "threat_sat": log(2.0),
		"gun_range": 15000.0, "radius": 7000.0, "fire_radius": 15000.0,
		"w_reach": 0.8, "w_reveal": 0.8, "w_close": 0.2, "w_threat": 1.0, "aversion": 1.0, "w_path": 0.2,
		"held": Vector2(INF, INF), "avoid": PackedVector2Array(), "avoid_radius": 300.0,
		"weights": PackedFloat32Array([1, 1, 1, 1, 1, 1, 1]), "toward": Vector2(0, 8000),
	}
	var sopts := {"weights": PackedFloat32Array([1, 1, 1, 1, 1, 1, 1]), "gun_range": 15000.0, "pref_range": 12000.0,
		"min_range": 0.0, "max_range": INF, "radius": 7000.0, "fire_radius": 15000.0, "toward": Vector2(0, 8000),
		"held": Vector2(INF, INF), "avoid": PackedVector2Array(), "avoid_radius": 300.0, "axis_from": here, "w_detour": 0.0,
		"enemy_weights": {}, "max_exposed": 99.0, "require_unseen": false, "covered_only": false, "flank_from": Vector2.ZERO, "w_flank": 0.0}
	for mode in [0, 1]:
		for box in [8000.0, 13000.0]:
			var pls := []
			var p: Dictionary
			for k in 7:
				field.plan_ship(0, 7, here + Vector2(0, 100.0 * (k + 1)), 7000.0, 0.5, 60.0, box, mode, Vector2(0, 8000))
				t0 = Time.get_ticks_usec()
				p = field.plan_ship(0, 7, here, 7000.0, 0.5, 60.0, box, mode, Vector2(0, 8000))
				pls.append(_ms(t0))
			pls.sort()
			var pl: float = pls[3]
			print("  plan min %.2f med %.2f max %.2f" % [pls[0], pls[3], pls[6]])
			t0 = Time.get_ticks_usec(); field.plan_ship(0, 7, here, 7000.0, 0.5, 60.0, box, mode, Vector2(0, 8000)); var plc := _ms(t0)
			var ss := INF; var su := INF; var rs: Dictionary; var ru: Dictionary
			var sl := []; var ul := []
			for k in 9:
				t0 = Time.get_ticks_usec(); rs = field.score_station(0, 7, keys[0], sopts); sl.append(_ms(t0))
				t0 = Time.get_ticks_usec(); ru = field.score_utility(0, 7, keys[0], uopts); ul.append(_ms(t0))
			sl.sort(); ul.sort(); ss = sl[4]; su = ul[4]
			print("  station min %.2f med %.2f max %.2f | utility min %.2f med %.2f max %.2f" % [sl[0], sl[4], sl[8], ul[0], ul[4], ul[8]])
			print("CHECK station %s %.6f utility %s %.6f marker %s cost %.3f esc %.3f risk %.3f" % [rs.get("best"), float(rs.get("best_score", 0)), ru.get("best"), float(ru.get("best_score", 0)), p.marker, float(p.marker_cost), float(p.max_escape), float(p.max_risk)])
			t0 = Time.get_ticks_usec(); field.utility_score_at(0, 7, keys[0], uopts, here); var sa := _ms(t0)
			print("mode %d box %.0f: plan_ship %.1f (rust %.1f, cached call %.2f) | score_station %.1f | score_utility %.1f | utility_score_at %.2f" % [mode, box, pl, float(p.us) / 1000.0, plc, ss, su, sa])
	var from := Vector2(-12000, -12000); var to := Vector2(12000, 12000)
	hpa.debug_stamp_fire(field, 0, 0.5)
	t0 = Time.get_ticks_usec(); var path = hpa.find_path_packed(from, to, 60.0); print("find_path_packed fire-stamped %.1f ms, %d pts" % [_ms(t0), path.size()])
	hpa.debug_clear_threats()
	t0 = Time.get_ticks_usec(); path = hpa.find_path_packed(from, to, 60.0); print("find_path_packed clear %.1f ms" % _ms(t0))
	quit()
