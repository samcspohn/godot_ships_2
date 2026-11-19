class_name TorpStats

## Side-neutral per-salvo torpedo records. The target is inferred the same way for both bots: the enemy the
## centre torpedo would pass closest to if everyone held course.

static var salvos: Array[Dictionary] = []


static func clear() -> void:
	salvos.clear()


static func _p2(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


static func _fwd(s: Ship) -> Vector2:
	var f := -s.global_transform.basis.z
	return Vector2(f.x, f.z).normalized()


static func open(shooter: Ship, launcher: TorpedoLauncher, n: int, speed: float, reach: float) -> int:
	var server: GameServer = shooter.get_node_or_null("/root/Server")
	if server == null:
		return -1
	var from := _p2(launcher.muzzles[0].global_position)
	var dir := Vector2.ZERO
	for m in launcher.muzzles:
		dir += _p2(-m.global_basis.z)
	dir = dir.normalized()
	var vt := dir * speed
	var best: Ship = null
	var best_miss := INF
	var best_t := 0.0
	for e in server.get_team_ships(1 - shooter.team.team_id):
		if not is_instance_valid(e) or not e.is_alive():
			continue
		var r0 := _p2(e.global_position) - from
		var vr := _p2(e.linear_velocity) - vt
		var t := clampf(-r0.dot(vr) / maxf(vr.length_squared(), 1e-3), 0.0, reach / maxf(speed, 1.0))
		var miss := (r0 + vr * t).length()
		if miss < best_miss:
			best_miss = miss
			best = e
			best_t = t
	var me := _p2(shooter.global_position)
	var rec := {
		"ship": shooter, "t": SimClock.now(), "n": n, "pending": n, "my_speed": _p2(shooter.linear_velocity).length(),
		"lit": shooter.visible_to_enemy, "hits": 0, "dmg": 0.0, "ground": 0, "expire": 0, "other": 0, "hit_other": 0,
		"detect_t": -1.0, "detect_d": -1.0, "pass_d": INF, "pass_turn": 0.0, "pass_t": -1.0,
	}
	if best != null:
		var to_me := me - _p2(best.global_position)
		var f := _fwd(best)
		rec.merge({
			"target": best, "class": int(best.ship_class), "range": to_me.length(), "miss": best_miss, "eta": best_t,
			"aspect": rad_to_deg(f.angle_to(to_me.normalized())), "t_speed": _p2(best.linear_velocity).length(),
			"t_turn": rad_to_deg(absf(best.angular_velocity.y)), "t_seen": best.visible_to_enemy, "t_fwd": f,
		})
	salvos.append(rec)
	return salvos.size() - 1


## Per physics tick per live torpedo: the salvo's closest pass on its target and how far the target had turned.
static func track(s: int, pos: Vector3, detected: bool) -> void:
	var r: Dictionary = salvos[s]
	if detected and r["detect_t"] < 0.0 and r.has("target") and is_instance_valid(r["target"]):
		r["detect_t"] = SimClock.now() - r["t"]
		r["detect_d"] = _p2(pos).distance_to(_p2(r["target"].global_position))
	if not r.has("target") or not is_instance_valid(r["target"]) or not r["target"].is_alive():
		return
	var d := _p2(pos).distance_to(_p2(r["target"].global_position))
	if d < r["pass_d"]:
		r["pass_d"] = d
		r["pass_t"] = SimClock.now() - r["t"]
		r["pass_turn"] = rad_to_deg(absf((r["t_fwd"] as Vector2).angle_to(_fwd(r["target"]))))


## kind: hit, ground, expire, other (an ally, unarmed, or a dead hull).
static func close(s: int, kind: String, ship: Ship = null, dmg: float = 0.0) -> void:
	var r: Dictionary = salvos[s]
	r["pending"] -= 1
	if kind == "hit":
		if ship == r.get("target"):
			r["hits"] += 1
		else:
			r["hit_other"] += 1
		r["dmg"] += dmg
	else:
		r[kind] += 1


static func summary(apt_of: Callable) -> Array:
	var out := []
	for r in salvos:
		if not is_instance_valid(r["ship"]):
			continue
		var o := r.duplicate()
		o["apt"] = apt_of.call(r["ship"])
		o["shooter"] = r["ship"].ship_name
		o.erase("ship")
		o.erase("t_fwd")
		if r.has("target"):
			o["target"] = r["target"].ship_name if is_instance_valid(r["target"]) else ""
		if not is_finite(o["pass_d"]):
			o["pass_d"] = -1.0
		out.append(o)
	return out
