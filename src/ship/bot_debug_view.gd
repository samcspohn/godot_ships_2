class_name BotDebugView
## The bot overlay, drawn from BotControllerV4.debug_state() and team_state(); live and replay share it.

## Enemy labels anchor where the HP tag does (CameraUIScene, 20 m up) and sit this many pixels above it.
const ENEMY_LABEL_Y: float = 20.0
const ENEMY_LABEL_UP_PX: float = 50.0
const STALE_MAX: float = 120.0
const NO_ID := 255
const RING_COLORS := [Color(0.2, 1.0, 0.3, 0.7), Color(1.0, 0.25, 0.2, 0.7), Color(1.0, 0.85, 0.2, 0.7)]
enum Station { NONE, COVER, FIGHT, SPOT, OTHER }


## Where draw() reads what the state leaves out: ship poses and projectiles.
class World:
	func own_pos() -> Vector3: return Vector3.ZERO
	func own_heading() -> float: return 0.0
	## Vector3.INF when the ship is unknown or gone.
	func ship_pos(_id: int) -> Vector3: return Vector3.INF
	func trajectory() -> PackedVector3Array: return PackedVector3Array()
	func shell_threats() -> Array: return []
	func torpedo_threats() -> Array: return []


## What a team knows of its enemies; spotted ones (src 0) carry no position, their ship has it.
static func team_state(server: GameServer, team_id: int, ids: Dictionary) -> Dictionary:
	var beliefs := []
	for b in server._team_belief(team_id):
		var src := int(b.source)
		beliefs.append({"id": ids.get(b.ship, NO_ID), "src": src, "pos": Vector2.INF if src == 0 else b.pos,
			"spread": float(b.spread), "force": float(b.force_spot)})
	var lkps := []
	var now: float = SimClock.now()
	var unspotted: Dictionary = server.get_unspotted_enemies(team_id)
	var times: Dictionary = server.get_unspotted_enemy_times(team_id)
	for e in unspotted:
		if is_instance_valid(e):
			var p: Vector3 = unspotted[e]
			lkps.append({"id": ids.get(e, NO_ID), "pos": Vector2(p.x, p.z), "seen": float(times.get(e, now))})
	return {"now": now, "beliefs": beliefs, "lkps": lkps}


static func _belief_pos(b: Dictionary, w: World) -> Vector2:
	if b.pos.is_finite():
		return b.pos
	var p := w.ship_pos(b.id)
	return Vector2(p.x, p.z) if p.is_finite() else Vector2.INF


