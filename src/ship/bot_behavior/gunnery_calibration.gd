class_name GunneryCalibration

## Main-battery damage the baked model (DamageModel.get_expected, what SkillStance prices) expected
## against what landed, by shooter hull, target class and range band, for match metrics.
## Expected is booked when a gun fires, on the enemy nearest its aim point; landed when Stats records a hit.

const RANGE_BAND_M := 5000.0
const AIM_MATCH_M := 1500.0

## "shooter|target class|band|target hull" -> {salvos, shells, pred, pred_cit, real, real_cit, hits}, and per hit result
## code n_, real_, full_ (full-pool payout), sized_ (full_ after HPManager.size_mod)
static var rows: Dictionary = {}
## Ship instance id -> {attacker instance id -> main-battery damage it has taken from it}.
static var taken: Dictionary = {}
## SkillStance's priced manoeuvres against what the hull then took over as long, one open per ship;
## closed into probes "class|kind|duration band" (PROBE_BANDS_S): predicted (pred: as priced; on / by / dark:
## from shooters on us / bystanders / unspotted; early: in the turn's swing) against real (on / by / dark /
## other: from those ships, from anyone else; early), plus over_hp, died, died_over.
const PROBE_BANDS_S := [30.0, 60.0, 120.0]
static var _open: Dictionary = {}
static var probes: Dictionary = {}
## Class -> {cheaper: fresh prices where turning won, vetoed: of those, the swing outweighed HP}.
static var vetoes: Dictionary = {}
## What `make learn` folds into DamageExpectation's table, saved per bot-only match:
## salvo "shooter|fp|target|fp|range band|aspect band" -> {n, pred, real, pred_cit, real_cit, shells, hits, pred_hits};
## turnout "hull|fp|kind|slice" -> {n, pred_on, pred_by, pred_dark, real_on, real_by, real_dark, real_other}; lead "target|fp|band"
## (DamageExpectation.LEAD_BAND_M) -> {n, abs_along, abs_across}; hulls name -> {scene, fp, cls}.
const SAMPLES_DIR := "user://damage_samples"
static var samples := {"salvo": {}, "turnout": {}, "lead": {}, "hulls": {}}


static func _hull(ship: Ship) -> String:
	var fp := DamageExpectation.fingerprint(ship)
	if not (samples.hulls as Dictionary).has(ship.ship_name):
		samples.hulls[ship.ship_name] = {"scene": ship.scene_file_path, "fp": fp, "cls": DamageExpectation.class_name_of(ship)}
	return "%s|%s" % [ship.ship_name, fp]


static func _salvo_cell(shooter: Ship, target: Ship) -> Dictionary:
	var key := "%s|%s|%d|%d" % [_hull(shooter), _hull(target),
		DamageExpectation.range_band(shooter.global_position.distance_to(target.global_position)),
		DamageExpectation.aspect_band(BotGunnery.aspect_from(target, shooter.global_position))]
	return (samples.salvo as Dictionary).get_or_add(key, {"n": 0, "pred": 0.0, "real": 0.0, "pred_cit": 0.0, "real_cit": 0.0,
		"shells": 0, "hits": 0, "pred_hits": 0.0})


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
	_pending_aims.clear()
	_bots.clear()
	taken.clear()
	_shell_of.clear()
	samples = {"salvo": {}, "turnout": {}, "lead": {}, "hulls": {}}


## Where bots aim and where that aim sits on the hull when the shell arrives, by "shooter class|target
## class|range band|stern, mid or bow": n (salvos), along / abs_along (offset forward of centre, in half-lengths), abs_across
## (half-beams), height (m); at impact n_imp, err_along / abs_err_along / abs_err_across (m, aim point at
## impact less the offset aimed for), err_hd (horizontal error in dispersion half-widths), on_hull (aim
## point still inside the hull's length and beam).
static var aims: Dictionary = {}
static var _pending_aims: Array = []
## Ship instance id -> its BotControllerV4 (a child of Modules), or null for a human.
static var _bots: Dictionary = {}


static func _bot_of(ship: Ship) -> BotControllerV4:
	var id := ship.get_instance_id()
	if not _bots.has(id):
		_bots[id] = null
		var modules := ship.get_node_or_null("Modules")
		if modules != null:
			for c in modules.get_children():
				if c is BotControllerV4:
					_bots[id] = c
	return _bots[id]


## Where on the hull the offset sits: the ends swing when the target turns.
const AIM_END_SHARE := 0.3


