## ReplayRecorder — server-side match recorder autoload.
##
## Register in project.godot autoloads as:
##   ReplayRecorder = "*res://src/replay/replay_recorder.gd"
##
## Call begin_match(ships, map_id) once the match starts.
## All other record_* methods are called from the relevant game systems.
## end_match() is triggered automatically via _Utils.match_ended signal.
extends Node

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _file: FileAccess = null
var _match_start_time: float    = 0.0
var _match_active: bool         = false
var _snapshot_timer: float      = 0.0

const SNAPSHOT_INTERVAL: float  = 0.2   # 5 Hz

var _ships: Array        = []            # Array[Ship], index = ship_id
var _ship_to_id: Dictionary = {}         # Ship -> int (ship_id)
var _ship_gun_counts: Array = []         # Array[int], gun count per ship (from manifest)
var _ship_secondary_gun_counts: Array = []  # Array[int], secondary gun count per ship

# Snapshot seek-table built in memory, flushed to EOF in end_match()
# Each entry: { timestamp: float, offset: int }
var _snapshot_index: Array = []

# Detection cache — used to emit DETECTION_CHANGED events
var _prev_detection: Dictionary = {}     # Ship -> int
var _prev_visible: Dictionary   = {}     # Ship -> bool

# ---------------------------------------------------------------------------
# FileAccess string helper (u8 length + UTF-8 bytes, mirrors ReplayEvent.write_string)
# ---------------------------------------------------------------------------
func _file_write_string(s: String) -> void:
	var bytes: PackedByteArray = s.to_utf8_buffer()
	if bytes.size() > 255:
		bytes.resize(255)
	_file.store_8(bytes.size())
	_file.store_buffer(bytes)

