class_name NavSpikeLog

## One JSON line per slow navigate_to, beside the run's SDF; read by tools/nav_spike_view.py.

static var _dir := ""

static func _run_dir() -> String:
	if _dir.is_empty():
		_dir = "user://nav_spikes/%s_%d" % [Time.get_datetime_string_from_system().replace(":", "-"), OS.get_process_id()]
		DirAccess.make_dir_recursive_absolute(_dir)
		_write_map()
		print("[nav spike] logging to %s" % ProjectSettings.globalize_path(_dir))
	return _dir

static func _write_map() -> void:
	var m: NavigationMap = NavigationMapManager.get_map()
	if m == null:
		return
	var meta := FileAccess.open(_dir + "/map.json", FileAccess.WRITE)
	meta.store_string(JSON.stringify({"w": m.get_grid_width(), "h": m.get_grid_height(),
		"cell": m.get_cell_size_value(), "min_x": m.get_min_x(), "min_z": m.get_min_z()}))
	FileAccess.open(_dir + "/sdf.f32", FileAccess.WRITE).store_buffer(m.get_sdf_data().to_byte_array())

static func write(bot: BotControllerV4, us: int, target: Vector3) -> void:
	var ship: Ship = bot._ship
	var raw: ShipNavigator = bot.navigator.get_raw()
	var beh: BotBehavior = bot.behavior
	var path := []
	for p in raw.get_current_path():
		path.append([p.x, p.z])
	var circles := []
	for c in raw.get_threat_circles():
		circles.append([c.x, c.y, c.z])
	var plan: Dictionary = raw.get_last_plan_breakdown()
	var bias := []
	for p in plan.get("bias", PackedVector2Array()):
		bias.append([p.x, p.y])
	plan["bias"] = bias
	var rec := {
		"t": SimClock.now(), "ship": String(ship.name), "team": ship.team.team_id if ship.team != null else -1,
		"class": Ship.ShipClass.keys()[ship.ship_class], "ms": us / 1000.0,
		"pos": [ship.global_position.x, ship.global_position.z], "heading": bot.get_ship_heading(),
		"target": [target.x, target.z], "clearance": raw.get_clearance(),
		"path": path, "circles": circles, "plan": plan,
		"spotted": ship.visible_to_enemy,
		"hp": ship.health_controller.current_hp / maxf(ship.health_controller.max_hp, 1.0),
	}
	if beh != null:
		var skill := String(beh._active_skill_name)
		var st: SkillPosition = null
		match beh._active_skill_name:
			&"Fight": st = beh._skill_fight.current()
			&"Disengage": st = beh._skill_disengage.cover()
		var pt: Ship = beh.priority_target()
		rec.merge({"skill": skill, "station": st.debug_text() if st != null else "",
			"stealth": beh.wants_stealth, "cornered": beh._cornered,
			"priority": String(pt.name) if pt != null else ""})
	var it: NavIntent = bot._last_intent
	if it != null:
		rec["intent"] = {"hold_radius": it.hold_radius, "avoid": it.avoid_origins.size(),
			"skip_threat_adjustment": it.skip_threat_adjustment, "directional": it.directional}
	var f := FileAccess.open(_run_dir() + "/spikes.jsonl", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_dir + "/spikes.jsonl", FileAccess.WRITE)
	f.seek_end()
	f.store_line(JSON.stringify(rec))