static func _aim_row(shooter: Ship, target: Ship, range_m: float, along: float) -> Dictionary:
	var region := "stern" if along < -AIM_END_SHARE else "bow" if along > AIM_END_SHARE else "mid"
	return aims.get_or_add("%s|%s|%d|%s" % [DamageExpectation.class_name_of(shooter), DamageExpectation.class_name_of(target),
		int(range_m / RANGE_BAND_M), region], {"n": 0, "along": 0.0, "abs_along": 0.0, "abs_across": 0.0, "height": 0.0,
		"n_imp": 0, "err_along": 0.0, "abs_err_along": 0.0, "abs_err_across": 0.0, "err_hd": 0.0, "on_hull": 0})


static func _book_aim(shooter: Ship, target: Ship, aim: Vector3, range_m: float, shell: ShellParams) -> void:
	var ctrl := _bot_of(shooter)
	if ctrl == null or ctrl.behavior == null:
		return
	var cached: Dictionary = ctrl.behavior._aim_cache.get(target, {})
	if not cached.has("offset"):
		return
	var o: Vector3 = cached.offset
	var mc = target.movement_controller
	var half_len: float = maxf(mc.ship_length * 0.5, 1.0)
	var half_beam: float = maxf(mc.ship_beam * 0.5, 1.0)
	var r := _aim_row(shooter, target, range_m, -o.z / half_len)
	r.n += 1
	r.along += -o.z / half_len
	r.abs_along += absf(o.z) / half_len
	r.abs_across += absf(o.x) / half_beam
	r.height += o.y
	var mounts := BotGunnery._batteries(shooter, BotGunnery.KIND_MAIN, range_m)
	var hd: float = BotGunnery._half_disp(mounts[0], range_m).x if not mounts.is_empty() else 0.0
	# The shell's own flight to the aim point, in shell-seconds, which the projectile manager runs time_mult times fast.
	var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(shooter.global_position, aim, shell)
	var tof: float = float(sol[1]) if sol[0] != null else BotGunnery.flight_time(shooter, range_m)
	_pending_aims.append({"target": target, "aim": aim, "o": o, "row": r, "hd": hd, "half_len": half_len,
		"half_beam": half_beam, "t": SimClock.now() + tof / ProjectileManager.get_shell_time_multiplier(),
		"lead": "%s|%d" % [_hull(target), int(range_m / DamageExpectation.LEAD_BAND_M)]})


static func _close_aims(now: float) -> void:
	var keep: Array = []
	for p in _pending_aims:
		if now < float(p.t):
			keep.append(p)
			continue
		var target = p.target
		if not is_instance_valid(target) or not target.is_alive():
			continue
		var at: Vector3 = target.to_local(p.aim)
		var err: Vector3 = at - (p.o as Vector3)
		var r: Dictionary = p.row
		r.n_imp += 1
		r.err_along += -err.z
		r.abs_err_along += absf(err.z)
		r.abs_err_across += absf(err.x)
		r.err_hd += Vector2(err.x, err.z).length() / maxf(float(p.hd), 1.0)
		r.on_hull += int(absf(at.z) <= float(p.half_len) and absf(at.x) <= float(p.half_beam))
		var lc: Dictionary = (samples.lead as Dictionary).get_or_add(p.lead, {"n": 0, "abs_along": 0.0, "abs_across": 0.0})
		lc.n += 1
		lc.abs_along += absf(err.z)
		lc.abs_across += absf(err.x)
	_pending_aims = keep


static func aim_summary() -> Dictionary:
	_close_aims(SimClock.now())
	return aims


static func on_veto(ship: Ship, vetoed: bool) -> void:
	var v: Dictionary = vetoes.get_or_add(Ship.ShipClass.keys()[ship.ship_class], {"cheaper": 0, "vetoed": 0})
	v.cheaper += 1
	v.vetoed += int(vetoed)


static func open_probe(ship: Ship, kind: StringName, pred: float, dur: float, early_s: float, split: Dictionary, on_ids: Array, by_ids: Array,
		dark_ids: Array) -> void:
	var now: float = SimClock.now()
	_close_due(now)
	var id := ship.get_instance_id()
	if _open.has(id) or not is_finite(pred) or dur <= 0.0:
		return
	var band := 0
	while band < PROBE_BANDS_S.size() and dur > PROBE_BANDS_S[band]:
		band += 1
	_open[id] = {"ship": ship, "key": "%s|%s|%d|%s" % [Ship.ShipClass.keys()[ship.ship_class], kind, band, ship.ship_name], "pred": pred,
		"split": split, "on": on_ids, "by": by_ids, "dark": dark_ids, "hp": ship.health_controller.current_hp,
		"taken0": (taken.get(id, {}) as Dictionary).duplicate(), "t0": now, "t_end": now + dur, "early_s": early_s,
		"turnout": "%s|%s" % [_hull(ship), kind], "cum": [], "tags": _unpriced_tags(ship, on_ids + by_ids + dark_ids)}