# ---------------------------------------------------------------------------
# begin_match
# ---------------------------------------------------------------------------
## Call this from the server once all Ship nodes are ready.
## [param ships]  Array of Ship nodes in the order they should be indexed.
## [param map_id] Integer map identifier (stored in the header).
func begin_match(ships: Array, map_id: int) -> void:
	if not _Utils.authority():
		return

	# --- build ship index -------------------------------------------------
	_ships = []
	_ship_to_id = {}
	_ship_gun_counts = []
	_ship_secondary_gun_counts = []
	for i in range(ships.size()):
		var ship: Ship = ships[i]
		_ships.append(ship)
		_ship_to_id[ship] = i
		_ship_gun_counts.append(
			ship.artillery_controller.guns.size() if ship.artillery_controller else 0
		)
		var sec_count: int = 0
		if ship.secondary_controller:
			for _sc in ship.secondary_controller.sub_controllers:
				sec_count += _sc.guns.size()
		_ship_secondary_gun_counts.append(sec_count)

	# --- open replay file -------------------------------------------------
	DirAccess.make_dir_recursive_absolute("user://replays")
	var ts: int = int(Time.get_unix_time_from_system())
	var filename: String = "user://replays/%d_%d.replay" % [ts, map_id]
	_file = FileAccess.open(filename, FileAccess.WRITE)
	if _file == null:
		push_error("ReplayRecorder: failed to open '%s' (error %d)" % [
			filename, FileAccess.get_open_error()])
		return

	# --- header -----------------------------------------------------------
	# Byte layout (must match reader expectations):
	#   0  – 3  : MAGIC  (u32)
	#   4  – 5  : VERSION (u16)
	#   6  – 9  : match_ts (u32, unix timestamp)
	#   10      : map_id (u8)
	#   11 – 12 : ship_count (u16)
	#   13 – 16 : index_offset placeholder (u32) ← patched in end_match()
	#   17+     : ship manifest entries
	_file.store_32(ReplayEvent.MAGIC)
	_file.store_16(ReplayEvent.VERSION)
	_file.store_32(ts)
	_file.store_8(map_id)
	_file.store_16(ships.size())
	_file.store_32(0)   # index_offset placeholder at byte offset 13

	# --- ship manifest ----------------------------------------------------
	for i in range(ships.size()):
		var ship: Ship = ships[i]

		_file.store_8(i)   # ship_id

		if ship.team:
			_file.store_8(ship.team.team_id)
			_file.store_8(1 if ship.team.is_bot else 0)
		else:
			_file.store_8(0)
			_file.store_8(0)

		_file_write_string(ship.name)          # player_name (node/peer id)
		_file_write_string(ship.ship_name)     # human-readable ship type
		_file_write_string(ship.scene_file_path)

		var gun_count: int = _ship_gun_counts[i]
		_file.store_8(gun_count)
		var secondary_gun_count: int = _ship_secondary_gun_counts[i] if i < _ship_secondary_gun_counts.size() else 0
		_file.store_8(secondary_gun_count)

		var fire_count: int = ship.fire_manager.fires.size() if ship.fire_manager else 0
		_file.store_8(fire_count)

		var flood_count: int = ship.flood_manager.floods.size() if ship.flood_manager else 0
		_file.store_8(flood_count)

		var consumable_count: int = 0
		if ship.consumable_manager:
			consumable_count = ship.consumable_manager.equipped_consumables.size()
		_file.store_8(consumable_count)

		# Per-consumable slot metadata
		if ship.consumable_manager:
			for j in range(ship.consumable_manager.equipped_consumables.size()):
				var item = ship.consumable_manager.equipped_consumables[j]
				_file.store_8(j)                               # slot_id
				_file.store_8(item.type if item else 0)        # ConsumableType int
				_file_write_string(item.name if item else "")  # label

	# --- MATCH_START event ------------------------------------------------
	_file.store_float(0.0)
	_file.store_8(ReplayEvent.MATCH_START)

	# --- activate recorder ------------------------------------------------
	_match_start_time = Time.get_ticks_msec() / 1000.0
	_match_active     = true
	_snapshot_timer   = 0.0
	_snapshot_index   = []
	_prev_detection   = {}
	_prev_visible     = {}

	# Begin armor sim companion log alongside this replay.
	if is_instance_valid(ArmorSimLogger):
		ArmorSimLogger.begin_log(filename, _ship_to_id)

	# --- connect global signals -------------------------------------------
	if not _Utils.kill_feed_event.is_connected(_on_kill_feed_event):
		_Utils.kill_feed_event.connect(_on_kill_feed_event)
	if not _Utils.match_ended.is_connected(_on_match_ended):
		_Utils.match_ended.connect(_on_match_ended)

	# --- connect per-ship consumable signals ------------------------------
	for ship in _ships:
		if not ship.consumable_manager:
			continue
		var cm = ship.consumable_manager
		if not cm.consumable_used.is_connected(_on_consumable_used.bind(ship)):
			cm.consumable_used.connect(_on_consumable_used.bind(ship))
		if not cm.consumable_ready.is_connected(_on_consumable_ended.bind(ship)):
			cm.consumable_ready.connect(_on_consumable_ended.bind(ship))

# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------
func _current_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _match_start_time

## Write the 5-byte event preamble: [f32 timestamp][u8 event_type]
func _write_preamble(event_type: int) -> void:
	_file.store_float(_current_time())
	_file.store_8(event_type)

# ---------------------------------------------------------------------------
# _physics_process — snapshot timer + detection-change events
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if not _match_active or _file == null:
		return

	_snapshot_timer += delta
	if _snapshot_timer >= SNAPSHOT_INTERVAL:
		_write_snapshot()
		_snapshot_timer = 0.0

	# Emit DETECTION_CHANGED whenever a ship's detection state changes
	for ship in _ships:
		if not is_instance_valid(ship):
			continue
		var dt: int = ship._det_flags()
		var ve: bool = ship.visible_to_enemy
		if _prev_detection.get(ship, -1) != dt or _prev_visible.get(ship, false) != ve:
			_prev_detection[ship] = dt
			_prev_visible[ship]   = ve
			_write_preamble(ReplayEvent.DETECTION_CHANGED)
			_file.store_8(_ship_to_id.get(ship, 255))
			_file.store_8(dt)
			_file.store_8(1 if ve else 0)