static func draw(s: Dictionary, team: Dictionary, w: World) -> void:
	var ship_pos := w.own_pos()
	draw_shell_threats(w.shell_threats())
	draw_state(s, ship_pos, w.own_heading())

	var lift := Vector3(0.0, 30.0, 0.0)
	if s.dis_on:
		var dest: Vector2 = s.dest_pos
		Debug.draw_line(ship_pos + lift, Vector3(dest.x, 0.0, dest.y) + lift, Color.GREEN)
		if is_finite(s.dis_axis):
			for end in [0.0, PI]:
				for side in [-1.0, 1.0]:
					var b: float = s.dis_axis + end + side * SkillDisengage.CONE
					var reach: float = SkillCover.REACH_M if end == 0.0 else SkillCover.REACH_M / SkillCover.AWAY_RATIO
					Debug.draw_line(ship_pos + lift, ship_pos + lift + Vector3(sin(b), 0.0, cos(b)) * reach,
						Color(0.0, 1.0, 0.0, 0.5))

	var tgt := w.ship_pos(s.tgt)
	if tgt.is_finite():
		Debug.draw_cone(Vector3(tgt.x, tgt.y + 150.0, tgt.z), Vector3(PI, 0.0, 0.0), 60.0, 0.0, 30.0, Color.RED, 4)
	var d: Vector2 = s.dest_pos if s.dest_pos.is_finite() else Vector2.ZERO
	Debug.draw_cone(Vector3(d.x, 120.0, d.y), Vector3(PI, 0.0, 0.0), 80.0, 0.0, 40.0, Color(0.0, 1.0, 0.4, 0.9), 4)

	if s.nav >= 0:
		var path: PackedVector2Array = s.path
		if path.size() > 0:
			var full_path := PackedVector3Array([Vector3(ship_pos.x, 50.0, ship_pos.z)])
			for pt in path:
				full_path.append(Vector3(pt.x, 50.0, pt.y))
			Debug.draw_path(full_path, Color(1.0, 0.6, 1.0, 0.7), 1, 20.0)
		var traj := w.trajectory()
		if traj.size() >= 2:
			var raised := PackedVector3Array()
			for pt in traj:
				raised.append(Vector3(pt.x, 40.0, pt.z))
			Debug.draw_path(raised, Color(0.0, 0.9, 0.9, 0.8), maxi(raised.size() / 30, 1), 12.0)
		draw_trajectory(traj)
		if s.clear > 0.0:
			Debug.draw_sdf_tiles(ship_pos, s.clear, 1000.0, 3.0)
		draw_torpedo_threats(w.torpedo_threats())

	if s.dis_text != "":
		Debug.draw_label(ship_pos + Vector3(0.0, 120.0, 0.0), s.dis_text, Color(1.0, 0.8, 1.0), 14)
	Debug.draw_label(ship_pos + Vector3(0.0, 160.0, 0.0), s.stance_text, Color(1.0, 1.0, 0.6), 14)
	for trail in s.trails:
		var pts: PackedVector2Array = trail.pts
		var n: PackedInt32Array = trail.n
		for i in pts.size():
			if i > 0:
				Debug.draw_line(Vector3(pts[i - 1].x, 10.0, pts[i - 1].y), Vector3(pts[i].x, 10.0, pts[i].y), Color(0.4, 0.8, 1.0, 0.6))
			if i < n.size() and n[i] > 0:
				Debug.draw_label(Vector3(pts[i].x, 40.0, pts[i].y), str(n[i]), Color(0.6, 0.9, 1.0), 14)
	if s.st_kind != Station.NONE and s.st_pos.is_finite():
		var st: Vector2 = s.st_pos
		var st_col: Color = [Color(0.2, 1.0, 0.9), Color(0.3, 1.0, 0.3), Color(1.0, 0.5, 0.1), Color(0.4, 0.8, 1.0), Color(0.2, 1.0, 0.9)][s.st_kind]
		Debug.draw_circle(Vector3(st.x, 8.0, st.y), 150.0, Color(st_col, 0.8), 32)
		Debug.draw_im_sphere(Vector3(st.x, 30.0, st.y), 20.0, st_col)
		Debug.draw_label(Vector3(st.x, 90.0, st.y), s.st_text, Color(0.85, 1.0, 0.9), 14)

	if not team.is_empty():
		_draw_enemies(s, team, w)

	if s.danger.is_finite():
		var dc := Vector3(s.danger.x, 10.0, s.danger.y)
		Debug.draw_circle(dc, 300.0, Color.RED, 32)
		Debug.draw_label(dc + Vector3(0.0, 150.0, 0.0), "Danger [spotted]", Color.RED)


