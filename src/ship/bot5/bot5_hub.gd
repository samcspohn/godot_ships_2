extends Node
class_name Bot5Hub

## Thin adapter for the native v5 bots (BotWorld): packs ship state in, applies commands out.

const STRIDE := 32
const CMD_STRIDE := 19
const TORP_REAIM_FRAMES := 2
const SPOT_REISSUE_M := 300.0
const AIM_TOL_M := 5.0
const PAIR_RETRY_S := 2.0
const LIVE_EVERY_S := 0.5
const STATIC_EVERY_S := 2.0

var world: BotWorld = BotWorld.new()
var server: GameServer
var _setup_done := false
var _pending: Array = []
var _ships: Array[Ship] = []
var _slot_of: Dictionary = {}
var _repair_slot: PackedInt32Array = []
var _dc_slot: PackedInt32Array = []
var _spot_idx: PackedInt32Array = []
var _spot_wp: PackedVector2Array = []
var _torp_pt: PackedVector2Array = []
var _torp_frame: PackedInt64Array = []
var _shots := PackedInt32Array()
var _static: Dictionary = {}
var _static_t := -INF
var _pair_t := -INF
var _live_t := -INF
var _ids := PackedInt64Array()
var _trace := OS.has_environment("SHIPS_BOT5_TRACE")
var _gates: Dictionary = {}
var _data := PackedFloat32Array()
var _frame_us := PackedInt32Array()


func add_ship(ship: Ship, team_data: Dictionary) -> void:
	_pending.append({ship = ship, cfg = team_data, frame = Engine.get_physics_frames()})


func is_v5(ship: Ship) -> bool:
	return _slot_of.has(ship)


func field_bytes(ship: Ship, dark: bool) -> PackedByteArray:
	return world.field_bytes(_slot_of[ship], dark) if _slot_of.has(ship) else PackedByteArray()


## Match setup (server warm step): world setup, bot registration, terrain tables, so the first frame stays cheap.
func prepare() -> bool:
	if not _setup():
		return false
	_register_pending(true)
	return world.prepare()


func _setup() -> bool:
	if _setup_done:
		return true
	if not _Utils.authority() or server == null or not NavigationMapManager.is_map_ready():
		return false
	world.setup(NavigationMapManager.get_map(), NavigationMapManager.get_hpa_graph(), server.ship_registry,
		ProjectileManager.get_raw(), get_viewport().find_world_3d().direct_space_state,
		NavigationMapManager.get_visibility(), NavigationMapManager.get_reach_field())
	_setup_done = true
	return true


func _physics_process(delta: float) -> void:
	if not _setup():
		return
	var t0 := Time.get_ticks_usec()
	if _register_pending(false) > 0:
		world.prepare()
	if _ships.is_empty():
		return
	var now: float = SimClock.now()
	_push_ships(now)
	if now - _pair_t >= PAIR_RETRY_S:
		_pair_t = now
		_push_pairs()
	if now - _live_t >= LIVE_EVERY_S:
		_live_t = now
		_push_live()
	for slot in _ships.size():
		_push_inputs(slot)
	world.tick(now, delta, ProjectileManager.get_shell_time_multiplier())
	_apply(world.commands(), now)
	BotTiming.add(&"bot5", t0)
	_frame_us.append(Time.get_ticks_usec() - t0)
	var f: Ship = Debug.follow_ship
	if f != null and _slot_of.has(f):
		var slot: int = _slot_of[f]
		Bot5DebugView.draw(world.debug_bot(slot), world.debug_team(slot, now), now)
	if _trace and Engine.get_physics_frames() % 160 == 0:
		for slot in _ships.size():
			print("bot5 trace ", _ships[slot].ship_name, " ", world.debug_bot(slot), " hub ", _gates.get(slot, {}))
		if not _ships.is_empty():
			var t := world.debug_team(0, now)
			print("bot5 flanks t=%d " % int(now), JSON.stringify(t.get("flanks", [])), " roles ", t.get("roles", []).map(func(r): return r.role))


## `settled`: the caller already waited for stat mods to land.
func _register_pending(settled: bool) -> int:
	var keep := []
	var n := 0
	for p in _pending:
		var ship: Ship = p.ship
		if not is_instance_valid(ship):
			continue
		if not ship.is_inside_tree() or ship.movement_controller == null or ship.artillery_controller == null \
				or (not settled and Engine.get_physics_frames() - int(p.frame) < 3):
			keep.append(p)
			continue
		_register(ship, p.cfg)
		n += 1
	_pending = keep
	return n


