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


static func sample(teams_ships: Array) -> void:
	var all: Array[Ship] = []
	for ships in teams_ships:
		for s in ships:
			if is_instance_valid(s) and s.is_alive():
				all.append(s)
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
		for b in ["shooters", "angle", "range", "speed"]:
			r[b] = {"t": Array(r[b]["t"]), "dmg": Array(r[b]["dmg"])}
		out[key] = r
	return out
