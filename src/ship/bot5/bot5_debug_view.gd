class_name Bot5DebugView
## Overlay for the followed v5 bot, drawn from BotWorld.debug_bot / debug_team.

const LIFT := Vector3(0.0, 30.0, 0.0)
const C_ENGAGE := Color(0.3, 1.0, 0.3)
const C_RETREAT := Color(1.0, 0.3, 1.0)
const C_BAND := Color(1.0, 0.85, 0.2, 0.6)
const C_PATH := Color(1.0, 0.2, 0.9)
const C_TRACK := Color(0.3, 0.9, 1.0)
const C_CLEAR := {"ok": Color(0.9, 0.9, 0.9), "terrain": Color(1.0, 0.15, 0.1), "friendly": Color(1.0, 0.55, 0.0), "none": Color(0.5, 0.5, 0.5)}
const C_TRUE := Color(1.0, 0.3, 0.3)
const C_BELIEF := Color(0.3, 0.7, 1.0)
const C_VIEW := Color(0.7, 0.3, 1.0)
const C_FOCUS := Color(1.0, 1.0, 1.0, 0.35)
const C_TORP_RUN := Color(0.2, 0.8, 1.0)
const C_TORP := Color(0.2, 1.0, 0.8)
const C_TORP_HELD := Color(0.2, 1.0, 0.8, 0.3)
const C_SPOT := Color(1.0, 1.0, 0.4)
const C_PRESUMED := Color(1.0, 0.6, 0.6, 0.5)
const C_FLANK := [Color(1.0, 0.5, 0.2), Color(0.4, 1.0, 0.4), Color(0.4, 0.6, 1.0)]
const C_SEAM := Color(1.0, 1.0, 1.0)


static func draw(b: Dictionary, team: Dictionary, now: float) -> void:
	if not b.has("pos"):
		return
	var me: Vector3 = b.pos
	_draw_plan(b, me)
	_draw_nav(b, me)
	_draw_guns(b, me)
	_draw_torps(b)
	_draw_spot(b, me)
	_draw_team(team, b)
	Debug.draw_label(me + Vector3(0.0, 140.0, 0.0), _summary(b, now), Color(0.9, 1.0, 0.9), 14)


static func _draw_plan(b: Dictionary, me: Vector3) -> void:
	if not b.has("station"):
		return
	var col: Color = {"disengage": C_RETREAT, "torp_run": C_TORP_RUN}.get(b.get("posture", ""), C_ENGAGE)
	var st: Vector3 = b.station
	Debug.draw_line(me + LIFT, st + LIFT, col)
	Debug.draw_im_sphere(st + LIFT, 20.0, col)
	Debug.draw_circle(st + Vector3(0.0, 8.0, 0.0), float(b.get("hold_radius", 0.0)), Color(col, 0.6), 32)
	for w: Vector3 in b.get("walls", PackedVector3Array()):
		Debug.draw_circle(Vector3(w.x, 7.0, w.z), w.y, Color(1.0, 0.4, 0.1, 0.5), 48)
	var anchor: Vector3 = b.anchor
	Debug.draw_im_sphere(anchor + LIFT, 25.0, C_BAND)
	if b.has("band_lo"):
		Debug.draw_circle(anchor + Vector3(0.0, 6.0, 0.0), b.band_lo, C_BAND, 96)
		Debug.draw_circle(anchor + Vector3(0.0, 6.0, 0.0), b.band_hi, C_BAND, 96)


static func _draw_nav(b: Dictionary, me: Vector3) -> void:
	var path: PackedVector3Array = b.get("path", PackedVector3Array())
	if not path.is_empty():
		path.insert(0, me)
	Debug.draw_path(_lift(path, 12.0), C_PATH, 1, 10.0)
	var track: PackedVector3Array = b.get("trajectory", PackedVector3Array())
	Debug.draw_path(_lift(track, 4.0), C_TRACK)


static func _draw_guns(b: Dictionary, me: Vector3) -> void:
	if not b.has("aim"):
		return
	var aim: Vector3 = b.aim
	var col: Color = C_CLEAR.get(b.get("clear", "none"), Color.GRAY)
	Debug.draw_line(me + LIFT, aim, col)
	Debug.draw_im_sphere(aim, 12.0, col)
	var t = instance_from_id(int(b.get("target", 0))) if int(b.get("target", 0)) != 0 else null
	if b.has("impact_pos") and t is Node3D:
		var ip: Vector3 = b.impact_pos
		Debug.draw_line((t as Node3D).global_position + LIFT, ip + LIFT, C_BAND)
		Debug.draw_im_sphere(ip + LIFT, 15.0, C_BAND)
	if b.has("blocked_by"):
		var a = instance_from_id(int(b.blocked_by))
		if a is Node3D:
			var p: Vector3 = (a as Node3D).global_position
			Debug.draw_circle(p + Vector3(0.0, 10.0, 0.0), 150.0, C_CLEAR.friendly, 32)
			Debug.draw_label(p + Vector3(0.0, 90.0, 0.0), "in line of fire", C_CLEAR.friendly, 14)


static func _draw_torps(b: Dictionary) -> void:
	if not b.has("torp_points"):
		return
	var from: Vector3 = b.torp_from + Vector3(0.0, 6.0, 0.0)
	var pts: PackedVector3Array = b.torp_points
	var col := C_TORP if b.get("torp_gate", "") == "torp_fire" else C_TORP_HELD
	for k in pts.size():
		var c := col if k == int(b.torp_next) else Color(col, col.a * 0.5)
		Debug.draw_line(from, pts[k] + Vector3(0.0, 6.0, 0.0), c)
	Debug.draw_im_sphere(b.torp_intercept + Vector3(0.0, 10.0, 0.0), 30.0, col)


