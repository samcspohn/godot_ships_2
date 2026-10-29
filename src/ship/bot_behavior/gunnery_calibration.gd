class_name GunneryCalibration

## Main-battery damage the baked model (DamageModel.get_expected, what SkillStance prices) expected
## against what landed, by shooter hull, target class and range band, for match metrics.
## Expected is booked when a gun fires, on the enemy nearest its aim point; landed when Stats records a hit.

const RANGE_BAND_M := 5000.0
const AIM_MATCH_M := 1500.0

## "shooter|target class|band|target hull" -> {salvos, shells, pred, pred_cit, real, real_cit, hits}
static var rows: Dictionary = {}
## Ship instance id -> {attacker instance id -> main-battery damage it has taken from it}.
static var taken: Dictionary = {}
## SkillStance's priced manoeuvres against what the hull then took over as long, one open per ship;
## closed into probes "class|kind|duration band" (PROBE_BANDS_S): predicted (pred: as priced; on / by:
## from shooters on us / bystanders; early: in the turn's swing) against real (on / by /
## other: from those shooters, from anyone else; early), plus over_hp, died, died_over.
const PROBE_BANDS_S := [30.0, 60.0, 120.0]
static var _open: Dictionary = {}
static var probes: Dictionary = {}
## Class -> {cheaper: fresh prices where turning won, vetoed: of those, the swing outweighed HP}.
static var vetoes: Dictionary = {}
## What `make learn` folds into DamageExpectation's table, saved per bot-only match:
## salvo "shooter|fp|target|fp|range band|aspect band" -> {n, pred, real, pred_cit, real_cit};
## turnout "hull|fp|kind|slice" -> {n, pred_on, pred_by, real_on, real_by, real_other}; hulls name -> {scene, fp, cls}.
const SAMPLES_DIR := "user://damage_samples"
static var samples := {"salvo": {}, "turnout": {}, "hulls": {}}


static func _hull(ship: Ship) -> String:
	var fp := DamageExpectation.fingerprint(ship)
	if not (samples.hulls as Dictionary).has(ship.ship_name):
		samples.hulls[ship.ship_name] = {"scene": ship.scene_file_path, "fp": fp, "cls": DamageExpectation.class_name_of(ship)}
	return "%s|%s" % [ship.ship_name, fp]


static func _salvo_cell(shooter: Ship, target: Ship) -> Dictionary:
	var key := "%s|%s|%d|%d" % [_hull(shooter), _hull(target),
		DamageExpectation.range_band(shooter.global_position.distance_to(target.global_position)),
		DamageExpectation.aspect_band(BotGunnery.aspect_from(target, shooter.global_position))]
	return (samples.salvo as Dictionary).get_or_add(key, {"n": 0, "pred": 0.0, "real": 0.0, "pred_cit": 0.0, "real_cit": 0.0})


static func save_samples() -> void:
	_close_due(SimClock.now())
	if not ((samples.salvo as Dictionary).is_empty() and (samples.turnout as Dictionary).is_empty()):
		DirAccess.make_dir_recursive_absolute(SAMPLES_DIR)
		var path := "%s/%d_%d.json" % [SAMPLES_DIR, int(Time.get_unix_time_from_system()), OS.get_process_id()]
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(samples.merged({"version": 1, "bake": BotGunnery.SOLVER_VERSION})))
	reset_match()


## Ships and instance ids are per match: drop what the finished match left behind.
static func reset_match() -> void:
	_open.clear()
	taken.clear()
	samples = {"salvo": {}, "turnout": {}, "hulls": {}}


static func on_veto(ship: Ship, vetoed: bool) -> void:
	var v: Dictionary = vetoes.get_or_add(Ship.ShipClass.keys()[ship.ship_class], {"cheaper": 0, "vetoed": 0})
	v.cheaper += 1
	v.vetoed += int(vetoed)


static func open_probe(ship: Ship, kind: StringName, pred: float, dur: float, early_s: float, split: Dictionary, on_ids: Array, by_ids: Array) -> void:
	var now: float = SimClock.now()
	_close_due(now)
	var id := ship.get_instance_id()
	if _open.has(id) or not is_finite(pred) or dur <= 0.0:
		return
	var band := 0
	while band < PROBE_BANDS_S.size() and dur > PROBE_BANDS_S[band]:
		band += 1
	_open[id] = {"ship": ship, "key": "%s|%s|%d|%s" % [Ship.ShipClass.keys()[ship.ship_class], kind, band, ship.ship_name], "pred": pred,
		"split": split, "on": on_ids, "by": by_ids, "hp": ship.health_controller.current_hp,
		"taken0": (taken.get(id, {}) as Dictionary).duplicate(), "t0": now, "t_end": now + dur, "early_s": early_s,
		"turnout": "%s|%s" % [_hull(ship), kind], "cum": []}


## Damage `id` took since `before`, as [from on_ids, from by_ids, from anyone else].
static func _since(id: int, before: Dictionary, on_ids: Array, by_ids: Array) -> Array:
	var out := [0.0, 0.0, 0.0]
	var now_by: Dictionary = taken.get(id, {})
	for a in now_by:
		var d: float = float(now_by[a]) - float(before.get(a, 0.0))
		out[0 if on_ids.has(a) else 1 if by_ids.has(a) else 2] += d
	return out