## Enemies the probe did not price, by why: OTHER_TAGS (dark: unspotted; _far: beyond its guns). Absent ones (dead at open) book as "dead".
const OTHER_TAGS := ["dark", "dark_far", "far", "tuck"]


static func _unpriced_tags(ship: Ship, priced: Array) -> Dictionary:
	var out := {}
	var server: Node = ship.get_node_or_null("/root/Server")
	if server == null or ship.team == null:
		return out
	var spotted := {}
	for e in server.get_valid_targets(ship.team.team_id):
		if is_instance_valid(e):
			spotted[e.get_instance_id()] = true
	for e in server.get_all_ships():
		if not (e is Ship) or not is_instance_valid(e) or not e.is_alive() or e.team == null or e.team.team_id == ship.team.team_id:
			continue
		var id: int = e.get_instance_id()
		if priced.has(id):
			continue
		var reach: float = e.artillery_controller.get_params()._range if e.artillery_controller != null else 0.0
		var far: bool = e.global_position.distance_to(ship.global_position) > reach
		out[id] = ("dark_far" if far else "dark") if not spotted.has(id) else "far" if far else "tuck"
	return out


## Damage probe `o` of ship `id` has taken since it opened, as [from its on, by, dark ids, from anyone else].
static func _since(id: int, o: Dictionary) -> Array:
	var out := [0.0, 0.0, 0.0, 0.0]
	var now_by: Dictionary = taken.get(id, {})
	for a in now_by:
		var d: float = float(now_by[a]) - float((o.taken0 as Dictionary).get(a, 0.0))
		out[0 if (o.on as Array).has(a) else 1 if (o.by as Array).has(a) else 2 if (o.dark as Array).has(a) else 3] += d
	return out


static func _close_due(now: float) -> void:
	for id in _open.keys():
		var o: Dictionary = _open[id]
		var ship = o.ship
		if not o.has("early") and now >= float(o.t0) + float(o.early_s):
			var e := _since(id, o)
			o["early"] = e[0] + e[1] + e[2] + e[3]
		var dur: float = float(o.t_end) - float(o.t0)
		var slices: Array = DamageExpectation.TURNOUT_SLICES_S
		while (o.cum as Array).size() < slices.size() and slices[(o.cum as Array).size()] < dur \
				and now >= float(o.t0) + slices[(o.cum as Array).size()]:
			(o.cum as Array).append(_since(id, o))
		var dead: bool = not is_instance_valid(ship) or not ship.is_alive()
		if now < float(o.t_end) and not dead:
			continue
		_open.erase(id)
		var r := _since(id, o)
		var why := _other_split(id, o)
		# A run cut short by death books only its whole slices.
		if not dead:
			(o.cum as Array).append(r)
		_book_turnout(o)
		var p: Dictionary = probes.get_or_add(o.key, {"n": 0, "pred": 0.0, "pred_on": 0.0, "pred_by": 0.0, "pred_dark": 0.0, "pred_early": 0.0,
			"real": 0.0, "real_on": 0.0, "real_by": 0.0, "real_dark": 0.0, "real_other": 0.0, "real_early": 0.0, "over_hp": 0, "died": 0,
			"died_over": 0, "learn": 0.0})
		var over: bool = float(o.pred) > float(o.hp)
		p.n += 1
		p.pred += float(o.pred)
		p.pred_on += float(o.split.on)
		p.pred_by += float(o.split.by)
		p.pred_dark += float(o.split.dark)
		p.pred_early += float(o.split.early)
		p.learn += float(o.split.get("learn", 0.0))
		p.real += r[0] + r[1] + r[2] + r[3]
		p.real_on += r[0]
		p.real_by += r[1]
		p.real_dark += r[2]
		p.real_other += r[3]
		for tag in why:
			p["other_" + tag] = float(p.get("other_" + tag, 0.0)) + float(why[tag])
		for tag in OTHER_TAGS:
			p["n_" + tag] = float(p.get("n_" + tag, 0.0)) + float((o.tags as Dictionary).values().count(tag))
		p.real_early += float(o.get("early", r[0] + r[1] + r[2] + r[3]))
		p.over_hp += int(over)
		p.died += int(dead)
		p.died_over += int(dead and over)


## Damage from unpriced attackers since the probe opened, by OTHER_TAGS (or "dead").
static func _other_split(id: int, o: Dictionary) -> Dictionary:
	var out := {}
	var now_by: Dictionary = taken.get(id, {})
	for a in now_by:
		if (o.on as Array).has(a) or (o.by as Array).has(a) or (o.dark as Array).has(a):
			continue
		var tag: String = (o.tags as Dictionary).get(a, "dead")
		out[tag] = float(out.get(tag, 0.0)) + float(now_by[a]) - float((o.taken0 as Dictionary).get(a, 0.0))
	return out