# ---------------------------------------------------------------------------
# _write_snapshot
# ---------------------------------------------------------------------------
## Per-ship fixed snapshot layout (54 bytes + 12 bytes × gun_count):
##
##  Floats (×12, 48 bytes):
##    pos.x, pos.z, rot.y,
##    lv.x, lv.y, lv.z,
##    hp,
##    rudder_input,
##    aim.x, aim.y, aim.z,
##    bloom_radius
##
##  Bytes (×6, 6 bytes):
##    flags, throttle+1, shell_index,
##    fire_mask, flood_mask, consumable_mask
##
##  Per gun (×gun_count × 3 floats, 12 bytes each):
##    gun.rotation.y, gun.barrel.rotation.x, gun.reload
func _write_snapshot() -> void:
	_snapshot_index.append({
		"timestamp": _current_time(),
		"offset":    _file.get_position()
	})
	_write_preamble(ReplayEvent.SNAPSHOT)

	for i in range(_ships.size()):
		var ship = _ships[i]
		var gc: int = _ship_gun_counts[i] if i < _ship_gun_counts.size() else 0

		# --- invalid / freed ship: write zeros so the binary layout stays fixed ---
		if not is_instance_valid(ship):
			for _j in range(12):       # 12 floats
				_file.store_float(0.0)
			for _j in range(6):        # 6 u8 bytes
				_file.store_8(0)
			for _j in range(gc * 3):   # gc guns × 3 floats each
				_file.store_float(0.0)
			_file.store_8(0)   # secondary_active = 0 (not active, guns at base)
			continue

		# --- position / orientation -------------------------------------------
		_file.store_float(ship.global_position.x)
		_file.store_float(ship.global_position.z)
		_file.store_float(ship.rotation.y)

		# --- linear velocity --------------------------------------------------
		_file.store_float(ship.linear_velocity.x)
		_file.store_float(ship.linear_velocity.y)
		_file.store_float(ship.linear_velocity.z)

		# --- HP ---------------------------------------------------------------
		var hp: float = ship.health_controller.current_hp if ship.health_controller else 0.0
		_file.store_float(hp)

		# --- flags byte: bit0=visible_to_enemy, bit1=det_los, bit2=det_hydro, bit3=det_radar, bit4=sunk ---
		var flags: int = 0
		if ship.visible_to_enemy:
			flags |= 1
		flags |= (ship._det_flags() & 0x7) << 1
		if hp <= 0.0:
			flags |= 16
		_file.store_8(flags)

		# --- movement controller ----------------------------------------------
		if ship.movement_controller:
			# throttle_level ranges –1..4; +1 offset so stored range is 0..5
			_file.store_8(ship.movement_controller.throttle_level + 1)
			_file.store_float(ship.movement_controller.rudder_input)
		else:
			_file.store_8(1)         # 0 throttle + 1 offset
			_file.store_float(0.0)

		# --- artillery controller ---------------------------------------------
		if ship.artillery_controller:
			var ap: Vector3 = ship.artillery_controller.aim_point
			_file.store_float(ap.x)
			_file.store_float(ap.y)
			_file.store_float(ap.z)
			_file.store_float(ship.concealment.bloom_radius if ship.concealment else 0.0)
			_file.store_8(ship.artillery_controller.shell_index)
		else:
			_file.store_float(0.0)   # aim_point.x
			_file.store_float(0.0)   # aim_point.y
			_file.store_float(0.0)   # aim_point.z
			_file.store_float(0.0)   # bloom_radius
			_file.store_8(0)         # shell_index

		# --- fire mask (bit per zone, up to 8) --------------------------------
		var fire_mask: int = 0
		if ship.fire_manager:
			for fi in range(min(ship.fire_manager.fires.size(), 8)):
				if ship.fire_manager.fires[fi].lifetime > 0:
					fire_mask |= (1 << fi)
		_file.store_8(fire_mask)

		# --- flood mask (bit per zone, up to 8) -------------------------------
		var flood_mask: int = 0
		if ship.flood_manager:
			for fi in range(min(ship.flood_manager.floods.size(), 8)):
				if ship.flood_manager.floods[fi].lifetime > 0:
					flood_mask |= (1 << fi)
		_file.store_8(flood_mask)

		# --- consumable mask (bit per slot, up to 8) --------------------------
		var consumable_mask: int = 0
		if ship.consumable_manager:
			for item_id in ship.consumable_manager.active_effects.keys():
				if item_id < 8:
					consumable_mask |= (1 << item_id)
		_file.store_8(consumable_mask)

		# --- per-gun state ----------------------------------------------------
		if ship.artillery_controller:
			for gun in ship.artillery_controller.guns:
				if is_instance_valid(gun):
					_file.store_float(gun.rotation.y)
					_file.store_float(gun.barrel.rotation.x)
					_file.store_float(gun.reload)
				else:
					_file.store_float(0.0)
					_file.store_float(0.0)
					_file.store_float(0.0)

		# --- secondary gun state (v2: active flag + conditional per-gun transforms) ---
		# Only write per-gun data when the secondary controller is actively tracking;
		# otherwise a single 0-byte pass flag is written and the replay resets to base.
		var sec_active: bool = false
		if ship.secondary_controller:
			sec_active = ship.secondary_controller.active
		_file.store_8(1 if sec_active else 0)
		if sec_active and ship.secondary_controller:
			for sc in ship.secondary_controller.sub_controllers:
				for gun in sc.guns:
					if is_instance_valid(gun):
						_file.store_float(gun.rotation.y)
						_file.store_float(gun.barrel.rotation.x)
					else:
						_file.store_float(0.0)
						_file.store_float(0.0)

