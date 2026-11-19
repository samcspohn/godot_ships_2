class_name ExposureStats

## Side-neutral per-ship exposure samples, once a second: where damage is taken (lit, silent, shooters,
## angle to the nearest shooter, range, speed). Keyed "apt|ship" at write time.

const DT := 1.0
const SHOOTER_BINS := 9
const ANGLE_BIN_DEG := 15.0
const RANGE_BIN_M := 4000.0
const RANGE_BINS := 6
const SPEED_BIN_MPS := 5.0
const SPEED_BINS := 4
const LOW_HP := 0.3
const AHEAD_BIN_M := 2000.0
const AHEAD_BINS := 6
const CLOSING_EDGES := [-5.0, -1.0, 1.0, 5.0]
const ALLY_EDGES := [2000.0, 4000.0, 8000.0]
const PHASE_BIN_S := 120.0
const PHASE_BINS := 10
const FIGHT_MODES := ["station", "cover", "spot"]
const USE_TYPES := {
	ConsumableItem.ConsumableType.REPAIR_PARTY: "repair", ConsumableItem.ConsumableType.DAMAGE_CONTROL: "dc",
	ConsumableItem.ConsumableType.SMOKE_SCREEN: "smoke", ConsumableItem.ConsumableType.HYDROACOUSTIC_SEARCH: "hydro",
	ConsumableItem.ConsumableType.RADAR: "radar",
}

static var rows: Dictionary = {}
static var _prev: Dictionary = {}
static var _using: Dictionary = {}


static func clear() -> void:
	rows.clear()
	_prev.clear()
	_using.clear()


static func _row(ship: Ship) -> Dictionary:
	if not rows.has(ship):
		rows[ship] = {
			"t": 0.0, "dmg": 0.0, "t_lit": 0.0, "dmg_lit": 0.0, "t_silent": 0.0, "dmg_silent": 0.0,
			"t_dark_fire": 0.0, "shooters_visible": 0.0,
		"t_spot": 0.0, "t_spot_lit": 0.0, "t_sole": 0.0, "t_sole_useful": 0.0, "spot_n": 0.0, "spot_d": 0.0,
		"t_enemy_lit": 0.0, "t_team_blind": 0.0,
		"t_first_low": -1.0, "t_low_lit": 0.0, "dmg_low_lit": 0.0, "low_shooters": 0.0, "equip": [], "uses": {}, "use_t": {},
			"shooters": _bins(SHOOTER_BINS), "angle": _bins(6), "range": _bins(RANGE_BINS), "speed": _bins(SPEED_BINS),
			"los": _bins(SHOOTER_BINS), "ahead": _bins(AHEAD_BINS), "closing": _bins(CLOSING_EDGES.size() + 1),
			"ally": _bins(ALLY_EDGES.size() + 1), "phase": _bins(PHASE_BINS), "phase_lit": _bins(PHASE_BINS), "mode": {},
		}
	return rows[ship]


static func _bins(n: int) -> Dictionary:
	var t := PackedFloat64Array()
	t.resize(n)
	var d := PackedFloat64Array()
	d.resize(n)
	return {"t": t, "dmg": d}


static func _add(b: Dictionary, k: int, dmg: float) -> void:
	b["t"][k] += DT
	b["dmg"][k] += dmg


static func _edge_bin(x: float, edges: Array) -> int:
	var k := 0
	while k < edges.size() and x >= edges[k]:
		k += 1
	return k


static func _centroids(all: Array[Ship]) -> Dictionary:
	var sum := {}
	for s in all:
		var t: int = s.team.team_id
		var a: Array = sum.get(t, [Vector2.ZERO, 0])
		sum[t] = [a[0] + Vector2(s.global_position.x, s.global_position.z), a[1] + 1]
	var out := {}
	for t in sum:
		out[t] = sum[t][0] / sum[t][1]
	return out


static func _mode(me: Ship, hub: Bot5Hub) -> String:
	if hub != null and hub.is_v5(me):
		return hub.mode_of(me)
	var bc = me.get_node_or_null("Modules/BotController")
	if bc == null or bc.behavior == null:
		return "none"
	var b: BotBehavior = bc.behavior
	var n := String(b._active_skill_name)
	return n + "/" + FIGHT_MODES[b._skill_fight.mode] if n == "Fight" else n


