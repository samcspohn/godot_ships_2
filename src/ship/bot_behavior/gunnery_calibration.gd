class_name GunneryCalibration

## Main-battery damage the baked model (DamageModel.get_expected, what SkillStance prices) expected
## against what landed, by shooter hull, target class and range band, for match metrics.
## Expected is booked when a gun fires, on the enemy nearest its aim point; landed when Stats records a hit.

const RANGE_BAND_M := 5000.0
const AIM_MATCH_M := 1500.0

## "shooter|target class|band" -> {salvos, shells, pred, pred_cit, real, real_cit, hits}
static var rows: Dictionary = {}


static func _row(shooter: Ship, target: Ship, range_m: float) -> Dictionary:
	var key := "%s|%s|%d" % [shooter.ship_name, Ship.ShipClass.keys()[target.ship_class], int(range_m / RANGE_BAND_M)]
	return rows.get_or_add(key, {"salvos": 0, "shells": 0, "pred": 0.0, "pred_cit": 0.0, "real": 0.0, "real_cit": 0.0, "hits": 0})


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


static func on_hit(shooter: Ship, target: Ship, hit_type: int, damage: float) -> void:
	if not is_instance_valid(shooter) or not is_instance_valid(target) or damage <= 0.0:
		return
	var r := _row(shooter, target, shooter.global_position.distance_to(target.global_position))
	r.real += damage
	r.hits += 1
	if hit_type == 5 or hit_type == 6:
		r.real_cit += damage


static func summary() -> Dictionary:
	return rows