# ---------------------------------------------------------------------------
# Shell events
# ---------------------------------------------------------------------------
func record_shell_fired(
		ship: Ship,
		gun_index: int,
		muzzle_index: int,
		muzzle_pos: Vector3,
		velocity: Vector3,
		fire_ts: float,
		shell_params: ShellParams,
		shell_uid: int = 0) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.SHELL_FIRED)
	_file.store_8(_ship_to_id.get(ship, 255))
	_file.store_8(gun_index    if gun_index    >= 0 else 255)
	_file.store_8(muzzle_index if muzzle_index >= 0 else 0)
	# shell_type byte (v2): bit 0 = is_secondary, bit 1 = is_AP
	#   0 = primary HE,  1 = secondary HE,  2 = primary AP,  3 = secondary AP
	var _is_sec: int = 1 if (shell_params != null and shell_params._secondary) else 0
	var _is_ap:  int = 2 if (shell_params != null and shell_params.type == ShellParams.ShellType.AP) else 0
	_file.store_8(_is_sec | _is_ap)
	# muzzle world position
	_file.store_float(muzzle_pos.x)
	_file.store_float(muzzle_pos.y)
	_file.store_float(muzzle_pos.z)
	# launch velocity vector
	_file.store_float(velocity.x)
	_file.store_float(velocity.y)
	_file.store_float(velocity.z)
	# fire_ts (ProjectileManager internal clock) intentionally NOT stored.
	# The preamble timestamp written by _write_preamble() is replay-relative wall
	# time and is all the replay system needs to reconstruct the trajectory.
	# Shell physics + visual params
	_file.store_float(shell_params.drag    if shell_params else 0.0)
	_file.store_float(shell_params.size    if shell_params else 1.0)
	_file.store_float(shell_params.caliber if shell_params else 0.0)
	_file.store_32(shell_uid)


func record_shell_hit(
		attacker: Ship,
		victim: Ship,
		hit_type: int,
		position: Vector3,
		shell_uid: int = 0) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.SHELL_HIT)
	_file.store_8(_ship_to_id.get(attacker, 255))
	_file.store_8(_ship_to_id.get(victim,   255))
	_file.store_8(hit_type)
	_file.store_float(position.x)
	_file.store_float(position.y)
	_file.store_float(position.z)
	_file.store_32(shell_uid)

# ---------------------------------------------------------------------------
# Shell damage event (v3)
# ---------------------------------------------------------------------------
## Recorded from Stats.record_hit() when a shell actually deals damage to a ship.
## Carries the data needed to drive replay-side stat counters (per-weapon damage,
## per-victim damage, hit-type flashes). Logically distinct from SHELL_HIT, which
## describes a visual termination point.
func record_shell_damage(
		attacker: Ship,
		victim: Ship,
		hit_type: int,
		damage: float,
		is_secondary: bool,
		position: Vector3) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.SHELL_DAMAGE)
	_file.store_8(_ship_to_id.get(attacker, 255))
	_file.store_8(_ship_to_id.get(victim,   255))
	_file.store_8(hit_type)
	_file.store_8(1 if is_secondary else 0)
	_file.store_float(damage)
	_file.store_float(position.x)
	_file.store_float(position.y)
	_file.store_float(position.z)

# ---------------------------------------------------------------------------
# Fire events
# ---------------------------------------------------------------------------
func record_fire_started(ship: Ship, zone_index: int, caused_by: Ship) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.FIRE_STARTED)
	_file.store_8(_ship_to_id.get(ship, 255))
	_file.store_8(zone_index if zone_index >= 0 else 0)
	_file.store_8(_ship_to_id.get(caused_by, 0xFF) if is_instance_valid(caused_by) else 0xFF)


