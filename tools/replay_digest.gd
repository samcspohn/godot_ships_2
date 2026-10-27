extends SceneTree

## Text digest of a replay: overview.txt, frames.txt, maps.txt.
## godot --headless --path . -s res://tools/replay_digest.gd -- --replay <file> [--out dir] [--focus 0]
##   [--from 0] [--to end] [--frame 10] [--map 30] [--zoom 0 (crop radius m around focus)] [--cols 110]

const BOUNDS := Rect2(-17500, -17500, 35000, 35000)
const HIT_NAMES := ["pen", "part", "rico", "over", "shat", "cit", "citov", "water", "terr"]
const CONS_TYPES := ["heal", "damage control", "radar boost", "repair party", "smoke", "hydro", "radar"]
const EV_SHELL_DAMAGE := 0x12
const EV_TORP_FIRED := 0x20
const EV_TORP_DESTROYED := 0x23
const EV_FIRE_STARTED := 0x30
const EV_FLOOD_STARTED := 0x32
const EV_FIRE_DAMAGE := 0x34
const EV_FLOOD_DAMAGE := 0x35
const EV_CONSUMABLE_USED := 0x40
const EV_DETECTION := 0x50
const EV_SUNK := 0x60

var r
var focus := 0
var focus_team := 0
var glyph := {}
var team := {}
var name_of := {}
var max_hp := {}
var torp_owner := {}
var nmm: Node


func _initialize() -> void:
	await process_frame
	var path: String = CmdArgs.value("--replay", "")
	if path == "":
		var dir := OS.get_user_data_dir() + "/replays"
		var newest := 0
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".replay") and FileAccess.get_modified_time(dir + "/" + f) > newest:
				newest = FileAccess.get_modified_time(dir + "/" + f)
				path = dir + "/" + f
	r = load("res://src/replay/replay_file_reader.gd").new()
	if r.load_file(path) != OK:
		quit(1)
		return
	var out: String = CmdArgs.value("--out", "res://build/replay_digest/" + path.get_file().get_basename())
	out = ProjectSettings.globalize_path(out)
	DirAccess.make_dir_recursive_absolute(out)

	var map = load("res://src/Maps/map.tscn" if r.header.map_id == 0 else "res://src/Maps/map2.tscn").instantiate()
	root.add_child(map)
	await physics_frame
	nmm = root.get_node("/root/NavigationMapManager")
	nmm.build_map(map.islands, BOUNDS)

	focus = int(CmdArgs.value("--focus", "0"))
	var first: Dictionary = r.read_snapshot_at(r.snapshot_index[0].timestamp)
	_roster(first)
	for e in r.all_events:
		if e.type == EV_TORP_FIRED:
			torp_owner[e.torpedo_id] = e.ship_id

	var t_end: float = r.snapshot_index[-1].timestamp
	var from := float(CmdArgs.value("--from", "0"))
	var to := minf(float(CmdArgs.value("--to", str(t_end))), t_end)
	var frame_dt := float(CmdArgs.value("--frame", "10"))
	var map_dt := float(CmdArgs.value("--map", "30"))
	var zoom := float(CmdArgs.value("--zoom", "0"))
	var cols := int(CmdArgs.value("--cols", "110"))

	_save(out + "/overview.txt", _overview(from, to, t_end))
	var frames := PackedStringArray()
	var t := snappedf(from, frame_dt)
	while t <= to:
		frames.append(_frame(t, frame_dt))
		t += frame_dt
	_save(out + "/frames.txt", "\n".join(frames))
	var maps := PackedStringArray()
	t = snappedf(from, map_dt)
	while t <= to:
		maps.append(_map(t, zoom, cols))
		t += map_dt
	_save(out + "/maps.txt", "\n".join(maps))
	print("digest written to ", out)
	quit()