## Geometry columns: enemies in their gun range with clear LOS, ahead of own centroid toward the enemy's,
## closing speed on the nearest enemy, nearest ally, match phase, and the bot's mode.
static func _geometry(r: Dictionary, me: Ship, pos: Vector2, vel: Vector2, all: Array[Ship], cen: Dictionary,
		dmg: float, hub: Bot5Hub) -> void:
	var los := 0
	var nearest := INF
	var near_p := Vector2.ZERO
	var ally := INF
	for e in all:
		if e == me:
			continue
		var ep := Vector2(e.global_position.x, e.global_position.z)
		var d := ep.distance_to(pos)
		if e.team.team_id == me.team.team_id:
			ally = minf(ally, d)
			continue
		if d < nearest:
			nearest = d
			near_p = ep
		var gp = e.artillery_controller.get_params() if e.artillery_controller != null else null
		if gp != null and d <= gp._range and not NavigationMapManager.is_los_blocked_2d(ep, pos):
			los += 1
	_add(r["los"], mini(los, SHOOTER_BINS - 1), dmg)
	var mine: Vector2 = cen.get(me.team.team_id, pos)
	var theirs: Vector2 = cen.get(1 - me.team.team_id, mine)
	var axis := (theirs - mine).normalized()
	if axis != Vector2.ZERO:
		var a := (pos - mine).dot(axis)
		_add(r["ahead"], clampi(int(floor(a / AHEAD_BIN_M)) + AHEAD_BINS / 2, 0, AHEAD_BINS - 1), dmg)
	if nearest < INF:
		_add(r["closing"], _edge_bin(vel.dot((near_p - pos) / maxf(nearest, 1.0)), CLOSING_EDGES), dmg)
	if ally < INF:
		_add(r["ally"], _edge_bin(ally, ALLY_EDGES), dmg)
	var ph := mini(int(r["t"] / PHASE_BIN_S), PHASE_BINS - 1)
	_add(r["phase"], ph, dmg)
	if me.visible_to_enemy:
		_add(r["phase_lit"], ph, dmg)
	var m := _mode(me, hub)
	var row: Array = r["mode"].get(m, [0.0, 0.0, 0.0])
	r["mode"][m] = [row[0] + DT, row[1] + dmg, row[2] + (DT if me.visible_to_enemy else 0.0)]


static func sample(teams_ships: Array, hub: Bot5Hub = null) -> void:
	var all: Array[Ship] = []
	for ships in teams_ships:
		for s in ships:
			if is_instance_valid(s) and s.is_alive():
				all.append(s)
	var cen := _centroids(all)
	for me in all:
		var hp: float = me.health_controller.current_hp
		var pos := Vector2(me.global_position.x, me.global_position.z)
		var prev: Dictionary = _prev.get(me, {"hp": hp, "pos": pos})
		_prev[me] = {"hp": hp, "pos": pos}
		var dmg := maxf(float(prev["hp"]) - hp, 0.0)
		var speed := pos.distance_to(prev["pos"]) / DT
		var fired: bool = me.concealment.blooms.size() > 0
		var shooters := 0
		var visible := 0
		var nearest := INF
		var near_dir := Vector2.ZERO
		for e in all:
			if e.team.team_id == me.team.team_id:
				continue
			var ep := Vector2(e.global_position.x, e.global_position.z)
			var d := ep.distance_to(pos)
			if d < nearest:
				nearest = d
				near_dir = (ep - pos) / maxf(d, 1.0)
			var gp = e.artillery_controller.get_params() if e.artillery_controller != null else null
			if gp != null and d <= gp._range:
				shooters += 1
				if e.visible_to_enemy:
					visible += 1
		var r := _row(me)
		_spotting(r, me, pos, all)
		_consumables(r, me)
		_geometry(r, me, pos, (pos - prev["pos"]) / DT, all, cen, dmg, hub)
		var low: bool = hp < LOW_HP * me.health_controller.max_hp
		if low and r["t_first_low"] < 0.0:
			r["t_first_low"] = r["t"]
		r["t"] += DT
		r["dmg"] += dmg
		_add(r["speed"], mini(int(speed / SPEED_BIN_MPS), SPEED_BINS - 1), dmg)
		if nearest < INF:
			_add(r["range"], mini(int(nearest / RANGE_BIN_M), RANGE_BINS - 1), dmg)
		if not me.visible_to_enemy:
			if fired:
				r["t_dark_fire"] += DT
			continue
		r["t_lit"] += DT
		r["dmg_lit"] += dmg
		if low and shooters > 0:
			r["t_low_lit"] += DT
			r["dmg_low_lit"] += dmg
			r["low_shooters"] += shooters * DT
		if not fired:
			r["t_silent"] += DT
			r["dmg_silent"] += dmg
		r["shooters_visible"] += visible
		_add(r["shooters"], mini(shooters, SHOOTER_BINS - 1), dmg)
		if shooters > 0:
			var f3: Vector3 = -me.global_transform.basis.z
			var fwd := Vector2(f3.x, f3.z).normalized()
			var ang := rad_to_deg(acos(clampf(absf(fwd.dot(near_dir)), 0.0, 1.0)))
			_add(r["angle"], mini(int(ang / ANGLE_BIN_DEG), 5), dmg)


