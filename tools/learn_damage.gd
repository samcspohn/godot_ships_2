extends SceneTree

## Folds every saved bot-only match sample (GunneryCalibration.SAMPLES_DIR) into DamageExpectation.TABLE_PATH.
## Samples from another gunnery bake are dropped; ones whose hulls have since changed (fingerprint)
## count STALE_W per changed hull. Writes hull-pair and class-pair cells, aspect bands and "*".
## make learn

const STALE_W := 0.25


func _initialize() -> void:
	await process_frame
	var de = load("res://src/ship/bot_behavior/damage_expectation.gd")
	var cal = load("res://src/ship/bot_behavior/gunnery_calibration.gd")
	var bake: int = load("res://src/ship/bot_behavior/bot_gunnery.gd").SOLVER_VERSION
	var dir: String = cal.SAMPLES_DIR
	var files := DirAccess.get_files_at(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray()
	var current := {}
	var salvo_pair := {}
	var salvo_class := {}
	var turnout_hull := {}
	var turnout_class := {}
	var used := 0
	var stale := 0
	for f in files:
		var s = JSON.parse_string(FileAccess.get_file_as_string(dir + "/" + f))
		if not (s is Dictionary) or int(s.get("bake", -1)) != bake:
			continue
		used += 1
		var hulls: Dictionary = s.get("hulls", {})
		for name in hulls:
			if not current.has(name):
				current[name] = await _fingerprint(de, hulls[name].scene)
		for key in s.get("salvo", {}):
			var p: PackedStringArray = key.split("|")
			var w := _weight(current, p[0], p[1]) * _weight(current, p[2], p[3])
			stale += int(w < 1.0)
			var c: Dictionary = s.salvo[key]
			for aspect in [p[5], "*"]:
				var tail := "%s|%s" % [p[4], aspect]
				_add(salvo_pair, "%s|%s|%s" % [p[0], p[2], tail], c, w)
				_add(salvo_class, "%s|%s|%s" % [hulls.get(p[0], {}).get("cls", "?"), hulls.get(p[2], {}).get("cls", "?"), tail], c, w)
		for key in s.get("turnout", {}):
			var p: PackedStringArray = key.split("|")
			var w := _weight(current, p[0], p[1])
			var c: Dictionary = s.turnout[key]
			_add(turnout_hull, "%s|%s|%s" % [p[0], p[2], p[3]], c, w)
			_add(turnout_class, "%s|%s|%s" % [hulls.get(p[0], {}).get("cls", "?"), p[2], p[3]], c, w)
	var out := {"version": 1, "bake": bake, "built": Time.get_datetime_string_from_system(true), "matches": used,
		"fingerprints": current, "salvo_pair": salvo_pair, "salvo_class": salvo_class,
		"turnout_hull": turnout_hull, "turnout_class": turnout_class}
	var fa := FileAccess.open(de.TABLE_PATH, FileAccess.WRITE)
	fa.store_string(JSON.stringify(out, "\t", true))
	print("learn: %d matches (%d stale salvo cells), %d hull-pair and %d class-pair salvo cells, %d turn-out cells -> %s" % [
		used, stale, salvo_pair.size(), salvo_class.size(), turnout_hull.size(), ProjectSettings.globalize_path(de.TABLE_PATH)])
	quit()


static func _weight(current: Dictionary, name: String, fp: String) -> float:
	return 1.0 if current.get(name, "") == fp else STALE_W


static func _add(table: Dictionary, key: String, cell: Dictionary, w: float) -> void:
	var t: Dictionary = table.get_or_add(key, {})
	for k in cell:
		t[k] = float(t.get(k, 0.0)) + float(cell[k]) * w


func _fingerprint(de, scene_path: String) -> String:
	if not ResourceLoader.exists(scene_path):
		return ""
	var ship = load(scene_path).instantiate()
	root.add_child(ship)
	ship.global_position = Vector3(0, 0, 100000.0 * root.get_child_count())
	await physics_frame
	var fp: String = de.fingerprint(ship)
	ship.queue_free()
	return fp