static func _draw_spot(b: Dictionary, me: Vector3) -> void:
	if not b.has("spot_reach"):
		return
	Debug.draw_circle(me + Vector3(0.0, 4.0, 0.0), b.spot_reach, Color(C_SPOT, 0.25), 64)
	if b.has("spot_point"):
		var p: Vector3 = b.spot_point + Vector3(0.0, 60.0, 0.0)
		Debug.draw_line(me + LIFT, p, C_SPOT)
		Debug.draw_circle(p, 2000.0, Color(C_SPOT, 0.5 if b.get("spot_up", false) else 0.2), 48)


static func _draw_team(team: Dictionary, b: Dictionary) -> void:
	for c: Dictionary in team.get("contacts", []):
		var bel: Vector3 = c.belief
		if c.has("pos") and not c.seen:
			var p: Vector3 = c.pos
			Debug.draw_line(p + LIFT, bel + LIFT, Color(C_TRUE, 0.5))
			Debug.draw_im_sphere(p + LIFT, 10.0, C_TRUE)
		Debug.draw_im_sphere(bel + LIFT, 14.0, C_BELIEF)
		if not c.seen:
			Debug.draw_label(bel + Vector3(0.0, 70.0, 0.0), "%ds ago" % int(c.age), C_BELIEF, 12)
		if c.has("view") and (c.view as Vector3).distance_to(bel) > 25.0:
			var v: Vector3 = c.view
			Debug.draw_line(bel + LIFT, v + LIFT, C_VIEW)
			Debug.draw_im_sphere(v + LIFT, 14.0, C_VIEW)
	for e: Dictionary in team.get("targets", []):
		var t = instance_from_id(int(e.target))
		if t is Node3D:
			var col := C_FOCUS if int(e.ship) != int(b.get("ship_id", 0)) else Color(C_FOCUS, 0.9)
			Debug.draw_line((e.pos as Vector3) + LIFT * 2.0, (t as Node3D).global_position + LIFT * 2.0, col)
	if team.has("enemy_spawn"):
		Debug.draw_circle((team.enemy_spawn as Vector3) + Vector3(0.0, 5.0, 0.0), 400.0, Color(C_TRUE, 0.4), 32)
	for p: Vector3 in team.get("presumed", PackedVector3Array()):
		Debug.draw_circle(p + Vector3(0.0, 5.0, 0.0), 600.0, C_PRESUMED, 24)
	var flanks: Array = team.get("flanks", [])
	for g in flanks.size():
		var f: Dictionary = flanks[g]
		var c: Vector3 = f.centre
		var col: Color = C_FLANK[g % C_FLANK.size()] if f.live else Color(0.5, 0.5, 0.5)
		Debug.draw_circle(c + Vector3(0.0, 8.0, 0.0), 1500.0, col, 48)
		Debug.draw_label(c + Vector3(0.0, 200.0, 0.0), "flank %d  enemy %.1f own %.1f  p %.2f" % [g, f.enemy, f.own, f.pressure], col, 16)
	for r: Dictionary in team.get("roles", []):
		var fi := int(r.flank)
		var col: Color = C_SEAM if fi < 0 else C_FLANK[fi % C_FLANK.size()]
		Debug.draw_circle((r.pos as Vector3) + Vector3(0.0, 6.0, 0.0), 300.0, col, 24)


static func _summary(b: Dictionary, now: float) -> String:
	var apt: String = BotAptitude.Level.keys()[clampi(int(b.aptitude), 0, BotAptitude.Level.size() - 1)]
	var lines := ["v5 %s%s %s  hp %d%%  %s" % [b.playstyle, " PUSH" if b.get("brawl", false) else "", apt.to_lower(), roundi(100.0 * float(b.get("hp", 0.0))), b.get("role", "")]]
	if b.has("spot_for"):
		var sf = instance_from_id(int(b.spot_for))
		lines.append("flank spotter: %s" % [(sf as Ship).ship_name if sf is Ship else "?"])
	lines.append("band %.1f-%.1f km" % [float(b.get("band_lo", 0.0)) / 1000.0, float(b.get("band_hi", 0.0)) / 1000.0])
	var tgt := "no target"
	var tid := int(b.get("target", 0))
	if tid != 0:
		var t = instance_from_id(tid)
		tgt = "%s %.1f km" % [(t as Ship).ship_name if t is Ship else "?", float(b.get("target_dist", 0.0)) / 1000.0]
	lines.append("%s%s | %s" % [b.get("posture", "-"), "" if b.get("station_shot", true) else " (no shot)", tgt])
	if b.has("aim"):
		lines.append("%s ev %.0f | %s" % [["AP", "HE"][int(b.ammo)], float(b.ev), b.get("gate", "")])
	else:
		lines.append(b.get("gate", ""))
	if b.has("release"):
		lines.append("replan: %s %ds ago" % [b.release, int(now - float(b.release_at))])
	if b.has("torp_gate"):
		lines.append("torp %s %d%%" % [b.torp_gate, roundi(100.0 * float(b.get("torp_chance", 0.0)))])
	if b.has("spot_reach"):
		lines.append("spotter %s%s" % ["up" if b.get("spot_up", false) else "deck", " tasked" if b.has("spot_point") else ""])
	if float(b.get("blocked_s", 0.0)) > 0.1:
		lines.append("blocked %.1fs" % float(b.blocked_s))
	return "\n".join(lines)


static func _lift(pts: PackedVector3Array, y: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = Vector3(pts[i].x, y, pts[i].z)
	return out