func record_fire_ended(ship: Ship, zone_index: int) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.FIRE_ENDED)
	_file.store_8(_ship_to_id.get(ship, 255))
	_file.store_8(zone_index if zone_index >= 0 else 0)
	_file.store_8(0xFF)   # no "caused_by" for endings

# ---------------------------------------------------------------------------
# Flood events
# ---------------------------------------------------------------------------
func record_flood_started(ship: Ship, zone_index: int, caused_by: Ship) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.FLOOD_STARTED)
	_file.store_8(_ship_to_id.get(ship, 255))
	_file.store_8(zone_index if zone_index >= 0 else 0)
	_file.store_8(_ship_to_id.get(caused_by, 0xFF) if is_instance_valid(caused_by) else 0xFF)


func record_flood_ended(ship: Ship, zone_index: int) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.FLOOD_ENDED)
	_file.store_8(_ship_to_id.get(ship, 255))
	_file.store_8(zone_index if zone_index >= 0 else 0)
	_file.store_8(0xFF)

# ---------------------------------------------------------------------------
# Fire / flood per-tick damage events (v4)
# ---------------------------------------------------------------------------
## Recorded once per second from Fire.damage() / Flood.damage() with the
## actual damage applied that tick.  Lets the replay accumulate fire_damage
## and flood_damage totals (and total_damage) bidirectionally.
func record_fire_damage(attacker: Ship, victim: Ship, damage: float) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.FIRE_DAMAGE)
	_file.store_8(_ship_to_id.get(attacker, 255))
	_file.store_8(_ship_to_id.get(victim,   255))
	_file.store_float(damage)

func record_flood_damage(attacker: Ship, victim: Ship, damage: float) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.FLOOD_DAMAGE)
	_file.store_8(_ship_to_id.get(attacker, 255))
	_file.store_8(_ship_to_id.get(victim,   255))
	_file.store_float(damage)

# ---------------------------------------------------------------------------
# Consumable events  (connected via bind() in begin_match)
# ---------------------------------------------------------------------------
func _on_consumable_used(item: ConsumableItem, ship: Ship) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.CONSUMABLE_USED)
	_file.store_8(_ship_to_id.get(ship, 255))
	_file.store_8(item.id if item else 0)


func _on_consumable_ended(item: ConsumableItem, ship: Ship) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.CONSUMABLE_ENDED)
	_file.store_8(_ship_to_id.get(ship, 255))
	_file.store_8(item.id if item else 0)

# ---------------------------------------------------------------------------
# Kill-feed → SHIP_SUNK event
# ---------------------------------------------------------------------------
## Signal args (from hp_manager.gd):
##   kill_feed_event(sinker.ship_name, sinker.name, sinker_team, damage_type,
##                   ship.ship_name,   ship.name,   sunk_team)
## So sinker_player_name == sinker.name  (node / peer id)
##    sunk_player_name   == sunk.name    (node / peer id)
func _on_kill_feed_event(
		_sinker_ship_name: String,
		sinker_player_name: String,
		_sinker_team: int,
		damage_type: int,
		_sunk_ship_name: String,
		sunk_player_name: String,
		_sunk_team: int) -> void:
	if not _match_active or _file == null:
		return

	var victim: Ship = null
	var sinker: Ship = null
	for ship in _ships:
		if not is_instance_valid(ship):
			continue
		if ship.name == sunk_player_name:
			victim = ship
		if ship.name == sinker_player_name:
			sinker = ship

	_write_preamble(ReplayEvent.SHIP_SUNK)
	_file.store_8(_ship_to_id.get(victim, 255))
	_file.store_8(_ship_to_id.get(sinker, 255))
	_file.store_8(damage_type)
	if victim != null and is_instance_valid(victim):
		_file.store_float(victim.global_position.x)
		_file.store_float(victim.global_position.z)
		_file.store_float(victim.global_position.y)
	else:
		_file.store_float(0.0)
		_file.store_float(0.0)
		_file.store_float(0.0)