static func _draw_enemies(s: Dictionary, team: Dictionary, w: World) -> void:
	var at := {}
	for b in team.beliefs:
		at[b.id] = _belief_pos(b, w)
		if b.src == 0:
			var p := w.ship_pos(b.id)
			if p.is_finite():
				var epos := Vector3(p.x, 20.0, p.z)
				Debug.draw_im_sphere(epos, 30.0, Color(1.0, 0.1, 0.1, 0.9))
				Debug.draw_circle(epos, 350.0, Color(1.0, 0.2, 0.2, 0.5), 16)

	# Fight's ring round each enemy that shoots: green we push in, yellow we hold at our best trade, red we keep out of its fire.
	var rank := {}
	for k in s.prio.size():
		if s.prio[k].id != NO_ID:
			rank[s.prio[k].id] = k
	var ringed := {}
	for r in s.rings:
		var c: Vector2 = at.get(r.id, Vector2.INF)
		if not c.is_finite():
			continue
		ringed[r.id] = true
		var col: Color = RING_COLORS[r.cls]
		Debug.draw_circle(Vector3(c.x, 12.0, c.y), r.r, col, 64)
		var text := "%.1fk x%.2f" % [r.r / 1000.0, r.trade]
		if rank.has(r.id):
			text = "P%d %.2f\n%s" % [rank[r.id] + 1, s.prio[rank[r.id]].score, text]
		Debug.draw_label(Vector3(c.x, ENEMY_LABEL_Y, c.y), text, Color(col, 1.0),
			12 if rank.get(r.id, 99) < BotBehavior.PRIORITY_COUNT else 9, ENEMY_LABEL_UP_PX)

	# How far each enemy spots us now, unbloomed: our concealment, or its radar/hydro while that reaches further.
	if s.conceal >= 0.0:
		for b in team.beliefs:
			var c: Vector2 = at[b.id]
			if c.is_finite():
				Debug.draw_circle(Vector3(c.x, 14.0, c.y), maxf(s.conceal, b.force), Color(0.3, 0.7, 1.0, 0.6), 64)

	for i in s.prio.size():
		var c: Dictionary = s.prio[i]
		if ringed.has(c.id):
			continue
		var p: Vector2 = c.pos if c.id == NO_ID else at.get(c.id, Vector2.INF)
		if not p.is_finite():
			var sp := w.ship_pos(c.id)
			p = Vector2(sp.x, sp.z) if sp.is_finite() else Vector2.INF
		if not p.is_finite():
			continue
		var top: bool = i < BotBehavior.PRIORITY_COUNT
		Debug.draw_label(Vector3(p.x, ENEMY_LABEL_Y, p.y), "P%d%s %.2f" % [i + 1, "" if c.id != NO_ID else "?", c.score],
			Color(1.0, 0.95, 0.3) if top else Color(0.7, 0.7, 0.7, 0.7), 13 if top else 9, ENEMY_LABEL_UP_PX)

	for l in team.lkps:
		var staleness: float = clampf((team.now - l.seen) / STALE_MAX, 0.0, 1.0)
		var alpha: float = lerpf(0.7, 0.15, staleness)
		var lkp_pos := Vector3(l.pos.x, 20.0, l.pos.y)
		Debug.draw_im_sphere(lkp_pos, 20.0, Color(1.0, 0.85, 0.0, alpha))
		Debug.draw_circle(lkp_pos, 350.0, Color(1.0, 0.85, 0.0, alpha * 0.5), 16)

	if NavigationMapManager.is_map_ready():
		var my_pos := w.own_pos()
		for isl in NavigationMapManager.get_islands():
			var center_2d: Vector2 = isl["center"]
			var isl_pos := Vector3(center_2d.x, 0.0, center_2d.y)
			var isl_radius: float = isl["radius"]
			if isl_pos.distance_to(my_pos) - isl_radius <= 10000.0:
				Debug.draw_circle(Vector3(isl_pos.x, 9.0, isl_pos.z), isl_radius, Color(0.0, 0.8, 0.9, 0.35), 48)
				Debug.draw_im_sphere(Vector3(isl_pos.x, 28.0, isl_pos.z), 15.0, Color(0.0, 0.9, 1.0, 0.6))


const POLICY_NAMES := ["STEALTH", "CONCEAL", "NO_DARK", "HOLD_GUNS", "HOLD_FIRE", "CORNERED"]

static func _state_label(s: Dictionary) -> String:
	var lines: PackedStringArray = PackedStringArray()
	if s.apt_name != "":
		lines.append("[%s] %sagg %+.2f" % [s.apt_name, s.apt + " · " if s.apt != "" else "", s.agg])
	var state_names = ["NORMAL", "EMERGENCY"]
	lines.append("Nav: %s" % state_names[s.nav] if s.nav >= 0 and s.nav < state_names.size() else "Nav: UNKNOWN(%d)" % s.nav)
	if s.skill != "":
		var threat_bar := ""
		if s.threat >= 0.0:
			var filled := int(round(s.threat * 10.0))
			threat_bar = " [" + "█".repeat(filled) + "░".repeat(clamp(10 - filled, 0, 10)) + "] %.2f" % s.threat
		lines.append("Skill: %s%s" % [s.skill, threat_bar])
	if s.tgt_d >= 0.0:
		var dist_m := int(s.tgt_d)
		var dist_str := "%.1fk" % (dist_m / 1000.0) if dist_m >= 1000 else "%dm" % dist_m
		lines.append("→ %s %s  ·  %s" % [s.tgt_cls, s.tgt_name, dist_str])
	if s.p_d >= 0.0:
		lines.append("P: %s  ·  %.1fk%s" % [s.p_name, int(s.p_d) / 1000.0, " (dark)" if s.p_dark else ""])
	var flags: PackedStringArray = PackedStringArray()
	if s.hp >= 0:
		flags.append("HP:%d%%" % s.hp)
	flags.append("VISIBLE" if s.visible else "HIDDEN")
	if s.cover:
		flags.append("COVER")
	lines.append(" · ".join(flags))
	var policy: PackedStringArray = PackedStringArray()
	for i in POLICY_NAMES.size():
		if s.policy & (1 << i):
			policy.append(POLICY_NAMES[i])
	lines.append(" · ".join(policy) if not policy.is_empty() else "guns free · no stealth")
	if s.torp >= 0.0:
		var filled := int(round(s.torp * 10.0))
		lines.append("Torps: [%s] %d%%" % ["█".repeat(filled) + "░".repeat(10 - filled), int(s.torp * 100.0)])
	lines.append("Dmg: %d  Pot: %d" % [s.dmg, s.pot])
	return "\n".join(lines)


