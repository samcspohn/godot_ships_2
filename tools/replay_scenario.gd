extends SceneTree

## Scenario lineup from a replay snapshot: every live ship as it stood at --at, all bots, plus what each team knew then.
## godot --headless --path . -s res://tools/replay_scenario.gd -- [--replay <file>] [--at 9:30] [--out <json>] [--trace "SP1,Shimakaze"]

## GameServer's and TeamState's: naming those scripts here would pull the whole server in.
const MATCH_DURATION_S := 1200.0
const POINTS_START := 300
const POINTS_TICK := 2
const POINTS_TICK_S := 6.0
const KILL_GAINED := {0: 40, 1: 35, 2: 30, 3: 40}
const KILL_LOST := {0: 60, 1: 50, 2: 45, 3: 60}
## BotDebugView.NO_ID: that script needs autoloads a tool run lacks.
const NO_ID := 255

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
	var r = load("res://src/replay/replay_file_reader.gd").new()
	if path == "" or r.load_file(path) != OK:
		push_error("replay_scenario: cannot load " + path)
		quit(1)
		return
	if int(r.header.map_id) != 0:
		push_warning("replay_scenario: map %d; botmatches run on map 0" % int(r.header.map_id))
	var at: float = _clock(CmdArgs.value("--at", "9:30"))
	var snap: Dictionary = r.read_snapshot_at(at)
	if snap.is_empty():
		push_error("replay_scenario: no snapshot at %.0f s" % at)
		quit(1)
		return

	# Last snapshot each ship was visible to its enemies in, up to `at`.
	var last_seen := {}
	for s in r.snapshot_index:
		if float(s.timestamp) > at:
			break
		var frame: Dictionary = r.read_snapshot_at(float(s.timestamp))
		for sid in frame:
			if int(frame[sid].flags) & 1:
				last_seen[sid] = [float(s.timestamp), frame[sid]]

	# Each team's own LKP table as its debug stream recorded it: enemy ship id -> [pos, age s].
	var recorded := {}
	for tid in 2:
		var stream: int = BotDebugCodec.TEAM_STREAM + tid
		var rec: Dictionary = r.bot_debug_record(stream, r.bot_debug_index(stream, at))
		if rec.is_empty():
			continue
		var lk := {}
		for l in rec.get("lkps", []):
			if int(l.id) != NO_ID:
				lk[int(l.id)] = [l.pos, maxf(float(rec.now) - float(l.seen), 0.0)]
		recorded[tid] = lk

	# ship id -> slot -> [uses, last use time]; ship id -> launcher -> last launch time.
	var uses := {}
	var launches := {}
	for e in r.all_events:
		if float(e.timestamp) > at:
			break
		if int(e.type) == 0x40:
			var u: Array = (uses.get_or_add(int(e.ship_id), {}) as Dictionary).get_or_add(int(e.slot_id), [0, 0.0])
			u[0] += 1
			u[1] = float(e.timestamp)
		elif int(e.type) == 0x20:
			(launches.get_or_add(int(e.ship_id), {}) as Dictionary)[str(e.launcher_index)] = snappedf(at - float(e.timestamp), 0.1)

	var team := {}
	var sunk: Array = []
	var names: Array = []
	for m in r.ships:
		var sid: int = int(m.ship_id)
		var st: Dictionary = snap.get(sid, {})
		var cls: int = _ship_class(m.scene_path)
		if st.is_empty() or float(st.hp) <= 0.0 or int(st.flags) & 16:
			sunk.append({"team": int(m.team_id), "class": cls})
			continue
		var rot: float = float(st.rot_y)
		var fwd := Vector3(-sin(rot), 0.0, -cos(rot))
		var e := {
			"team": str(m.team_id), "player_id": "p%02d" % sid, "ship": m.scene_path, "is_bot": true, "aptitude": 1,
			"pos": [snappedf(st.pos.x, 0.1), snappedf(st.pos.z, 0.1)],
			"heading_deg": snappedf(rad_to_deg(wrapf(rot - PI, -PI, PI)), 0.1),
			"speed": snappedf((st.velocity as Vector3).dot(fwd), 0.01),
			"throttle": int(st.throttle),
			"hp": snappedf(float(st.hp), 1.0),
			"reload": (st.guns as Array).map(func(g): return snappedf(float(g.reload), 0.001)),
		}
		var cons: Array = []
		for slot in uses.get(sid, {}):
			var u: Array = uses[sid][slot]
			cons.append({"slot": slot, "used": u[0], "last_s": snappedf(at - float(u[1]), 0.1)})
		if not cons.is_empty():
			e["consumables"] = cons
		if launches.has(sid):
			e["torp_last_s"] = launches[sid]
		var them: int = 1 - int(m.team_id)
		e["identified"] = last_seen.has(sid)
		var lkp_pos := Vector2.INF
		var age := 0.0
		if recorded.has(them) and (recorded[them] as Dictionary).has(sid):
			lkp_pos = recorded[them][sid][0]
			age = recorded[them][sid][1]
		elif recorded.has(them) and int(st.flags) & 1:
			lkp_pos = Vector2(st.pos.x, st.pos.z)
		elif not recorded.has(them) and last_seen.has(sid):
			lkp_pos = Vector2(last_seen[sid][1].pos.x, last_seen[sid][1].pos.z)
			age = at - float(last_seen[sid][0])
		if lkp_pos.is_finite():
			# The stream keeps no course: the snapshot nearest the sighting has it.
			var then: Dictionary = r.read_snapshot_at(at - age).get(sid, st)
			e["lkp"] = {"pos": [snappedf(lkp_pos.x, 0.1), snappedf(lkp_pos.y, 0.1)], "age_s": snappedf(age, 0.1),
				"vel": [snappedf(then.velocity.x, 0.01), snappedf(then.velocity.z, 0.01)], "rot": snappedf(float(then.rot_y), 0.001)}
		team[e.player_id] = e
		names.append("%s %s team %d hp %.0f lkp %s" % [e.player_id, m.ship_name, m.team_id, float(st.hp),
			"%.0f s old" % float(e.lkp.age_s) if e.has("lkp") else "none"])

	if recorded.size() < 2:
		push_warning("replay_scenario: no team debug stream for team(s) %s; their LKPs are their last sightings" % \
			str([0, 1].filter(func(t): return not recorded.has(t))))
	var final := _final(r)
	var trace: Array = Array(CmdArgs.value("--trace", "").split(",", false))
	var cfg := {"duration_s": maxf(MATCH_DURATION_S - at, 1.0), "elapsed_s": at, "trace": trace, "log_dt": 5.0, "sunk": sunk,
		"source": {"replay": path.get_file(), "at_s": at, "winning_team": r.winning_team, "duration_s": r.total_duration,
			"final": final},
		"expect": "From %s at %s: the recorded match was won by team %d." % [path.get_file(), _mmss(at), r.winning_team]}
	var out: String = CmdArgs.value("--out", "res://tools/scenarios/snap_%s_%s.json" % [path.get_file().get_basename(), _mmss(at).replace(":", "")])
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify({"scenario": cfg, "team": team}, " "))
	f.close()
	print("replay_scenario: %s at %s -> %s" % [path.get_file(), _mmss(at), out])
	print("  %d alive, %d sunk; recorded winner team %d at %s, points %s, alive %s, hp %s" % [team.size(), sunk.size(),
		r.winning_team, _mmss(r.total_duration), final.points, final.alive, final.hp])
	for n in names:
		print("  " + n)
	quit(0)