# ---------------------------------------------------------------------------
# Torpedo events  (called from TorpedoManager / torpedo scripts)
# ---------------------------------------------------------------------------
func record_torpedo_fired(
		ship: Ship,
		launcher_index: int,
		torpedo_id: int,
		start_pos: Vector3,
		direction: Vector3,
		fire_ts: float,
		params,
		range_m: float = 0.0) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.TORPEDO_FIRED)
	_file.store_8(_ship_to_id.get(ship, 255))
	_file.store_8(launcher_index)
	_file.store_16(torpedo_id)
	_file.store_float(start_pos.x)
	_file.store_float(start_pos.y)
	_file.store_float(start_pos.z)
	_file.store_float(direction.x)
	_file.store_float(direction.y)
	_file.store_float(direction.z)
	# fire_ts (ProjectileManager internal clock) intentionally NOT stored.
	# The preamble timestamp is sufficient for replay position reconstruction.
	_file.store_float(params.speed_knts      if params else 0.0)
	_file.store_float(params.damage          if params else 0.0)
	_file.store_float(range_m)
	_file.store_float(params.detection_range if params else 0.0)


func record_torpedo_armed(torpedo_id: int) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.TORPEDO_ARMED)
	_file.store_16(torpedo_id)


func record_torpedo_detected(torpedo_id: int) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.TORPEDO_DETECTED)
	_file.store_16(torpedo_id)


func record_torpedo_destroyed(torpedo_id: int, position: Vector3, hit_ship: Ship) -> void:
	if not _match_active or _file == null:
		return
	_write_preamble(ReplayEvent.TORPEDO_DESTROYED)
	_file.store_16(torpedo_id)
	_file.store_float(position.x)
	_file.store_float(position.y)
	_file.store_float(position.z)
	_file.store_8(_ship_to_id.get(hit_ship, 0xFF) if is_instance_valid(hit_ship) else 0xFF)

# ---------------------------------------------------------------------------
# Match end
# ---------------------------------------------------------------------------
func _on_match_ended(winning_team: int) -> void:
	end_match(winning_team)


func end_match(winning_team: int) -> void:
	if not _match_active or _file == null:
		return
	_match_active = false

	# --- MATCH_END event --------------------------------------------------
	_write_preamble(ReplayEvent.MATCH_END)
	_file.store_8(winning_team)

	var duration_s: int = int(_current_time())
	_file.store_16(min(duration_s, 65535))  # u16 duration in seconds

	# Per-ship final stats
	for ship in _ships:
		_file.store_8(_ship_to_id.get(ship, 255))
		if is_instance_valid(ship) and ship.stats != null:
			_file.store_float(ship.stats.total_damage)
			_file.store_float(ship.stats.main_damage)
			_file.store_float(ship.stats.torpedo_damage)
			_file.store_float(ship.stats.fire_damage)
			_file.store_float(ship.stats.flood_damage)
			_file.store_32(ship.stats.frags)
			_file.store_32(ship.stats.main_hits)
			_file.store_32(ship.stats.citadel_count)
			_file.store_32(ship.stats.penetration_count)
			_file.store_32(ship.stats.overpen_count)
		else:
			for _i in range(5):     # 5 damage floats
				_file.store_float(0.0)
			for _i in range(5):     # 5 hit/frag counters
				_file.store_32(0)

	# --- snapshot index block at EOF --------------------------------------
	var index_offset: int = _file.get_position()
	_file.store_32(_snapshot_index.size())
	for entry in _snapshot_index:
		_file.store_float(entry["timestamp"])
		_file.store_64(entry["offset"])

	# Patch the index_offset placeholder in the header (byte offset 13)
	_file.seek(13)
	_file.store_32(index_offset)

	_file.close()
	_file = null

	# Close the armor sim companion log.
	if is_instance_valid(ArmorSimLogger):
		ArmorSimLogger.end_log()

	# --- disconnect signals -----------------------------------------------
	if _Utils.kill_feed_event.is_connected(_on_kill_feed_event):
		_Utils.kill_feed_event.disconnect(_on_kill_feed_event)
	if _Utils.match_ended.is_connected(_on_match_ended):
		_Utils.match_ended.disconnect(_on_match_ended)

	# --- reset state ------------------------------------------------------
	_ships          = []
	_ship_to_id     = {}
	_ship_gun_counts = []
	_snapshot_index = []
	_prev_detection = {}
	_prev_visible   = {}