func _save(p: String, s: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(s)


func _roster(first: Dictionary) -> void:
	for s in r.ships:
		if s.ship_id == focus:
			focus_team = s.team_id
	var ally := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	var enemy := "abcdefghijklmnopqrstuvwxyz"
	var ai := 0
	var ei := 0
	for s in r.ships:
		var id: int = s.ship_id
		team[id] = s.team_id
		name_of[id] = s.ship_name
		max_hp[id] = first[id].hp if first.has(id) else 1.0
		if id == focus:
			glyph[id] = "@"
		elif s.team_id == focus_team:
			glyph[id] = ally[ai]
			ai += 1
		else:
			glyph[id] = enemy[ei]
			ei += 1


func _g(id: int) -> String:
	return glyph.get(id, "?")


func _tag(id: int) -> String:
	return "%s(%s)" % [_g(id), name_of.get(id, "?")]


static func _mmss(t: float) -> String:
	return "%d:%02d" % [int(t) / 60, int(t) % 60]


func _overview(from: float, to: float, t_end: float) -> String:
	var L := PackedStringArray()
	L.append("replay v%d map %d  length %s  focus %s team %d" % [r.header.version, r.header.map_id, _mmss(t_end), _tag(focus), focus_team])
	L.append("glyphs: @ = focus, A.. = focus team, a.. = enemy; positions x right, z down (map north up); hdg 0 = -z")
	L.append("")
	L.append("roster")
	for s in r.ships:
		L.append("  %s  id %2d  team %d  %-15s %-10s maxhp %6.0f%s" % [_g(s.ship_id), s.ship_id, s.team_id, s.ship_name,
				s.player_name, max_hp[s.ship_id], "" if s.is_bot else "  HUMAN"])
	L.append("")

	var dealt := {}
	var recv := {}
	var hits := {}
	var total_by := {}
	for e in r.all_events:
		if e.type in [EV_SHELL_DAMAGE, EV_FIRE_DAMAGE, EV_FLOOD_DAMAGE]:
			total_by[e.attacker_ship_id] = total_by.get(e.attacker_ship_id, 0.0) + e.damage
		if e.timestamp < from or e.timestamp > to:
			continue
		var w := int(e.timestamp / 10.0)
		if e.type == EV_SHELL_DAMAGE:
			var kind: String = "sec" if e.is_secondary else HIT_NAMES[e.hit_type] if e.hit_type < HIT_NAMES.size() else str(e.hit_type)
			if e.attacker_ship_id == focus:
				_acc(dealt, w, e.victim_ship_id, e.damage)
				var h: Dictionary = hits.get_or_add(w, {})
				h[kind] = h.get(kind, 0) + 1
			if e.victim_ship_id == focus:
				_acc(recv, w, e.attacker_ship_id, e.damage)
		elif e.type in [EV_FIRE_DAMAGE, EV_FLOOD_DAMAGE]:
			if e.attacker_ship_id == focus:
				_acc(dealt, w, e.victim_ship_id, e.damage)
			if e.victim_ship_id == focus:
				_acc(recv, w, e.attacker_ship_id, e.damage)

	L.append("total damage (whole replay)")
	var ids := total_by.keys()
	ids.sort_custom(func(a, b): return total_by[a] > total_by[b])
	for id in ids:
		if id < 255:
			L.append("  %-18s %8.0f" % [_tag(id), total_by[id]])
	L.append("")

	L.append("timeline %s-%s  (focus damage per 10 s: dealt by victim [hit kinds] / received by attacker)" % [_mmss(from), _mmss(to)])
	var lines := []
	for e in r.read_events_in_range(from, to, true):
		var s := _event_line(e)
		if s != "":
			lines.append([e.timestamp, s])
	var windows := {}
	for w in dealt.keys() + recv.keys():
		windows[w] = true
	for w in windows:
		var s := "  dmg"
		if dealt.has(w):
			s += "  dealt %s %s" % [_fmt_acc(dealt[w]), hits.get(w, {})]
		if recv.has(w):
			s += "  recv %s" % _fmt_acc(recv[w])
		lines.append([w * 10.0 + 9.99, s])
	lines.sort_custom(func(a, b): return a[0] < b[0])
	for l in lines:
		L.append("%6s %s" % [_mmss(l[0]), l[1]])
	L.append("")

	L.append("team hp % / alive every 30 s")
	var t := snappedf(from, 30.0)
	while t <= to:
		var snap: Dictionary = r.read_snapshot_at(t)
		var hp := {}
		var cap := {}
		var alive := {}
		for id in snap:
			var tm: int = team[id]
			hp[tm] = hp.get(tm, 0.0) + maxf(snap[id].hp, 0.0)
			cap[tm] = cap.get(tm, 0.0) + max_hp[id]
			if snap[id].flags & 16 == 0 and snap[id].hp > 0.0:
				alive[tm] = alive.get(tm, 0) + 1
		var s := "%6s" % _mmss(t)
		for tm in [focus_team, 1 - focus_team]:
			s += "  %s %3.0f%% %2d alive" % ["us  " if tm == focus_team else "them", 100.0 * hp.get(tm, 0.0) / maxf(cap.get(tm, 1.0), 1.0), alive.get(tm, 0)]
		L.append(s)
		t += 30.0
	return "\n".join(L)


func _acc(d: Dictionary, w: int, id: int, dmg: float) -> void:
	var m: Dictionary = d.get_or_add(w, {})
	m[id] = m.get(id, 0.0) + dmg


func _fmt_acc(m: Dictionary) -> String:
	var parts := PackedStringArray()
	var total := 0.0
	for id in m:
		total += m[id]
		parts.append("%s %.0f" % [_g(id), m[id]])
	return "%.0f (%s)" % [total, ", ".join(parts)]


func _event_line(e: Dictionary) -> String:
	match e.type:
		EV_SUNK:
			return "SUNK %s by %s" % [_tag(e.victim_ship_id), _tag(e.sinker_ship_id)]
		EV_DETECTION:
			if e.ship_id == focus:
				return "focus %s" % ("SPOTTED" if e.visible_to_enemy else "hidden")
		EV_CONSUMABLE_USED:
			if e.ship_id == focus or _near_focus(e.ship_id, e.timestamp, 12000.0):
				return "%s uses %s" % [_tag(e.ship_id), _cons_label(e.ship_id, e.slot_id)]
		EV_TORP_DESTROYED:
			var by: int = torp_owner.get(e.torpedo_id, -1)
			if e.hit_ship_id < 255 and (e.hit_ship_id == focus or by == focus):
				return "torp hit %s by %s" % [_tag(e.hit_ship_id), _tag(by)]
		EV_TORP_FIRED:
			if e.ship_id == focus:
				return "focus fires torpedo"
		EV_FIRE_STARTED, EV_FLOOD_STARTED:
			if e.ship_id == focus or e.caused_by_ship_id == focus:
				return "%s on %s by %s" % ["fire" if e.type == EV_FIRE_STARTED else "flood", _tag(e.ship_id), _tag(e.caused_by_ship_id)]
	return ""


func _cons_label(id: int, slot: int) -> String:
	for s in r.ships:
		if s.ship_id == id:
			for c in s.consumables:
				if c.slot_id == slot:
					return c.label if c.label != "" else CONS_TYPES[c.type] if c.type < CONS_TYPES.size() else "type %d" % c.type
	return "slot %d" % slot


func _near_focus(id: int, t: float, d: float) -> bool:
	var snap: Dictionary = r.read_snapshot_at(t)
	return snap.has(id) and snap.has(focus) and snap[id].pos.distance_to(snap[focus].pos) <= d


static func _hdg(rot_y: float) -> float:
	return fposmod(rad_to_deg(rot_y) * -1.0, 360.0)


func _bot_line(id: int, t: float) -> String:
	var i: int = r.bot_debug_index(id, t)
	if i < 0:
		return ""
	var s: Dictionary = r.bot_debug_record(id, i)
	var tgt := "-" if s.get("tgt", 255) == 255 else _g(s.tgt)
	var txt: String = s.get("stance_text", "")
	return "%s tgt %s %s" % [s.get("skill", ""), tgt, "" if txt == "Stance: off" else txt.replace("\n", " | ").left(60)]


func _frame(t: float, dt: float) -> String:
	var snap: Dictionary = r.read_snapshot_at(t)
	if not snap.has(focus):
		return ""
	var me: Dictionary = snap[focus]
	var mp := Vector2(me.pos.x, me.pos.z)
	var aim := Vector2(me.aim_point.x, me.aim_point.z)
	var aim_at := -1
	var best := 1500.0
	for id in snap:
		if team[id] != focus_team and snap[id].pos.distance_to(Vector3(aim.x, 0, aim.y)) < best:
			best = snap[id].pos.distance_to(Vector3(aim.x, 0, aim.y))
			aim_at = id
	var dealt := 0.0
	var recv := 0.0
	for e in r.read_events_in_range(t - dt, t):
		if e.type in [EV_SHELL_DAMAGE, EV_FIRE_DAMAGE, EV_FLOOD_DAMAGE]:
			if e.attacker_ship_id == focus:
				dealt += e.damage
			if e.victim_ship_id == focus:
				recv += e.damage
	var reloads := PackedStringArray()
	for g in me.guns:
		reloads.append("%.0f" % (g.reload * 100.0))
	var L := PackedStringArray()
	L.append("=== %s  focus hp %.0f%%  spd %.1f  thr %d  rud %+.2f  %s  aim %s  last %.0fs dealt %.0f recv %.0f  reload%% %s" % [
			_mmss(t), 100.0 * me.hp / max_hp[focus], me.velocity.length(), me.throttle, me.rudder,
			"SPOTTED" if me.flags & 1 else "hidden", "-" if aim_at < 0 else "%s %.1fkm" % [_g(aim_at), mp.distance_to(aim) / 1000.0],
			dt, dealt, recv, " ".join(reloads)])
	var fb: Dictionary = r.bot_debug_record(focus, r.bot_debug_index(focus, t))
	if not fb.is_empty():
		var dp: Vector2 = fb.get("dest_pos", Vector2.INF)
		var to := dp - mp
		L.append("  bot: %s tgt %s | dest %s | %s | %s | %s" % [fb.get("skill", ""), "-" if fb.get("tgt", 255) == 255 else _g(fb.tgt),
				"-" if not dp.is_finite() else "%.1fkm brg %.0f" % [to.length() / 1000.0, fposmod(rad_to_deg(atan2(to.x, -to.y)), 360.0)],
				String(fb.get("st_text", "")).replace("\n", " "), String(fb.get("dis_text", "")), String(fb.get("stance_text", "")).left(70)])
	L.append("  g ship            hp%  spd  hdg     x      z   vis  rng  brg  bot")
	var ids := snap.keys()
	ids.sort_custom(func(a, b): return Vector2(snap[a].pos.x, snap[a].pos.z).distance_to(mp) < Vector2(snap[b].pos.x, snap[b].pos.z).distance_to(mp))
	for id in ids:
		var s: Dictionary = snap[id]
		if s.flags & 16 or s.hp <= 0.0:
			continue
		var p := Vector2(s.pos.x, s.pos.z)
		var d := p - mp
		L.append("  %s %-14s %4.0f %4.1f %4.0f %6.0f %6.0f %4s %4.1f %4.0f  %s" % [_g(id), name_of[id], 100.0 * s.hp / max_hp[id],
				s.velocity.length(), _hdg(s.rot_y), p.x, p.y, "S" if s.flags & 1 else "-", d.length() / 1000.0,
				fposmod(rad_to_deg(atan2(d.x, -d.y)), 360.0), _bot_line(id, t)])
	return "\n".join(L) + "\n"


func _map(t: float, zoom: float, cols: int) -> String:
	var snap: Dictionary = r.read_snapshot_at(t)
	var box: Rect2
	if zoom > 0.0 and snap.has(focus):
		box = Rect2(snap[focus].pos.x - zoom, snap[focus].pos.z - zoom, zoom * 2.0, zoom * 2.0)
	else:
		var first := true
		for id in snap:
			if snap[id].flags & 16 or snap[id].hp <= 0.0:
				continue
			var p := Vector2(snap[id].pos.x, snap[id].pos.z)
			box = Rect2(p, Vector2.ZERO) if first else box.expand(p)
			first = false
		box = box.grow(1500.0).intersection(BOUNDS)
	var cell := maxf(box.size.x / cols, box.size.y / (cols / 2.0))
	var w := int(ceil(box.size.x / cell))
	var h := int(ceil(box.size.y / cell))
	var grid := []
	for row in h:
		var line := ""
		for c in w:
			var wp := box.position + Vector2(c + 0.5, row + 0.5) * cell
			line += "#" if nmm.get_distance(Vector3(wp.x, 0, wp.y)) < 0.0 else "."
		grid.append(line)
	for id in snap:
		var s: Dictionary = snap[id]
		var p := Vector2(s.pos.x, s.pos.z)
		var sunk: bool = s.flags & 16 or s.hp <= 0.0
		var c := int((p.x - box.position.x) / cell)
		var row := int((p.y - box.position.y) / cell)
		if c < 0 or c >= w or row < 0 or row >= h:
			continue
		if sunk:
			if grid[row][c] in [".", "#"]:
				grid[row][c] = "x"
			continue
		var fwd := Vector2(-sin(s.rot_y), -cos(s.rot_y))
		var hc := c + int(round(fwd.x * 1.4))
		var hr := row + int(round(fwd.y))
		if hc >= 0 and hc < w and hr >= 0 and hr < h and grid[hr][hc] in [".", "#"]:
			grid[hr][hc] = _arrow(fwd)
		grid[row][c] = _g(id)
	var fb: Dictionary = r.bot_debug_record(focus, r.bot_debug_index(focus, t))
	var dp: Vector2 = fb.get("dest_pos", Vector2.INF)
	if dp.is_finite():
		var dc := int((dp.x - box.position.x) / cell)
		var dr := int((dp.y - box.position.y) / cell)
		if dc >= 0 and dc < w and dr >= 0 and dr < h and grid[dr][dc] in [".", "#"]:
			grid[dr][dc] = "*"
	var ruler := ""
	for c in w:
		ruler += "|" if c % 10 == 0 else " "
	var out := PackedStringArray()
	out.append("=== %s  box x %.0f..%.0f z %.0f..%.0f  %.0f m/char (| every %.1f km)  x = sunk, arrows = heading, * = focus bot destination" % [
			_mmss(t), box.position.x, box.end.x, box.position.y, box.end.y, cell, cell * 10.0 / 1000.0])
	out.append(ruler)
	out.append_array(grid)
	return "\n".join(out) + "\n"


static func _arrow(f: Vector2) -> String:
	var a := fposmod(atan2(f.x, -f.y), TAU)
	return ["^", "/", ">", "\\", "v", "/", "<", "\\"][int(round(a / (TAU / 8.0))) % 8]
