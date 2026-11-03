class_name BotScenario
extends RefCounted

## A botmatch lineup with a top-level "scenario" block and per-ship state, set once every ship has spawned:
##   "scenario": {"duration_s": 60, "elapsed_s": 568, "trace": ["Yamato"], "log_dt": 1.0}
##   per ship: "pos": [x, z], "heading_deg" (0 = +Z, 90 = +X), "speed" (m/s, ahead), "hp" (absolute),
##   "reload": [main guns 0..1] (default all loaded, tubes too), "bloom_m": seen out to this, as if just fired, all scenario,
##   "fixed": {"throttle": -1..4, "rudder": -1..1}: no bot, this helm the whole scenario; with "path": [[x, z], ...] it steers through those,
##   "consumables": [{slot, used, last_s}]: charges spent and seconds since the last went off,
##   "torp_last_s": {launcher index: seconds since it launched}, "throttle": -1..4, "identified": its enemies have seen it, "lkp": {pos, age_s, vel, rot}: their last sighting
## "sunk": [{team, class}] already gone: the points stand as the clock and those sinks left them.
## Ends the match after duration_s; traced hulls print SCN lines every log_dt and their stance duel options.

var duration_s: float = 60.0
var elapsed_s: float = 0.0
var log_dt: float = 1.0
var trace: Dictionary = {}
var _started: float = -1.0
var _next_log: float = 0.0
var _bloom: Dictionary = {}
var _fixed: Dictionary = {}
var _paths: Dictionary = {}  # Ship -> [waypoints, next]
const PATH_REACHED_M := 400.0
const PATH_GAIN := 2.0
var _sunk: Array = []

func _init(cfg: Dictionary) -> void:
	duration_s = float(cfg.get("duration_s", duration_s))
	elapsed_s = float(cfg.get("elapsed_s", elapsed_s))
	log_dt = float(cfg.get("log_dt", log_dt))
	_sunk = cfg.get("sunk", [])
	for n in cfg.get("trace", []):
		trace[String(n)] = true

func start(server: GameServer) -> void:
	await server.get_tree().physics_frame
	for p_name in server.players:
		var ship: Ship = server.players[p_name][0]
		var e: Dictionary = server.team_info["team"].get(p_name, {})
		if e.has("pos"):
			ship.global_position = Vector3(float(e.pos[0]), 0.0, float(e.pos[1]))
		if e.has("heading_deg"):
			ship.rotation.y = deg_to_rad(float(e.heading_deg)) + PI
		if e.has("speed"):
			ship.linear_velocity = -ship.global_transform.basis.z * float(e.speed)
			# Under way, not just moving: the engine at the throttle that holds this speed.
			var mc = ship.movement_controller
			var share: float = clampf(float(e.speed) / maxf(mc.max_speed, 1.0), 0.0, 1.0)
			mc.throttle_level = clampi(ceili(share * 4.0), 0, 4)
			mc.engine_power = share
		if e.has("throttle"):
			ship.movement_controller.throttle_level = int(e.throttle)
		if e.has("hp"):
			var hc = ship.health_controller
			hc._current_hp = minf(float(e.hp), hc.max_hp) / hc.params.p().mult
		if ship.artillery_controller != null:
			var guns: Array = ship.artillery_controller.guns
			for i in guns.size():
				guns[i].reload = float(e.reload[i]) if e.has("reload") and i < (e.reload as Array).size() else 1.0
		if is_instance_valid(ship.torpedo_controller):
			var fired: Dictionary = e.get("torp_last_s", {})
			var launchers: Array = ship.torpedo_controller.launchers
			for i in launchers.size():
				launchers[i].reload = clampf(float(fired[str(i)]) / launchers[i].get_params().reload_time, 0.0, 1.0) \
					if fired.has(str(i)) else 1.0
		for c in e.get("consumables", []):
			_consumable(ship, int(c.slot), int(c.used), float(c.last_s))
		if e.has("bloom_m"):
			_bloom[ship] = float(e.bloom_m)
		if e.has("fixed"):
			var bc := ship.get_node_or_null("Modules/BotController")
			if bc != null:
				bc.process_mode = Node.PROCESS_MODE_DISABLED
			_fixed[ship] = [int(e.fixed.get("throttle", 4)), float(e.fixed.get("rudder", 0.0))]
			if e.fixed.has("path"):
				_paths[ship] = [PackedVector2Array(e.fixed.path.map(func(w): return Vector2(float(w[0]), float(w[1])))), 0]
	SkillStance.duel_trace = trace
	server.match_elapsed = elapsed_s
	_know(server)
	if not _sunk.is_empty():
		_points(server)
	_started = SimClock.now()
	print("SCN start: %d ships, %.0f s from match time %.0f s, clock %.3f" % [server.players.size(), duration_s, elapsed_s, _started])

## True once the scenario has run its duration.
func tick(server: GameServer) -> bool:
	if _started < 0.0:
		return false
	var t: float = SimClock.now() - _started
	for ship in _bloom:
		if is_instance_valid(ship) and ship.concealment != null:
			ship.concealment.bloom(_bloom[ship])
	for ship in _fixed:
		if is_instance_valid(ship):
			if _paths.has(ship):
				_fixed[ship][1] = _steer(ship, _paths[ship])
			ship.movement_controller.set_movement_input(_fixed[ship])
	if t >= _next_log:
		_next_log = t + log_dt
		for p_name in server.players:
			var ship: Ship = server.players[p_name][0]
			if trace.has(ship.ship_name) and is_instance_valid(ship):
				_log(ship, t)
	return t >= duration_s

