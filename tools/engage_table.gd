extends Node3D
## Every hull against every other: the numbers the Fight rings are built from.
## `godot --headless --path . res://tools/engage_table.tscn -- [--all] [lineup.json] [--out=path]`
## Rows are us, columns the enemy. Default hulls: those in the 12v12 lineup.
## Each hull carries its bot build from server.BOT_SHIP_CONFIG_PATH unless --bare.

const LINEUP := "res://tools/botmatch/lineup_12v12_t10.json"
const SPACING_M := 3000.0
const CURVE_STEP_M := 250.0
const PRIO_CURVE_MAX_M := 26000.0

var _names: Array[String] = []
var _hulls: Array[Ship] = []
var _bots: Array[BotBehavior] = []
var _out := "build/engage_table.md"
var _us := ""
var _bare := false
var _pairs: Array = []
var _paths: Array[String] = []
var _prio_km: Array = [6.0, 10.0, 14.0, 18.0]
## [our HP share, their HP share] pairs for desired-range matrices; --hp=1:1,0.5:1,...
var _hp_pairs: Array = []
var _done := false


func _ready() -> void:
	var paths: Array = []
	var extra: Array = []
	var lineup := LINEUP
	for a in OS.get_cmdline_user_args():
		if a == "--all":
			paths = GunneryBake._all_hull_scenes()
		elif a.begins_with("--pair="):
			_pairs.append(a.get_slice("=", 1).split(":"))
		elif a.begins_with("--prio="):
			_prio_km = Array(a.get_slice("=", 1).split(",", false)).map(func(k): return float(k))
		elif a.begins_with("--hp="):
			for pr in a.get_slice("=", 1).split(","):
				_hp_pairs.append([float(pr.get_slice(":", 0)), float(pr.get_slice(":", 1))])
		elif a == "--bare":
			_bare = true
		elif a.begins_with("--us="):
			_us = a.get_slice("=", 1)
		elif a.begins_with("--out="):
			_out = a.get_slice("=", 1)
		elif a.ends_with(".json"):
			lineup = a
		elif a.ends_with(".tscn"):
			extra.append(a)
	if paths.is_empty():
		paths = _lineup_hulls(lineup)
	for p in extra:
		if not paths.has(p):
			paths.append(p)
	for p in paths:
		var ps = load(p)
		var inst = ps.instantiate() if ps is PackedScene else null
		if not (inst is Ship):
			if inst != null:
				inst.free()
			continue
		add_child(inst)
		inst.freeze = true
		inst.global_position = Vector3(_hulls.size() * SPACING_M, 0.0, 0.0)
		inst.set_physics_process(false)
		_hulls.append(inst)
		_paths.append(p)
		_names.append(String(p).get_file().get_basename())


## What server._load_and_apply_player_config does, applied now rather than on the ship's next physics frame.
static func _apply_build(ship: Ship, build: Dictionary) -> void:
	for slot in build:
		if slot == "skills" or slot == "threat-mod" or String(build[slot]).is_empty():
			continue
		var u = UpgradeRegistry.create_upgrade(build[slot])
		if u != null:
			ship.upgrades.add_upgrade(int(slot), u)
	for id in build.get("skills", []):
		var sk = SkillsRegistry.create_skill(id)
		if sk != null:
			ship.skills.add_skill(sk)
	ship._update_static_mods()


static func _lineup_hulls(path: String) -> Array:
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	var out: Array = []
	for k in data["team"]:
		var s: String = data["team"][k]["ship"]
		if not out.has(s):
			out.append(s)
	return out