## Activations and active seconds per equipped sensor, smoke, repair and damage control.
static func _consumables(r: Dictionary, me: Ship) -> void:
	var cm: ConsumableManager = me.consumable_manager
	if cm == null:
		return
	if r["equip"].is_empty():
		for c in cm.equipped_consumables:
			if c != null and USE_TYPES.has(c.type):
				r["equip"].append(USE_TYPES[c.type])
	var prev: Dictionary = _using.get(me, {})
	var now := {}
	for t in USE_TYPES:
		var on := cm.is_using(t)
		now[t] = on
		if on:
			var k: String = USE_TYPES[t]
			r["use_t"][k] = float(r["use_t"].get(k, 0.0)) + DT
			if not prev.get(t, false):
				r["uses"][k] = int(r["uses"].get(k, 0)) + 1
	_using[me] = now


## Lighting an enemy; sole: no friend lights it; useful: a friend has it in gun range (v4 spot_holding).
static func _spotting(r: Dictionary, me: Ship, pos: Vector2, all: Array[Ship]) -> void:
	var n := 0
	var sole := false
	var useful := false
	var enemy_lit := false
	var near := INF
	for e in all:
		if e.team.team_id == me.team.team_id:
			continue
		if e.visible_to_enemy:
			enemy_lit = true
		if e.concealment == null or not e.concealment.spotters.has(me):
			continue
		n += 1
		var ep := Vector2(e.global_position.x, e.global_position.z)
		near = minf(near, ep.distance_to(pos))
		var others := false
		for f in e.concealment.spotters:
			if f != me and is_instance_valid(f) and f.team.team_id == me.team.team_id:
				others = true
		if others:
			continue
		sole = true
		for f in all:
			if f != me and f.team.team_id == me.team.team_id and f.artillery_controller != null \
					and Vector2(f.global_position.x, f.global_position.z).distance_to(ep) <= f.artillery_controller.get_params()._range:
				useful = true
	r["t_enemy_lit"] += DT if enemy_lit else 0.0
	r["t_team_blind"] += 0.0 if enemy_lit else DT
	if n == 0:
		return
	r["t_spot"] += DT
	r["spot_n"] += n * DT
	r["spot_d"] += near * DT
	r["t_spot_lit"] += DT if me.visible_to_enemy else 0.0
	r["t_sole"] += DT if sole else 0.0
	r["t_sole_useful"] += DT if useful else 0.0


static func summary(apt_of: Callable) -> Dictionary:
	var out := {}
	for ship in rows:
		if not is_instance_valid(ship):
			continue
		var key := "%s|%s|%s" % [apt_of.call(ship), ship.ship_name, ship.name]
		var r: Dictionary = rows[ship].duplicate(true)
		for b in ["shooters", "angle", "range", "speed", "los", "ahead", "closing", "ally", "phase", "phase_lit"]:
			r[b] = {"t": Array(r[b]["t"]), "dmg": Array(r[b]["dmg"])}
		out[key] = r
	return out