func _register(ship: Ship, cfg: Dictionary) -> void:
	var mv: ShipMovementV4 = ship.movement_controller
	var kp = mv._p()
	var gp: GunParams = ship.artillery_controller.get_params()
	var slot := world.add_bot({
		ship_id = ship.get_instance_id(),
		team = ship.team.team_id,
		hull_class = int(ship.ship_class),
		playstyle = int(cfg.get("playstyle", -1)),
		aptitude = int(cfg.get("aptitude", BotAptitude.Level.REGULAR)),
		turning_circle_radius = kp.turning_circle_radius,
		rudder_response_time = kp.rudder_response_time,
		acceleration_time = kp.acceleration_time,
		deceleration_time = kp.deceleration_time,
		max_speed = mv.max_speed,
		reverse_speed_ratio = kp.reverse_speed_ratio,
		length = mv.ship_length,
		beam = mv.ship_beam,
		turn_speed_loss = kp.turn_speed_loss,
		linear_drag = mv.BASE_DRAG,
		turn_tightening = kp.slow_speed_turn_tightening,
		reload = gp.reload_time,
		shell_ap = gp.shell1,
		shell_he = gp.shell2,
		damage_ap = gp.shell1.damage if gp.shell1 != null else 0.0,
		damage_he = gp.shell2.damage if gp.shell2 != null else 0.0,
		gun_h = float(NavigationMapManager.reach_gun(ship).get("gun_h", 5.0)),
		gun_range = gp._range,
	}.merged(_torp_cfg(ship)).merged(_spot_cfg(ship)))
	_ships.append(ship)
	_slot_of[ship] = slot
	_repair_slot.append(_consumable_slot(ship, ConsumableItem.ConsumableType.REPAIR_PARTY))
	_dc_slot.append(_consumable_slot(ship, ConsumableItem.ConsumableType.DAMAGE_CONTROL))
	_spot_idx.append(_spotter_index(ship))
	_spot_wp.append(Vector2.INF)
	_torp_pt.append(Vector2.INF)
	_torp_frame.append(0)
	_shots.append_array([0, 0])


static func _torp_cfg(ship: Ship) -> Dictionary:
	var tc := ship.torpedo_controller
	if tc == null or tc.launchers.is_empty():
		return {}
	var tubes := 1
	for l in tc.launchers:
		tubes = maxi(tubes, l.muzzles.size())
	var tp := tc.get_torp_params()
	return {torp_speed = tp.speed * TorpedoManager.TORPEDO_SPEED_MULTIPLIER, torp_range = tc.get_params()._range,
		torp_tubes = tubes, torp_detect = tp.detection_range}


static func _spotter_index(ship: Ship) -> int:
	var av := ship.aviation_controller
	if av == null:
		return -1
	for i in av.squadrons.size():
		var sq: Squadron = av.squadrons[i]
		if not sq.aircraft.is_empty() and sq.aircraft[0] is SpottingAircraft:
			return i
	return -1


static func _spot_cfg(ship: Ship) -> Dictionary:
	var i := _spotter_index(ship)
	if i < 0:
		return {}
	return {spot_reach = (ship.aviation_controller.squadrons[i].params.p() as AircraftParams)._range}


static func _consumable_slot(ship: Ship, type: int) -> int:
	var cm = ship.consumable_manager
	if cm == null:
		return -1
	for i in cm.equipped_consumables.size():
		var c = cm.equipped_consumables[i]
		if c != null and c.type == type:
			return i
	return -1


func _ship_static(ship: Ship) -> Array:
	var mv = ship.movement_controller
	var ac = ship.artillery_controller
	var rev: float = mv._p().reverse_speed_ratio if mv else 0.5
	var cp: ConcealmentParams = ship.concealment.params.p() as ConcealmentParams if ship.concealment and ship.concealment.params else null
	var g: Dictionary = NavigationMapManager.reach_gun(ship)
	return [mv.max_speed if mv else 0.0, mv.ship_length if mv else 200.0, mv.ship_beam if mv else 20.0,
		float(ship.ship_class), ac.get_params()._range if ac else 0.0, ship.health_controller.max_hp, rev,
		(mv.ship_height - mv.ship_draft) if mv else 10.0, mv._p().turning_circle_radius if mv else 500.0,
		cp.air_radius if cp else 2500.0, cp.torpedo_detection_multiplier if cp else 1.0,
		cp.torpedo_detection_range_override if cp else -1.0,
		cp.radius if cp else 0.0, server._latent_force_spot_reach(ship) * server.LATENT_FORCE_SPOT_FACTOR,
		g.get("speed", 0.0), g.get("drag", 0.0), g.get("gun_h", 0.0), cp,
		ac.get_params().reload_time if ac else 0.0, float(GunneryModel.barrels(ac.guns)) if ac else 0.0,
		_shell_damage(ac, 0), _shell_damage(ac, 1)]