func _physics_process(_delta: float) -> void:
	if _done:
		return
	_done = true
	if not _bare:
		var cfg := ConfigFile.new()
		cfg.load(GameServer.BOT_SHIP_CONFIG_PATH)
		for i in _hulls.size():
			_apply_build(_hulls[i], cfg.get_value("ships", _paths[i], {}))
	BotGunnery.warm(_hulls)
	for s in _hulls:
		var b := BotBehavior.new()
		b._ship = s
		_bots.append(b)
	var md := PackedStringArray()
	md.append("# Engagement table\n\nRows: us. Columns: the enemy. Ranges in km, times in s, full HP, %s.\n" % ("bare hulls" if _bare else "bot builds"))
	md.append(_hull_sheet())
	md.append(_matrix("Desired range (W win, E even, L lose)", _desired))
	var u := _names.find(_us)
	if u >= 0:
		md.append(_curve(u, "Trade ratio", "ratios", _ratio))
		md.append(_curve(u, "Our time to kill them", "out", _secs))
		md.append(_curve(u, "Their time to kill us", "in", _secs))
	md.append(_matrix("Push: nearest range we out-trade them by TRADE_MARGIN (- none)", func(_i, _j, t): return "-" if float(t.push) < 0.0 else _km(t.push)))
	md.append(_matrix("Our time to kill them at desired range", func(i, j, _t): return _ttk_at(i, j, true)))
	md.append(_matrix("Their time to kill us at desired range", func(i, j, _t): return _ttk_at(i, j, false)))
	for hp in _hp_pairs:
		md.append(_matrix("Desired range, us at %d%% HP, them at %d%%" % [int(hp[0] * 100.0), int(hp[1] * 100.0)],
			func(i, j, _t): return _desired_hp(i, j, hp[0], hp[1])))
	for km in _prio_km:
		md.append(_priority_section(km * 1000.0))
	for pr in _pairs:
		md.append(_breakdown(_names.find(pr[0]), _names.find(pr[1])))
	_write_curves(_out.get_base_dir().path_join("engage_curves.csv"))
	_write_priority(_out.get_base_dir().path_join("priority_curves.csv"))
	for b in _bots:
		b.free()
	var text := "\n".join(md)
	print(text)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://" + _out.get_base_dir()))
	var f := FileAccess.open("res://" + _out, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		print("written %s" % _out)
	get_tree().quit()


func _hull_sheet() -> String:
	var rows := PackedStringArray(["## Hulls\n", "| hull | class | HP | gun km | sec km | conceal km | speed m/s | bear fore° | bear aft° | turrets x barrels | reload s | AP / HE dmg | raw main AP / HE dpm | raw sec HE dpm (one side) | torps: tubes/beam x dmg, reload s, km, kn |", "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"])
	for i in _hulls.size():
		var s := _hulls[i]
		var conceal: float = (s.concealment.params.p() as ConcealmentParams).radius if s.concealment != null else 0.0
		var bear := BotBehavior.guns_bear_angles(s)
		var raw := _raw(s)
		rows.append("| %s | %s | %d | %s | %s | %s | %.1f | %.1f | %.1f | %s | %s |" % [_names[i], Ship.ShipClass.keys()[s.ship_class],
			int(s.health_controller.max_hp), _km(s.artillery_controller.get_params()._range),
			_km(BotBehavior._secondary_range(s)), _km(conceal), s.movement_controller.max_speed, bear.x, bear.y, raw, _torps(s)])
	return "\n".join(rows) + "\n"


static func _torps(s: Ship) -> String:
	var tc: TorpedoController = s.torpedo_controller if is_instance_valid(s.torpedo_controller) else null
	if tc == null or tc.launchers.is_empty():
		return "-"
	var tubes := 0
	for side in [1.0, -1.0]:
		var n := 0
		for l in tc.launchers:
			if BotBehavior.gun_bears(s, l, 90.0, side):
				n += l.muzzles.size()
		tubes = maxi(tubes, n)
	var t := tc.get_torp_params()
	return "%d x %d, %.0f, %s, %.0f" % [tubes, int(t.damage), tc.get_params().reload_time, _km(tc.get_max_range()), t.speed_knts]


func _desired(i: int, j: int, _t) -> String:
	var d: Vector2 = _bots[i].desired_range(_hulls[j])
	return "%s %s" % [_km(d.x), "WEL"[int(d.y)]]


## _desired with HP set to these shares of max for the call; a hull against itself takes ours.
func _desired_hp(i: int, j: int, ours: float, theirs: float) -> String:
	var hu := _hulls[i].health_controller
	var ht := _hulls[j].health_controller
	var keep := [hu._current_hp, ht._current_hp]
	ht._current_hp = ht._max_hp * theirs
	hu._current_hp = hu._max_hp * ours
	var d: Vector2 = _bots[i].desired_range(_hulls[j])
	hu._current_hp = keep[0]
	ht._current_hp = keep[1]
	return "%s %s" % [_km(d.x), "WEL"[int(d.y)]]


## What each term of outgoing_dps is worth for `i` shooting `j`, by range.
func _breakdown(i: int, j: int) -> String:
	if i < 0 or j < 0:
		return ""
	var us := _hulls[i]
	var them := _hulls[j]
	var asp: float = BotBehavior.guns_bear_aspect(them)
	var model := BotGunnery.damage_model(them)
	var fp := them.fire_manager.fparams.p() as DOTParams
	var rows := PackedStringArray(["## %s shooting %s (aspect %.1f°; one full fire = %.1f%% HP)\n" % [_names[i], _names[j], asp, 100.0 * fp.dmg_rate * fp.dur],
		"| km | AP dps | of which fire | HE dps | of which fire | dodge | sec dps | total dps | TTK s |", "|---|---|---|---|---|---|---|---|---|"])
	var r := 2000.0
	while r <= us.artillery_controller.get_params()._range:
		var e: Dictionary = model.get_expected(us.get_instance_id(), them.get_instance_id(), r, asp)
		var fire_dps: float = float(e.get("he_fire_ev", 0.0)) * float(e.get("he_dps", 0.0)) / maxf(float(e.get("he_ev", 1.0)), 1e-6)
		var dodge: float = BotBehavior.dodge(them, us, r)
		var sec: float = BotBehavior._secondary_dps(us, them, r, asp)
		var total: float = _bots[i].outgoing_dps(them, r, asp)
		rows.append("| %.0f | %.0f | %.0f | %.0f | %.0f | %.2f | %.0f | %.0f | %s |" % [r / 1000.0, float(e.get("ap_dps", 0.0)), float(e.get("ap_fire_dps", 0.0)), float(e.get("he_dps", 0.0)),
			fire_dps, dodge, sec, total, _secs(total / them.health_controller.max_hp)])
		r += 2000.0
	return "\n".join(rows) + "\n"


## Main battery layout and the dpm every shell landing would do; secondaries that bear at guns_bear_aspect.
static func _raw(s: Ship) -> String:
	var p = s.artillery_controller.get_params()
	var barrels := 0
	for g in s.artillery_controller.guns:
		barrels += g.muzzles.size()
	var turrets: int = s.artillery_controller.guns.size()
	var ap: float = p.shell1.damage if p.shell1 != null else 0.0
	var he: float = p.shell2.damage if p.shell2 != null else 0.0
	var sec := 0.0
	if is_instance_valid(s.secondary_controller):
		var side := 1.0
		for sc in s.secondary_controller.sub_controllers:
			var sp = sc.get_params()
			var shell: ShellParams = sp.shell2 if sp.shell2 != null else sp.shell1
			for g in sc.guns:
				if BotBehavior.gun_bears(s, g, BotBehavior.guns_bear_aspect(s), side) or BotBehavior.gun_bears(s, g, BotBehavior.guns_bear_aspect(s), -side):
					sec += g.muzzles.size() * shell.damage / sp.reload_time * 60.0 * 0.5
	return "%d x %.1f | %.1f | %d / %d | %d / %d | %d" % [turrets, float(barrels) / maxi(turrets, 1), p.reload_time, ap, he,
		barrels * ap / p.reload_time * 60.0, barrels * he / p.reload_time * 60.0, sec]


## priority_score with every enemy `r` off in open water at full HP: shootable inside our guns.
func _prio(i: int, j: int, r: float) -> Vector4:
	return _bots[i].priority_parts(_hulls[j], r, r, r <= _hulls[i].artillery_controller.get_params()._range)


static func _score(p: Vector4) -> float:
	return BotBehavior.priority_value(p)


func _priority_section(r: float) -> String:
	var title := "Priority at %s km, alone, (%%HP/s)²: score = threat x chance x reach x (1 + harm)" % _km(r)
	var md := _matrix(title, func(i, j, _t):
		var p := _prio(i, j, r)
		return "%.2f = %.2fx%.2fx%.2fx%.2f" % [_score(p), p.x, p.y, p.z, 1.0 + BotBehavior.PRIORITY_FOCUS_W * p.w])
	var rows := PackedStringArray(["### Order at %s km\n" % _km(r), "| us | order |", "|---|---|"])
	for i in _hulls.size():
		var js: Array = range(_hulls.size())
		var sc := js.map(func(j): return _score(_prio(i, j, r)))
		js.sort_custom(func(a, b): return sc[a] > sc[b])
		rows.append("| %s | %s |" % [_names[i], " > ".join(js.map(func(j): return "%s %.2f" % [_names[j], sc[j]]))])
	return md + "\n" + "\n".join(rows) + "\n"


## _prio every CURVE_STEP_M out to PRIO_CURVE_MAX_M, for tools/priority_plot.py.
func _write_priority(path: String) -> void:
	var f := FileAccess.open("res://" + path, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("us,them,range_m,our_gun_m,threat,chance,reach,harm,score")
	for i in _hulls.size():
		var gun: float = _hulls[i].artillery_controller.get_params()._range
		for j in _hulls.size():
			var r := BotBehavior.POINT_BLANK_M
			while r <= PRIO_CURVE_MAX_M:
				var p := _prio(i, j, r)
				f.store_line("%s,%s,%d,%d,%.4f,%.4f,%.3f,%.3f,%.5f" % [_names[i], _names[j], int(r), int(gun), p.x, p.y, p.z, p.w, _score(p)])
				r += CURVE_STEP_M
	print("written %s" % path)


func _ttk_at(i: int, j: int, ours: bool) -> String:
	var r: float = _bots[i].desired_range(_hulls[j]).x
	if ours:
		return _secs(_bots[i].outgoing_dps(_hulls[j], r, BotBehavior.guns_bear_aspect(_hulls[j])) / _hulls[j].health_controller.max_hp)
	return _secs(_bots[i].incoming_dps(_hulls[j], r, BotBehavior.guns_bear_aspect(_hulls[i])) / _hulls[i].health_controller.max_hp)


## `cell(us, them, trade)` for every pair.
func _matrix(title: String, cell: Callable) -> String:
	var rows := PackedStringArray(["## " + title + "\n"])
	rows.append("| us \\ them | " + " | ".join(_names) + " |")
	rows.append("|---" + "|---".repeat(_names.size()) + "|")
	for i in _hulls.size():
		var cells := PackedStringArray()
		for j in _hulls.size():
			cells.append(cell.call(i, j, _bots[i]._trade(_hulls[j])))
		rows.append("| %s | %s |" % [_names[i], " | ".join(cells)])
	return "\n".join(rows) + "\n"


## Every pair's kill rates every CURVE_STEP_M, torpedoes included, for tools/engage_plot.py.
func _write_curves(path: String) -> void:
	var f := FileAccess.open("res://" + path, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("us,them,range_m,our_gun_m,their_gun_m,our_ttk_s,their_ttk_s")
	for i in _hulls.size():
		var us := _hulls[i]
		var our_gun: float = us.artillery_controller.get_params()._range
		for j in _hulls.size():
			var them := _hulls[j]
			var their_gun: float = them.artillery_controller.get_params()._range
			var r := BotBehavior.POINT_BLANK_M
			while r <= maxf(BotBehavior.reach_m(us), BotBehavior.reach_m(them)):
				var out: float = BotBehavior.kill_rate(us, them, r)
				var inc: float = BotBehavior.kill_rate(them, us, r)
				f.store_line("%s,%s,%d,%d,%d,%s,%s" % [_names[i], _names[j], int(r), int(our_gun), int(their_gun), _secs(out), _secs(inc)])
				r += CURVE_STEP_M
	print("written %s" % path)


## `key` of _trade per range step for hull `u` against every hull.
func _curve(u: int, title: String, key: String, fmt: Callable) -> String:
	var rows := PackedStringArray(["## %s: %s by range\n" % [_names[u], title]])
	rows.append("| km | " + " | ".join(_names) + " |")
	rows.append("|---" + "|---".repeat(_names.size()) + "|")
	var curves: Array = []
	for j in _hulls.size():
		curves.append(_bots[u]._trade(_hulls[j])[key])
	var gun: float = _hulls[u].artillery_controller.get_params()._range
	var r := BotBehavior.POINT_BLANK_M
	while r <= gun:
		var cells := PackedStringArray()
		for c in curves:
			cells.append(fmt.call(_at(c, r)))
		rows.append("| %s | %s |" % [_km(r), " | ".join(cells)])
		r += BotBehavior.RADIUS_STEP_M
	return "\n".join(rows) + "\n"


## The trade curve's sample nearest `range_m`; curves start at POINT_BLANK_M every RADIUS_STEP_M.
static func _at(curve: PackedFloat32Array, range_m: float) -> float:
	if curve.is_empty():
		return NAN
	var k: int = clampi(roundi((range_m - BotBehavior.POINT_BLANK_M) / BotBehavior.RADIUS_STEP_M), 0, curve.size() - 1)
	return curve[k]


static func _km(m: float) -> String:
	return "%.1f" % (m / 1000.0)


static func _ratio(r: float) -> String:
	return "-" if is_nan(r) else ("inf" if is_inf(r) else "%.2f" % r)


## `share` is HP share per second.
static func _secs(share: float) -> String:
	return "inf" if is_nan(share) or share <= 0.0 else "%d" % int(1.0 / share)