static func _close_due(now: float) -> void:
	for id in _open.keys():
		var o: Dictionary = _open[id]
		var ship = o.ship
		if not o.has("early") and now >= float(o.t0) + float(o.early_s):
			var e := _since(id, o.taken0, o.on, o.by)
			o["early"] = e[0] + e[1] + e[2]
		var dur: float = float(o.t_end) - float(o.t0)
		var slices: Array = DamageExpectation.TURNOUT_SLICES_S
		while (o.cum as Array).size() < slices.size() and slices[(o.cum as Array).size()] < dur \
				and now >= float(o.t0) + slices[(o.cum as Array).size()]:
			(o.cum as Array).append(_since(id, o.taken0, o.on, o.by))
		var dead: bool = not is_instance_valid(ship) or not ship.is_alive()
		if now < float(o.t_end) and not dead:
			continue
		_open.erase(id)
		var r := _since(id, o.taken0, o.on, o.by)
		# A run cut short by death books only its whole slices.
		if not dead:
			(o.cum as Array).append(r)
		_book_turnout(o)
		var p: Dictionary = probes.get_or_add(o.key, {"n": 0, "pred": 0.0, "pred_on": 0.0, "pred_by": 0.0, "pred_early": 0.0,
			"real": 0.0, "real_on": 0.0, "real_by": 0.0, "real_other": 0.0, "real_early": 0.0, "over_hp": 0, "died": 0, "died_over": 0, "learn": 0.0})
		var over: bool = float(o.pred) > float(o.hp)
		p.n += 1
		p.pred += float(o.pred)
		p.pred_on += float(o.split.on)
		p.pred_by += float(o.split.by)
		p.pred_early += float(o.split.early)
		p.learn += float(o.split.get("learn", 0.0))
		p.real += r[0] + r[1] + r[2]
		p.real_on += r[0]
		p.real_by += r[1]
		p.real_other += r[2]
		p.real_early += float(o.get("early", r[0] + r[1] + r[2]))
		p.over_hp += int(over)
		p.died += int(dead)
		p.died_over += int(dead and over)


static func _book_turnout(o: Dictionary) -> void:
	var prev := [0.0, 0.0, 0.0]
	for i in (o.cum as Array).size():
		var c: Array = o.cum[i]
		var cell: Dictionary = (samples.turnout as Dictionary).get_or_add("%s|%d" % [o.turnout, i],
			{"n": 0, "pred_on": 0.0, "pred_by": 0.0, "real_on": 0.0, "real_by": 0.0, "real_other": 0.0})
		cell.n += 1
		cell.pred_on += float(o.split.slices_on[i]) if i < (o.split.slices_on as Array).size() else 0.0
		cell.pred_by += float(o.split.slices_by[i]) if i < (o.split.slices_by as Array).size() else 0.0
		cell.real_on += float(c[0]) - float(prev[0])
		cell.real_by += float(c[1]) - float(prev[1])
		cell.real_other += float(c[2]) - float(prev[2])
		prev = c


static func _row(shooter: Ship, target: Ship, range_m: float) -> Dictionary:
	var key := "%s|%s|%d|%s" % [shooter.ship_name, Ship.ShipClass.keys()[target.ship_class], int(range_m / RANGE_BAND_M), target.ship_name]
	return rows.get_or_add(key, {"salvos": 0, "shells": 0, "pred": 0.0, "pred_cit": 0.0, "pred_hits": 0.0, "real": 0.0, "real_cit": 0.0, "hits": 0})


static func on_fire(shooter: Ship, aim: Vector3, shells: int, shell: ShellParams) -> void:
	var server: Node = shooter.get_node_or_null("/root/Server")
	if server == null or shooter.team == null or shells <= 0:
		return
	var target: Ship = null
	var best := AIM_MATCH_M
	for e in server.get_all_ships():
		if e is Ship and is_instance_valid(e) and e.is_alive() and e.team != null and e.team.team_id != shooter.team.team_id:
			var d: float = Vector2(e.global_position.x - aim.x, e.global_position.z - aim.z).length()
			if d < best:
				best = d
				target = e
	if target == null:
		return
	var range_m: float = shooter.global_position.distance_to(target.global_position)
	BotGunnery.damage_model(shooter)
	var e: Dictionary = BotGunnery.damage_model(target).get_expected(shooter.get_instance_id(), target.get_instance_id(),
		range_m, BotGunnery.aspect_from(target, shooter.global_position))
	if e.is_empty():
		return
	var he: bool = shell.type == ShellParams.ShellType.HE
	var ev: float = float(e.he_ev) - float(e.he_fire_ev) if he else float(e.ap_ev)
	var r := _row(shooter, target, range_m)
	r.salvos += 1
	r.shells += shells
	r.pred += ev * shells
	r.pred_cit += ev * shells * float(e.he_cit if he else e.ap_cit)
	r.pred_hits += float(e.he_landed if he else e.ap_landed) * shells
	var c := _salvo_cell(shooter, target)
	c.n += 1
	c.pred += ev * shells
	c.pred_cit += ev * shells * float(e.he_cit if he else e.ap_cit)


static func on_hit(shooter: Ship, target: Ship, hit_type: int, damage: float) -> void:
	# Zero-damage results (ricochet, shatter) still land on the hull; the model's landed share counts them.
	if not is_instance_valid(shooter) or not is_instance_valid(target):
		return
	_close_due(SimClock.now())
	var r := _row(shooter, target, shooter.global_position.distance_to(target.global_position))
	var by: Dictionary = taken.get_or_add(target.get_instance_id(), {})
	by[shooter.get_instance_id()] = float(by.get(shooter.get_instance_id(), 0.0)) + damage
	r.real += damage
	r.hits += 1
	var c := _salvo_cell(shooter, target)
	c.real += damage
	if hit_type == 5 or hit_type == 6:
		r.real_cit += damage
		c.real_cit += damage


static func summary() -> Dictionary:
	return rows


static func probe_summary() -> Dictionary:
	_close_due(SimClock.now())
	return probes


static func veto_summary() -> Dictionary:
	return vetoes