static func _shell_damage(ac, ammo: int) -> float:
	if ac == null:
		return 0.0
	var gp: GunParams = ac.get_params()
	var sh: ShellParams = gp.shell1 if ammo == 0 else gp.shell2
	return sh.damage if sh != null else 0.0


func _push_ships(now: float) -> void:
	var ships: Array = server.get_all_ships()
	var refresh := now - _static_t >= STATIC_EVERY_S
	if refresh:
		_static_t = now
	_ids.resize(ships.size())
	_data.resize(ships.size() * STRIDE)
	var i := 0
	for s: Ship in ships:
		if not is_instance_valid(s) or s.team == null:
			continue
		if refresh or not _static.has(s):
			_static[s] = _ship_static(s)
		var st: Array = _static[s]
		var hp = s.health_controller
		var o := i * STRIDE
		_ids[i] = s.get_instance_id()
		_data[o] = s.team.team_id
		_data[o + 1] = 1.0 if s.is_alive() else 0.0
		_data[o + 2] = s.global_position.x
		_data[o + 3] = s.global_position.y
		_data[o + 4] = s.global_position.z
		_data[o + 5] = s.linear_velocity.x
		_data[o + 6] = s.linear_velocity.z
		_data[o + 7] = s.global_rotation.y
		_data[o + 8] = s.angular_velocity.y
		_data[o + 9] = hp.current_hp / maxf(hp.max_hp, 1.0)
		_data[o + 10] = 1.0 if s.visible_to_enemy else 0.0
		_data[o + 11] = st[0]
		_data[o + 12] = st[1]
		_data[o + 13] = st[2]
		_data[o + 14] = st[3]
		_data[o + 15] = st[4]
		_data[o + 16] = st[5]
		_data[o + 17] = st[6]
		_data[o + 18] = st[7]
		_data[o + 19] = st[8]
		_data[o + 20] = st[9]
		_data[o + 21] = st[10]
		_data[o + 22] = st[11]
		_data[o + 23] = st[12]
		var cp: ConcealmentParams = st[17]
		_data[o + 24] = maxf(st[13], maxf(cp.spotting_range_override, cp.radar_spotting_range_override)) if cp else st[13]
		_data[o + 25] = st[14]
		_data[o + 26] = st[15]
		_data[o + 27] = st[16]
		_data[o + 28] = st[18]
		_data[o + 29] = st[19]
		_data[o + 30] = st[20]
		_data[o + 31] = st[21]
		i += 1
	_ids.resize(i)
	_data.resize(i * STRIDE)
	world.set_ships(_ids, _data)


## Point-table keys and loading (PointTables), the v4 solver never involved.
func _push_pairs() -> void:
	for slot in _ships.size():
		var me := _ships[slot]
		if not is_instance_valid(me) or not me.is_alive():
			continue
		var gp: GunParams = me.artillery_controller.get_params()
		for t: Ship in server.get_all_ships():
			if t.team == null or t.team.team_id == me.team.team_id or not t.is_alive():
				continue
			if world.has_pair(slot, t.get_instance_id()):
				continue
			var ap := PointTables.table_key(me, t, 0) if gp.shell1 != null else ""
			var he := PointTables.table_key(me, t, 1) if gp.shell2 != null else ""
			if (gp.shell1 != null and ap == "") or (gp.shell2 != null and he == ""):
				continue
			var raw: float = GunneryModel.raw_fire_chance(gp.shell2, t) if gp.shell2 != null else 0.0
			world.set_pair(slot, t.get_instance_id(), ap, he, raw)
		for t: Ship in server.get_all_ships():
			if t.team == null or t.team.team_id == me.team.team_id or not t.is_alive() or t.artillery_controller == null:
				continue
			if world.has_threat(slot, t.get_instance_id()):
				continue
			var tp: GunParams = t.artillery_controller.get_params()
			var tap := PointTables.table_key(t, me, 0) if tp.shell1 != null else ""
			var the := PointTables.table_key(t, me, 1) if tp.shell2 != null else ""
			if (tp.shell1 != null and tap == "") or (tp.shell2 != null and the == ""):
				continue
			world.set_threat(slot, t.get_instance_id(), tap, the)