static func _book_turnout(o: Dictionary) -> void:
	var prev := [0.0, 0.0, 0.0, 0.0]
	for i in (o.cum as Array).size():
		var c: Array = o.cum[i]
		var cell: Dictionary = (samples.turnout as Dictionary).get_or_add("%s|%d" % [o.turnout, i],
			{"n": 0, "pred_on": 0.0, "pred_by": 0.0, "pred_dark": 0.0, "real_on": 0.0, "real_by": 0.0, "real_dark": 0.0, "real_other": 0.0})
		cell.n += 1
		cell.pred_on += float(o.split.slices_on[i]) if i < (o.split.slices_on as Array).size() else 0.0
		cell.pred_by += float(o.split.slices_by[i]) if i < (o.split.slices_by as Array).size() else 0.0
		cell.pred_dark += float(o.split.slices_dark[i]) if i < (o.split.slices_dark as Array).size() else 0.0
		cell.real_on += float(c[0]) - float(prev[0])
		cell.real_by += float(c[1]) - float(prev[1])
		cell.real_dark += float(c[2]) - float(prev[2])
		cell.real_other += float(c[3]) - float(prev[3])
		prev = c


## Shooter instance id -> the main-battery shell it last fired, for a hit's full-pool payout.
static var _shell_of: Dictionary = {}
## Of a shell's damage, what each NativeArmorInteraction result pays into full pools.
const PAYOUT := [BotGunnery.DMG_PENETRATION, BotGunnery.DMG_PARTIAL_PEN, 0.0, BotGunnery.DMG_OVERPENETRATION, 0.0,
	BotGunnery.DMG_CITADEL, BotGunnery.DMG_CITADEL_OVERPEN]


static func _row(shooter: Ship, target: Ship, range_m: float) -> Dictionary:
	var key := "%s|%s|%d|%s" % [shooter.ship_name, Ship.ShipClass.keys()[target.ship_class], int(range_m / RANGE_BAND_M), target.ship_name]
	return rows.get_or_add(key, {"salvos": 0, "shells": 0, "pred": 0.0, "pred_cit": 0.0, "pred_hits": 0.0, "real": 0.0, "real_cit": 0.0, "hits": 0})


static func on_fire(shooter: Ship, aim: Vector3, shells: int, shell: ShellParams) -> void:
	var server: Node = shooter.get_node_or_null("/root/Server")
	if server == null or shooter.team == null or shells <= 0:
		return
	_shell_of[shooter.get_instance_id()] = shell
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
	_close_aims(SimClock.now())
	_book_aim(shooter, target, aim, range_m, shell)
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
	c.shells += shells
	c.pred_hits += float(e.he_landed if he else e.ap_landed) * shells
	c.pred += ev * shells
	c.pred_cit += ev * shells * float(e.he_cit if he else e.ap_cit)


static func on_hit(shooter: Ship, target: Ship, hit_type: int, damage: float) -> void:
	# Zero-damage results (ricochet, shatter) still land on the hull; the model's landed share counts them.
	if not is_instance_valid(shooter) or not is_instance_valid(target):
		return
	_close_due(SimClock.now())
	_close_aims(SimClock.now())
	var r := _row(shooter, target, shooter.global_position.distance_to(target.global_position))
	var by: Dictionary = taken.get_or_add(target.get_instance_id(), {})
	by[shooter.get_instance_id()] = float(by.get(shooter.get_instance_id(), 0.0)) + damage
	r.real += damage
	r.hits += 1
	var c := _salvo_cell(shooter, target)
	c.hits += 1
	c.real += damage
	if hit_type == 5 or hit_type == 6:
		r.real_cit += damage
		c.real_cit += damage
	var shell: ShellParams = _shell_of.get(shooter.get_instance_id())
	if shell == null or hit_type < 0 or hit_type >= PAYOUT.size():
		return
	var full: float = shell.damage * float(PAYOUT[hit_type])
	var t := str(hit_type)
	r["n_" + t] = float(r.get("n_" + t, 0.0)) + 1.0
	r["real_" + t] = float(r.get("real_" + t, 0.0)) + damage
	r["full_" + t] = float(r.get("full_" + t, 0.0)) + full
	r["sized_" + t] = float(r.get("sized_" + t, 0.0)) + full * HPManager.size_mod(target.mass, shell.caliber)


static func summary() -> Dictionary:
	return rows


static func probe_summary() -> Dictionary:
	_close_due(SimClock.now())
	return probes


static func veto_summary() -> Dictionary:
	return vetoes
