class_name DestChurn
extends RefCounted

## Per behavior tick: jumps over JUMP_M in the skill's goal and in each later
## layer (easing, stance/spread, controller), the goal's attributed to the first
## state change that explains it.

const JUMP_M := 500.0

## "<class>" -> {s, ticks, multi_fight, goal: {cause: n}, layer: {layer: n}}
static var stats: Dictionary = {}

var goal := Vector2.INF
var stand := false
var stand_why := ""
var _stand_since := -1.0
var fight_calls := 0
var eased := Vector2.INF
var post := Vector2.INF
var arm := ""

var _prev := {}

## Disengage entries by trigger and episode exits, per class.
static var dis: Dictionary = {}
var dis_why := ""
var dis_ttd := 0.0
var dis_ttw := 0.0
var _dis_since := -1.0
var _dis_entry := ""
var _left_at := -INF
var _left_entry := ""

## Navigator health per class and context (in / just after a disengage, by its trigger).
const AFTER_S := 30.0
static var nav: Dictionary = {}
var _fails := 0

func nav_tick(beh: BotBehavior, ship: Ship, raw: ShipNavigator) -> void:
	if raw == null:
		return
	var ctx: String = "in_" + _dis_entry if beh._active_skill_name == &"Disengage" else (
		"after_" + _left_entry if SimClock.now() - _left_at < AFTER_S else "normal")
	var c: Dictionary = nav.get_or_add(Ship.ShipClass.keys()[ship.ship_class], {}).get_or_add(ctx,
		{"ticks": 0, "fail": 0, "relaxed": 0, "empty_path": 0, "no_station": 0, "stand": 0, "reasons": {}})
	c.ticks += 1
	var f: int = raw.get_path_failure_count()
	if f > _fails:
		c.fail += f - _fails
		_bump(c.reasons, raw.get_last_path_failure_reason_name())
	_fails = f
	if raw.is_path_threat_relaxed():
		c.relaxed += 1
	if raw.get_current_path().is_empty():
		c.empty_path += 1
	var now: float = SimClock.now()
	if stand:
		c.stand += 1
		_bump(c.get_or_add("stand_why", {}), stand_why if stand_why != "" else "other")
		if _stand_since < 0.0:
			_stand_since = now
	elif _stand_since >= 0.0:
		var s: float = now - _stand_since
		_bump(c.get_or_add("stand_s", {}), "<10" if s < 10.0 else ("<30" if s < 30.0 else ("<60" if s < 60.0 else ">=60")))
		_stand_since = -1.0
	if beh._active_skill_name == &"Fight" and not beh._skill_fight.current().has_station():
		c.no_station += 1

static func _bump(d: Dictionary, k: String) -> void:
	d[k] = int(d.get(k, 0)) + 1

## Called once per tick after the skill is settled: counts entries into and exits from Disengage.
func disengage_tick(beh: BotBehavior, ship: Ship, threat: float, prev_skill: StringName) -> void:
	var c: Dictionary = dis.get_or_add(Ship.ShipClass.keys()[ship.ship_class], {"entries": {}, "exits": {}, "dur_s": {}})
	var now: float = SimClock.now()
	var on: bool = beh._active_skill_name == &"Disengage"
	if on and prev_skill != &"Disengage":
		var seen: Array = []
		if ship.visible_to_enemy: seen.append("vis")
		if ship.det_radar: seen.append("radar")
		if ship.det_hydro: seen.append("hydro")
		if ship.det_air: seen.append("air")
		var band: String = "<0.2" if threat < 0.2 else ("<0.4" if threat < BotBehavior.DISENGAGE_THREAT else ">=0.4")
		var k := "%s threat%s by=%s" % [dis_why, band, "+".join(seen)]
		if dis_why == "ttw":
			var r: float = dis_ttd / dis_ttw
			k += " ttw=%s ttd/ttw=%s" % ["INF" if is_inf(dis_ttw) else ("<300s" if dis_ttw < 300.0 else ("<900s" if dis_ttw < 900.0 else ">=900s")),
				"<0.5" if r < 0.5 else ("<1" if r < 1.0 else ">=1")]
		_bump(c.entries, k)
		_bump(c.entries, "_total " + dis_why)
		_dis_since = now
		_dis_entry = dis_why
	elif not on and prev_skill == &"Disengage" and _dis_since >= 0.0:
		var why: String = "%s -> %s" % [_dis_entry, "dark" if not ship.is_detected() else "released lit"]
		_bump(c.exits, why)
		_left_at = now
		_left_entry = _dis_entry
		c.dur_s[why] = float(c.dur_s.get(why, 0.0)) + now - _dis_since
		_dis_since = -1.0
	dis_why = ""

static var handoffs: Dictionary = {}

static func handoff(kind: String, why: String) -> void:
	_bump(handoffs.get_or_add(kind, {}), why)

static func dis_summary() -> Dictionary:
	return {"episodes": dis, "nav": nav, "handoffs": handoffs}

static func summary() -> Dictionary:
	var out := {}
	for k in stats:
		var c: Dictionary = stats[k]
		var mins: float = maxf(float(c.s) / 60.0, 1e-6)
		var per_min := {}
		for g in [c.goal, c.layer]:
			for cause in g:
				per_min[cause] = snappedf(float(g[cause]) / mins, 0.01)
		out[k] = c.merged({"minutes": snappedf(mins, 0.1), "per_min": per_min})
	return out