func _push_live() -> void:
	for t: Ship in server.get_all_ships():
		if not is_instance_valid(t) or not t.is_alive():
			continue
		var fires := PackedFloat32Array()
		if t.fire_manager != null:
			for f in t.fire_manager.fires:
				if f != null:
					var p: Vector3 = (f as Fire).position
					fires.append_array([p.x, p.y, p.z, 1.0 if (f as Fire).lifetime > 0.0 else 0.0])
		world.set_target_live(t.get_instance_id(), PointTables.saturation_mask(t), fires,
			GunneryModel.fire_dps(t) * GunneryModel.fire_burn_s(t))


func _push_inputs(slot: int) -> void:
	var s := _ships[slot]
	if not is_instance_valid(s) or not s.is_alive():
		return
	var ac := s.artillery_controller
	var reload: float = ac.get_params().reload_time
	var ready := 0
	var live := 0
	var lag := 0.0
	for g in ac.guns:
		if g.disabled:
			continue
		live += 1
		if g.reload >= 1.0:
			ready += 1
		else:
			lag = maxf(lag, (1.0 - g.reload) * reload)
	var hp = s.health_controller
	var heal := 0.0
	var repair_ready := false
	var rs: int = _repair_slot[slot]
	if rs >= 0:
		var rp = (s.consumable_manager.equipped_consumables[rs] as RepairParty).p() as RepairParty
		heal = rp.heal_per_sec * rp.duration
		repair_ready = s.consumable_manager.can_use_item(s.consumable_manager.equipped_consumables[rs])
	var dc_ready := false
	var ds: int = _dc_slot[slot]
	if ds >= 0:
		dc_ready = s.consumable_manager.can_use_item(s.consumable_manager.equipped_consumables[ds])
	var mv: ShipMovementV4 = s.movement_controller
	var torp_ready := 0
	var torp_live := 0
	var lc := Vector3.ZERO
	var tc := s.torpedo_controller
	if tc != null:
		for l in tc.launchers:
			if l.disabled:
				continue
			torp_live += 1
			lc += l.global_position
			if l.reload >= 1.0:
				torp_ready += 1
	lc = lc / torp_live if torp_live > 0 else s.global_position
	var spot_ready := false
	var spot_up := false
	var si: int = _spot_idx[slot]
	if si >= 0:
		spot_ready = s.aviation_controller.can_launch(si)
		spot_up = s.aviation_controller.squadrons[si].active
	world.set_bot_inputs(slot, PackedFloat32Array([ready, live, lag,
		hp.healable_damage / maxf(hp.max_hp, 1.0), heal,
		s.fire_manager.get_active_fires() if s.fire_manager else 0,
		s.flood_manager.get_active_floods() if s.flood_manager else 0,
		1.0 if repair_ready else 0.0, 1.0 if dc_ready else 0.0,
		mv.rudder_input, mv.engine_power, 1.0 if mv.is_grounded else 0.0,
		torp_ready, torp_live, lc.x, lc.z, 1.0 if spot_ready else 0.0, 1.0 if spot_up else 0.0]))


func _apply(cmd: PackedFloat64Array, now: float) -> void:
	for slot in _ships.size():
		var s := _ships[slot]
		if not is_instance_valid(s) or not s.is_alive():
			continue
		var o := slot * CMD_STRIDE
		s.movement_controller.set_movement_input([int(cmd[o]), cmd[o + 1]])
		var ac := s.artillery_controller
		if cmd[o + 2] > 0.5:
			var aim := Vector3(cmd[o + 3], cmd[o + 4], cmd[o + 5])
			ac.set_aim_input(aim)
			var ammo := int(cmd[o + 6])
			if ac.shell_index != ammo and _all_loaded(ac):
				ac.select_shell(ammo)
			if cmd[o + 7] > 0.5:
				_fire_one(slot, s, aim, now)
		if cmd[o + 8] > 0.5:
			s.consumable_manager.use_consumable(_repair_slot[slot])
		if cmd[o + 9] > 0.5:
			s.consumable_manager.use_consumable(_dc_slot[slot])
		if cmd[o + 12] > 0.5:
			_torps(slot, s, Vector2(cmd[o + 13], cmd[o + 14]), cmd[o + 15] > 0.5, now)
		_spotter(slot, s, cmd[o + 16] > 0.5, Vector2(cmd[o + 17], cmd[o + 18]))
		if Engine.get_physics_frames() % 8 == slot % 8:
			_secondaries(slot, s)