## Rudder toward the next waypoint not yet within PATH_REACHED_M; the last is held.
static func _steer(ship: Ship, path: Array) -> float:
	var wps: PackedVector2Array = path[0]
	var at := Vector2(ship.global_position.x, ship.global_position.z)
	while int(path[1]) < wps.size() - 1 and at.distance_to(wps[path[1]]) < PATH_REACHED_M:
		path[1] = int(path[1]) + 1
	var to: Vector2 = wps[path[1]] - at
	var fwd := -ship.global_transform.basis.z
	return clampf(-angle_difference(atan2(fwd.x, fwd.z), atan2(to.x, to.y)) * PATH_GAIN, -1.0, 1.0)

func _log(ship: Ship, t: float) -> void:
	var fwd := -ship.global_transform.basis.z
	var line := "SCN t=%5.1f %s hp=%.0f at=(%.0f,%.0f) hdg=%.0f spd=%.1f" % [t, ship.ship_name, ship.health_controller.current_hp,
		ship.global_position.x, ship.global_position.z, rad_to_deg(atan2(fwd.x, fwd.z)), ship.linear_velocity.length()]
	var bc := ship.get_node_or_null("Modules/BotController")
	if bc != null and bc.behavior != null and bc.process_mode != Node.PROCESS_MODE_DISABLED:
		var b: BotBehavior = bc.behavior
		var tgt: Ship = bc.target
		line += " skill=%s tgt=%s" % [b._active_skill_name, tgt.ship_name if is_instance_valid(tgt) else "-"]
		if is_instance_valid(tgt):
			line += " d=%.0f" % ship.global_position.distance_to(tgt.global_position)
		if ship.artillery_controller != null:
			line += " reload=%s" % [ship.artillery_controller.guns.map(func(g): return snappedf(g.reload, 0.01))]
		if is_instance_valid(ship.torpedo_controller) and not ship.torpedo_controller.launchers.is_empty():
			line += " tubes=%s torp_ok=%s" % [ship.torpedo_controller.launchers.map(func(l): return snappedf(l.reload, 0.01)),
				b.would_fire_torpedoes()]
		if bc._last_intent != null:
			var dst: Vector3 = bc._last_intent.target_position
			line += " dest=(%.0f,%.0f) dd=%.0f" % [dst.x, dst.z, ship.global_position.distance_to(dst)]
		line += " fight=[%s] cov1=%s lost=%s gb=%s" % [b._skill_fight.debug_text(), b.cover_first_last, b._skill_fight.cover.lost,
			b._is_gunboat(ship) if b.has_method("_is_gunboat") else "-"]
		line += " thr=%.2f dis=%s seen=%s prio=%s" % [b._threat_score_cache, b.churn.dis_why, ship.is_detected(), b.priority.ship.ship_name if not b.priority.is_empty() and is_instance_valid(b.priority.ship) else "ref" if not b.priority.is_empty() else "-"]
		if not b.priority.is_empty():
			var pp: Vector2 = b.priority.pos
			line += " ppos=(%.0f,%.0f) pd=%.0f" % [pp.x, pp.y, pp.distance_to(Vector2(ship.global_position.x, ship.global_position.z))]
		line += " | " + b._skill_stance.debug_text()
	print(line)

## What the enemy had seen of each ship by then: identified (its spawn reference retired) and its last sighting.
func _know(server: GameServer) -> void:
	var now: float = SimClock.now()
	for p_name in server.players:
		var ship: Ship = server.players[p_name][0]
		var e: Dictionary = server.team_info["team"].get(p_name, {})
		if ship.team == null:
			continue
		var them: int = 1 - ship.team.team_id
		if bool(e.get("identified", false)):
			server._identify(them, ship)
		if e.has("lkp"):
			var k: Dictionary = e.lkp
			server.teams[them].write_contact(ship, Vector3(float(k.pos[0]), 0.0, float(k.pos[1])), now - float(k.age_s),
				Vector3(float(k.vel[0]), 0.0, float(k.vel[1])), float(k.rot), GameServer.LKP_SOURCE_OBSERVED)

func _points(server: GameServer) -> void:
	var ticks: int = int(elapsed_s / GameServer.POINTS_TICK_S)
	for t in server.teams:
		t.points = TeamState.POINTS_START + ticks * GameServer.POINTS_TICK
	server._points_accrued_s = fmod(elapsed_s, GameServer.POINTS_TICK_S)
	for v in _sunk:
		var victim: int = int(v.team)
		server.teams[victim].points -= int(GameServer.KILL_POINTS_LOST[int(v["class"])])
		server.teams[1 - victim].points += int(GameServer.KILL_POINTS_GAINED[int(v["class"])])
	print("SCN points %d:%d after %d sinks" % [server.teams[0].points, server.teams[1].points, _sunk.size()])

## As ConsumableManager left it `last_s` after the last use: still running, cooling down, or ready.
static func _consumable(ship: Ship, slot: int, used: int, last_s: float) -> void:
	var cm = ship.consumable_manager
	if cm == null or slot >= cm.equipped_consumables.size() or cm.equipped_consumables[slot] == null:
		return
	var item: ConsumableItem = cm.equipped_consumables[slot]
	var p := item.p() as ConsumableItem
	if p.max_stack != -1:
		item.used = used
	if p.duration > 0.0 and last_s < p.duration:
		item.apply_effect(ship)
		cm.active_effects[item.id] = 1.0 - last_s / p.duration
	else:
		var left: float = p.cooldown_time - (last_s - maxf(p.duration, 0.0))
		if left > 0.0 and (p.max_stack == -1 or p.max_stack - item.used > 0):
			cm.cooldowns[item.id] = left / p.cooldown_time
	print("SCN %s %s: %d/%d used, active %.2f, cooldown %.2f" % [ship.ship_name, p.name, item.used, p.max_stack,
		cm.active_effects.get(item.id, 0.0), cm.cooldowns.get(item.id, 0.0)])