func begin_tick() -> void:
	goal = Vector2.INF
	stand = false
	stand_why = ""
	fight_calls = 0
	eased = Vector2.INF
	post = Vector2.INF
	arm = ""

func sample(beh: BotBehavior, ship: Ship, dest: Vector3) -> void:
	if not goal.is_finite() or not post.is_finite():
		_prev = {}
		return
	var st := Vector2.INF
	var leg := -1
	match beh._active_skill_name:
		&"Fight":
			var p: SkillPosition = beh._skill_fight.current()
			if p.has_station():
				st = Vector2(p.station_position().x, p.station_position().z)
		&"Disengage":
			leg = beh._skill_disengage.leg
			if beh._skill_disengage.cover().has_station():
				var c: Vector3 = beh._skill_disengage.cover().station_position()
				st = Vector2(c.x, c.z)
	var now: float = SimClock.now()
	var cur := {"t": now, "goal": goal, "eased": eased, "post": post, "dest": Vector2(dest.x, dest.z),
		"skill": beh._active_skill_name, "mode": beh._skill_fight.mode, "leg": leg, "arm": arm,
		"prio": BotBehavior._priority_key(beh.priority) if not beh.priority.is_empty() else "",
		"station": st, "stand": stand}
	var c: Dictionary = stats.get_or_add(Ship.ShipClass.keys()[ship.ship_class],
		{"s": 0.0, "ticks": 0, "multi_fight": 0, "goal": {}, "layer": {}})
	c.ticks += 1
	if fight_calls > 1:
		c.multi_fight += 1
	if not _prev.is_empty():
		c.s += now - float(_prev.t)
		var jumped := func(key: String) -> bool: return (cur[key] as Vector2).distance_to(_prev[key]) > JUMP_M
		if jumped.call("goal"):
			c.goal[_cause(cur)] = int(c.goal.get(_cause(cur), 0)) + 1
		elif jumped.call("eased"):
			c.layer["ease"] = int(c.layer.get("ease", 0)) + 1
		elif jumped.call("post"):
			c.layer["post"] = int(c.layer.get("post", 0)) + 1
		elif jumped.call("dest"):
			c.layer["controller"] = int(c.layer.get("controller", 0)) + 1
		if jumped.call("dest"):
			c.layer["dest_total"] = int(c.layer.get("dest_total", 0)) + 1
	_freeze_check(beh, ship, cur)
	_prev = cur

## Fight's sailed point stuck >= FREEZE_TICKS while its goal is FREEZE_GAP_M off: one FREEZE line per run.
const FREEZE_GAP_M := 300.0
const FREEZE_TICKS := 8
var _frozen := 0

func _freeze_check(beh: BotBehavior, ship: Ship, cur: Dictionary) -> void:
	var f: SkillFight = beh._skill_fight
	var d: Vector2 = cur.dest
	if _prev.is_empty() or cur.skill != &"Fight" or d.distance_to(goal) < FREEZE_GAP_M \
			or d.distance_to(_prev.dest) > 2.0:
		_frozen = 0
		return
	_frozen += 1
	if _frozen != FREEZE_TICKS:
		return
	var c: Dictionary = stats[Ship.ShipClass.keys()[ship.ship_class]]
	c["freezes"] = int(c.get("freezes", 0)) + 1
	var at := Vector2(ship.global_position.x, ship.global_position.z)
	print("FREEZE ", JSON.stringify({"t": SimClock.now(), "ship": String(ship.name), "hull": ship.ship_name,
		"mode": SkillFight.Mode.keys()[f.mode], "arm": arm, "calls": fight_calls, "at": [at.x, at.y],
		"goal": [goal.x, goal.y], "shown": [f._shown.x, f._shown.y], "shown_dt": SimClock.now() - f._shown_at,
		"goal_held_s": SimClock.now() - f._goal_since, "eased": [eased.x, eased.y], "post": [post.x, post.y],
		"dest": [d.x, d.y], "path_n": f._path.size(), "path_i": f._path_i,
		"path_goal": [f._path_goal.x, f._path_goal.y], "stand": stand}))

func _cause(cur: Dictionary) -> String:
	if cur.skill != _prev.skill:
		return "skill:%s>%s" % [_prev.skill, cur.skill]
	if cur.skill == &"Fight" and cur.mode != _prev.mode:
		return "mode:%s>%s" % [SkillFight.Mode.keys()[_prev.mode], SkillFight.Mode.keys()[cur.mode]]
	if cur.leg != _prev.leg:
		return "leg"
	if cur.stand != _prev.stand:
		return "stand"
	if cur.arm != _prev.arm:
		return "arm:%s>%s" % [_prev.arm, cur.arm]
	if cur.prio != _prev.prio:
		return "priority"
	var a: Vector2 = cur.station
	var b: Vector2 = _prev.station
	if a.is_finite() != b.is_finite():
		return "station_lost" if not a.is_finite() else "station_new"
	if a.is_finite() and a.distance_to(b) > JUMP_M:
		return "station_moved"
	return "other"