static func _all_loaded(ac) -> bool:
	for g in ac.guns:
		if not g.disabled and g.reload < 1.0:
			return false
	return true


## One gun per frame, like a ripple salvo; only guns already laid on the aim.
func _fire_one(slot: int, s: Ship, aim: Vector3, now: float) -> void:
	var ac := s.artillery_controller
	var waiting := false
	for g in ac.guns:
		if g.disabled or g.reload < 1.0 or not g.can_fire:
			continue
		if g._aim_point.distance_to(aim) > AIM_TOL_M:
			waiting = true
			continue
		g.fire(ac.target_mod)
		_gate(slot, "fired")
		_shots[slot * 2 + int(g.get_shell().type == ShellParams.ShellType.HE)] += 1
		world.note_fired(slot, 1, now)
		return
	if waiting:
		world.note(&"not_aimed")
		_gate(slot, "not_aimed")
	else:
		_gate(slot, "none_ready")


## A launcher's can_fire is from the last aim until it re-aims next frame, so a new spread point waits.
func _torps(slot: int, s: Ship, p: Vector2, fire: bool, now: float) -> void:
	var tc := s.torpedo_controller
	var frame := Engine.get_physics_frames()
	if p != _torp_pt[slot]:
		_torp_pt[slot] = p
		_torp_frame[slot] = frame
	tc.set_aim_input(Vector3(p.x, 0.0, p.y))
	if not fire or frame - _torp_frame[slot] < TORP_REAIM_FRAMES:
		return
	for l in tc.launchers:
		if not l.disabled and l.reload >= 1.0 and l.can_fire:
			l.fire()
			world.note_torp_fired(slot, now)
			return


func _spotter(slot: int, s: Ship, want: bool, p: Vector2) -> void:
	var i: int = _spot_idx[slot]
	if i < 0:
		return
	var av := s.aviation_controller
	var sq: Squadron = av.squadrons[i]
	if not sq.active:
		_spot_wp[slot] = Vector2.INF
		if want:
			av.ensure_launched(i)
		return
	if want and not sq.returning and sq.station_lock <= 0.0 and p.distance_to(_spot_wp[slot]) > SPOT_REISSUE_M:
		sq.set_attack(p, p - Vector2(s.global_position.x, s.global_position.z))
		_spot_wp[slot] = p


func _gate(slot: int, k: String) -> void:
	if _trace:
		var g: Dictionary = _gates.get_or_add(slot, {})
		g[k] = int(g.get(k, 0)) + 1


func _secondaries(slot: int, s: Ship) -> void:
	var sec = s.secondary_controller
	if sec == null or sec.sub_controllers.is_empty():
		return
	var max_range: float = sec.get_max_range()
	var tid: int = world.target_of(slot)
	var pick: Ship = null
	if tid != 0:
		var t = instance_from_id(tid)
		if t is Ship and t.is_alive() and t.visible_to_enemy and t.global_position.distance_to(s.global_position) <= max_range:
			pick = t
	if pick == null:
		var best := INF
		for e: Ship in server.get_valid_targets(s.team.team_id):
			var d := e.global_position.distance_to(s.global_position)
			if e.is_alive() and d <= max_range and d < best:
				best = d
				pick = e
	sec.target = pick
	sec.target_offset = Vector3.ZERO


func shots_of(ship: Ship) -> PackedInt32Array:
	var slot: int = _slot_of.get(ship, -1)
	return PackedInt32Array([_shots[slot * 2], _shots[slot * 2 + 1]]) if slot >= 0 else PackedInt32Array([0, 0])


func telemetry() -> Dictionary:
	var t := world.telemetry()
	t["hub_frame_us"] = frame_stats()
	return t


func frame_stats() -> Dictionary:
	var n := _frame_us.size()
	if n == 0:
		return {}
	var v := _frame_us.duplicate()
	v.sort()
	var sum := 0
	for x in v:
		sum += x
	var at := func(q: float) -> int: return v[mini(int(q * n), n - 1)]
	return {n = n, mean = float(sum) / n, p50 = at.call(0.5), p90 = at.call(0.9), p99 = at.call(0.99),
		p999 = at.call(0.999), max = v[n - 1]}