## The ship-anchored overlay, from debug_state() and a pose (live ship or replay ghost).
static func draw_state(s: Dictionary, ship_pos: Vector3, heading: float) -> void:
	var fwd := Vector3(sin(heading), 0.0, cos(heading))
	var dir := func(a: float) -> Vector3: return Vector3(sin(a), 0.0, cos(a))

	# Desired heading (GREEN); stance's held heading (ORANGE, length = throttle); away from the fire (RED).
	Debug.draw_arrow(ship_pos + Vector3(0.0, 100.0, 0.0), dir.call(s.dest), 200.0, Color.GREEN, 10.0)
	if is_finite(s.stance):
		Debug.draw_arrow(ship_pos + Vector3(0.0, 150.0, 0.0), dir.call(s.stance), 200.0 * s.stance_t, Color(1.0, 0.6, 0.0), 10.0)
	if is_finite(s.away):
		Debug.draw_arrow(ship_pos + Vector3(0.0, 170.0, 0.0), dir.call(s.away), 400.0, Color.RED, 12.0)

	# Heading + rudder (CYAN); collision threat (ORANGE) and away from it (TEAL).
	if is_finite(s.rudder):
		Debug.draw_arrow(ship_pos + Vector3(0.0, 80.0, 0.0), dir.call(s.rudder), 180.0, Color.CYAN, 8.0)
	if is_finite(s.threat_dir):
		Debug.draw_arrow(ship_pos + Vector3(0.0, 60.0, 0.0), dir.call(s.threat_dir), 200.0 * s.threat_w, Color(1.0, 0.3, 0.0), 8.0)
		Debug.draw_arrow(ship_pos + Vector3(0.0, 60.0, 0.0), -dir.call(s.threat_dir), 200.0 * s.threat_w, Color(0.0, 1.0, 0.5), 8.0)

	# Throttle
	var throttle_pos := ship_pos + Vector3(0.0, 120.0, 0.0)
	if s.throttle == 0:
		Debug.draw_im_sphere(throttle_pos, 15.0, Color.RED)
	elif s.throttle == -1:
		Debug.draw_arrow(throttle_pos, -fwd, 100.0, Color.YELLOW, 9.0)
	elif s.throttle == 4:
		Debug.draw_arrow(throttle_pos, fwd, 200.0, Color(0.0, 0.4, 1.0), 9.0)
	else:
		Debug.draw_arrow(throttle_pos, fwd, 200.0 * (float(s.throttle) / 4.0), Color(0.0, 1.0, 0.3), 9.0)

	# The OBB the navigator scores shell hits against: hull edges, keel and beam lines.
	var hsl: float = s.length * 0.5
	var hsb: float = s.beam * 0.5
	var stbd := Vector3(cos(heading), 0.0, -sin(heading))
	var ctr := Vector3(ship_pos.x, 3.0, ship_pos.z)
	var col := Color(1.0, 1.0, 1.0, 0.85)
	var dim := Color(1.0, 1.0, 1.0, 0.35)
	var bs := ctr + fwd * hsl + stbd * hsb
	var bp := ctr + fwd * hsl - stbd * hsb
	var sp := ctr - fwd * hsl - stbd * hsb
	var ss := ctr - fwd * hsl + stbd * hsb
	Debug.draw_line(bs, bp, col)
	Debug.draw_line(bp, sp, col)
	Debug.draw_line(sp, ss, col)
	Debug.draw_line(ss, bs, col)
	Debug.draw_line(ctr + fwd * hsl, ctr - fwd * hsl, dim)
	Debug.draw_line(ctr + stbd * hsb, ctr - stbd * hsb, dim)

	if s.clear > 0.0:
		Debug.draw_circle(Vector3(ship_pos.x, 5.0, ship_pos.z), s.clear, Color(0.2, 0.8, 1.0, 0.7), 64)
	if s.soft_clear > 0.0:
		Debug.draw_circle(Vector3(ship_pos.x, 4.0, ship_pos.z), s.soft_clear, Color(1.0, 0.8, 0.0, 0.5), 64)

	Debug.draw_label(ship_pos + Vector3(-100, 100, 0), _state_label(s))


