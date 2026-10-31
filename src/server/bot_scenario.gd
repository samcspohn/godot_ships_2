class_name BotScenario
extends RefCounted

## A botmatch lineup with a top-level "scenario" block and per-ship state, set once every ship has spawned:
##   "scenario": {"duration_s": 60, "elapsed_s": 568, "trace": ["Yamato"], "log_dt": 1.0}
##   per ship: "pos": [x, z], "heading_deg" (0 = +Z, 90 = +X), "speed" (m/s, ahead), "hp" (absolute),
##   "reload": [main guns 0..1] (default all loaded, tubes too), "bloom_m": seen out to this, as if just fired, all scenario
## Ends the match after duration_s; traced hulls print SCN lines every log_dt and their stance duel options.

var duration_s: float = 60.0
var elapsed_s: float = 0.0
var log_dt: float = 1.0
var trace: Dictionary = {}
var _started: float = -1.0
var _next_log: float = 0.0
var _bloom: Dictionary = {}

func _init(cfg: Dictionary) -> void:
	duration_s = float(cfg.get("duration_s", duration_s))
	elapsed_s = float(cfg.get("elapsed_s", elapsed_s))
	log_dt = float(cfg.get("log_dt", log_dt))
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
		if e.has("hp"):
			var hc = ship.health_controller
			hc._current_hp = minf(float(e.hp), hc.max_hp) / hc.params.p().mult
		if ship.artillery_controller != null:
			var guns: Array = ship.artillery_controller.guns
			for i in guns.size():
				guns[i].reload = float(e.reload[i]) if e.has("reload") and i < (e.reload as Array).size() else 1.0
		if is_instance_valid(ship.torpedo_controller):
			for l in ship.torpedo_controller.launchers:
				l.reload = 1.0
		if e.has("bloom_m"):
			_bloom[ship] = float(e.bloom_m)
	SkillStance.duel_trace = trace
	server.match_elapsed = elapsed_s
	_started = SimClock.now()
	print("SCN start: %d ships, %.0f s from match time %.0f s" % [server.players.size(), duration_s, elapsed_s])

## True once the scenario has run its duration.
func tick(server: GameServer) -> bool:
	if _started < 0.0:
		return false
	var t: float = SimClock.now() - _started
	for ship in _bloom:
		if is_instance_valid(ship) and ship.concealment != null:
			ship.concealment.bloom(_bloom[ship])
	if t >= _next_log:
		_next_log = t + log_dt
		for p_name in server.players:
			var ship: Ship = server.players[p_name][0]
			if trace.has(ship.ship_name) and is_instance_valid(ship):
				_log(ship, t)
	return t >= duration_s

func _log(ship: Ship, t: float) -> void:
	var fwd := -ship.global_transform.basis.z
	var line := "SCN t=%5.1f %s hp=%.0f at=(%.0f,%.0f) hdg=%.0f spd=%.1f" % [t, ship.ship_name, ship.health_controller.current_hp,
		ship.global_position.x, ship.global_position.z, rad_to_deg(atan2(fwd.x, fwd.z)), ship.linear_velocity.length()]
	var bc := ship.get_node_or_null("Modules/BotController")
	if bc != null and bc.behavior != null:
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
		line += " | " + b._skill_stance.debug_text()
	print(line)