## The recorded end: points (clock ticks and every sink), ships alive and their HP per team.
static func _final(r) -> Dictionary:
	var cls := {}
	var team_of := {}
	for m in r.ships:
		cls[int(m.ship_id)] = _ship_class(m.scene_path)
		team_of[int(m.ship_id)] = int(m.team_id)
	var ticks: int = int(minf(r.total_duration, MATCH_DURATION_S) / POINTS_TICK_S)
	var points := [POINTS_START + ticks * POINTS_TICK, POINTS_START + ticks * POINTS_TICK]
	for e in r.all_events:
		if int(e.type) == 0x60 and team_of.has(int(e.victim_ship_id)):
			var v: int = team_of[int(e.victim_ship_id)]
			points[v] -= int(KILL_LOST[cls[int(e.victim_ship_id)]])
			points[1 - v] += int(KILL_GAINED[cls[int(e.victim_ship_id)]])
	var last: Dictionary = r.read_snapshot_at(float(r.snapshot_index[-1].timestamp))
	var alive := [0, 0]
	var hp := [0.0, 0.0]
	for sid in last:
		if team_of.has(sid) and float(last[sid].hp) > 0.0 and not int(last[sid].flags) & 16:
			alive[team_of[sid]] += 1
			hp[team_of[sid]] += roundf(float(last[sid].hp))
	return {"points": points, "alive": alive, "hp": hp}

## "9:30" or seconds.
static func _clock(s: String) -> float:
	if ":" in s:
		var p := s.split(":")
		return float(p[0]) * 60.0 + float(p[1])
	return float(s)

static func _mmss(t: float) -> String:
	return "%d:%02d" % [int(t) / 60, int(t) % 60]

## The scene root's ship_class, read from the file: instancing a hull is far heavier. Omitted is Ship's default, CA.
static func _ship_class(scene: String) -> int:
	var txt := FileAccess.get_file_as_string(scene)
	var rx := RegEx.create_from_string("(?m)^ship_class = (\\d+)")
	var m := rx.search(txt)
	return int(m.get_string(1)) if m != null else 1