## Navigator winning arc; replays rebuild it with ShipNavigator.simulate_debug_arc.
static func draw_trajectory(trajectory: PackedVector3Array) -> void:
	for i in range(trajectory.size()):
		var t = float(i) / float(max(trajectory.size() - 1, 1))
		Debug.draw_im_sphere(trajectory[i], 15.0, Color(0.0, 1.0 - t * 0.5, 0.0))


## Navigator torpedo threat points; replays rebuild them from TorpedoReplayer.
static func draw_torpedo_threats(threat_lines: Array) -> void:
	for t_pt in threat_lines:
		var landing_x: float = t_pt.get("landing_x", 0.0)
		var landing_z: float = t_pt.get("landing_z", 0.0)
		var time_remaining: float = t_pt.get("time_remaining", 0.0)
		var caliber: float = t_pt.get("caliber", 0.0)
		var urgency: float = clampf(1.0 - (time_remaining / 10.0), 0.0, 1.0)

		var has_line: bool = t_pt.has("line_start_x")
		if has_line:
			var sx: float = t_pt.get("line_start_x", 0.0)
			var sz: float = t_pt.get("line_start_z", 0.0)
			var ex: float = t_pt.get("line_end_x", 0.0)
			var ez: float = t_pt.get("line_end_z", 0.0)
			var is_torp: bool = caliber >= 500.0
			var line_color: Color
			if is_torp:
				line_color = Color(0.0, lerpf(0.5, 1.0, urgency), 1.0, lerpf(0.4, 0.9, urgency))
			else:
				line_color = Color(1.0, lerpf(0.9, 0.0, urgency), 0.0, lerpf(0.4, 0.9, urgency))
			var draw_y: float = 5.0
			Debug.draw_line(Vector3(sx, draw_y, sz), Vector3(ex, draw_y, ez), line_color)
			# Small sphere at the center for reference
			Debug.draw_im_sphere(Vector3(landing_x, 15.0, landing_z), 4.0, line_color)
		else:
			var color = Color(0.0, lerpf(0.5, 1.0, urgency), 1.0, lerpf(0.3, 0.8, urgency))
			Debug.draw_circle(Vector3(landing_x, 5.0, landing_z), 60.0, color)
			Debug.draw_im_sphere(Vector3(landing_x, 15.0, landing_z), 6.0, color)


## ProjectileManager.get_shells_near_position entries; replays rebuild them from ShellReplayer.
static func draw_shell_threats(shells: Array) -> void:
	for s in shells:
		var landing_x: float = s.get("landing_x", 0.0)
		var landing_z: float = s.get("landing_z", 0.0)
		var time_remaining: float = s.get("time_remaining", 0.0)
		var caliber: float = s.get("caliber", 0.0)
		var urgency: float = clampf(1.0 - (time_remaining / 10.0), 0.0, 1.0)
		var color = Color(1.0, lerpf(0.9, 0.0, urgency), 0.0, lerpf(0.4, 0.9, urgency))
		# Draw the threat line using landing velocity direction and threat_half_len
		var vx: float = s.get("landing_vx", 0.0)
		var vz: float = s.get("landing_vz", 0.0)
		var spd: float = sqrt(vx * vx + vz * vz)
		var half_len: float = s.get("threat_half_len", 15.0)
		if spd > 1e-6 and half_len > 1.0:
			var dir_x: float = vx / spd
			var dir_z: float = vz / spd
			# Line trails backward from landing point and extends 15m past it
			var overshoot: float = 15.0
			var sx: float = landing_x - dir_x * half_len * 2.0
			var sz: float = landing_z - dir_z * half_len * 2.0
			var ex: float = landing_x + dir_x * overshoot
			var ez: float = landing_z + dir_z * overshoot
			var draw_y: float = 5.0
			Debug.draw_line(Vector3(sx, draw_y, sz), Vector3(ex, draw_y, ez), color)
			Debug.draw_im_sphere(Vector3(landing_x, 15.0, landing_z), 5.0, color)
		else:
			# Fallback: draw as a circle if no velocity data
			var radius: float = clampf(caliber * 0.2, 30.0, 120.0)
			Debug.draw_circle(Vector3(landing_x, 5.0, landing_z), radius, color)
			Debug.draw_im_sphere(Vector3(landing_x, 15.0, landing_z), 8.0, color)
