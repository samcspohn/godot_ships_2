class_name ReplayPlayback
extends Node

## Central time-keeping and state-machine for match replay.
##
## Lifecycle (called by the viewer scene):
##   1. load_replay(path)        – parse the .replay file
##   2. setup_ghost_ships(ships) – hand in pre-built GhostShip array
##   3. play() / pause() / seek(t) / set_speed(s) as needed
##
## _process() drives snapshot interpolation, event dispatch, and projectile updates.
##
## Depends on:
##   ReplayFileReader  (Phase 3) – binary file parser
##   ReplayEvent       (Phase 1) – event-type constants
##   GhostShip         (Phase 4) – visual-only ship node
##   ShellReplayer     (Phase 5) – this file set
##   TorpedoReplayer   (Phase 5) – this file set
##   ReplayBallistics  (Phase 5) – analytical ballistics helper

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted every frame while playing (and on seek) with the new replay time.
signal time_changed(new_time: float)

## Emitted each time a discrete event is dispatched (for the UI kill-feed etc.).
signal event_fired(event: Dictionary)

## Emitted when playback reaches the end of the recording (or MATCH_END fires).
signal playback_ended()

## Emitted once after load_replay() succeeds.
signal replay_loaded()

## Emitted at the end of seek() with the new current_time. Listeners that
## maintain event-derived state (e.g. ReplayStatsAccumulator) use this to
## reset and rebuild from t=0..new_time, since seek() does NOT re-emit
## events through event_fired.
signal seek_jumped(new_time: float)

# ---------------------------------------------------------------------------
# Public state
# ---------------------------------------------------------------------------

## The parsed replay file.  Null until load_replay() succeeds.
var reader: ReplayFileReader = null

## GhostShip nodes indexed by ship_id.  Populated by setup_ghost_ships().
var ghost_ships: Array = []

## Optional ShellReplayer child – assign before calling play()/seek().
var shell_replayer: ShellReplayer = null

## Optional TorpedoReplayer child – assign before calling play()/seek().
var torpedo_replayer: TorpedoReplayer = null

## Optional ArmorTrailVisualizer – set by match_replay.gd after scene setup.
var armor_trail_visualizer = null   ## ArmorTrailVisualizer

## Current playback cursor in seconds since match start.
var current_time: float = 0.0

## Whether the engine is advancing current_time each frame.
var is_playing: bool = false

## Playback rate multiplier.  Supported values: 0.25, 0.5, 1.0, 2.0, 4.0, 8.0.
var playback_speed: float = 1.0

# ---------------------------------------------------------------------------
# Private snapshot interpolation state
# ---------------------------------------------------------------------------

## ship_id → ship_data Dictionary for the snapshot at or just before current_time.
var _snap_a: Dictionary = {}

## ship_id → ship_data Dictionary for the snapshot just after current_time.
var _snap_b: Dictionary = {}

## Replay timestamp of _snap_a (seconds).
var _snap_a_time: float = 0.0

## Replay timestamp of _snap_b (seconds).
var _snap_b_time: float = 0.2

## Discrete events whose timestamp falls in (_snap_a_time, _snap_b_time] that
## have not yet been dispatched.
var _pending_events: Array = []

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## How far back to scan for in-flight shells/torpedoes when seeking.
## 60 s covers even the longest realistic shell trajectories.
const _LOOKBACK_SECONDS: float = 60.0

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Load a .replay file from disk and prime the snapshot window.
## Returns OK on success or a non-zero Error code.
## Ghost ships are NOT created here; call setup_ghost_ships() afterwards.
func load_replay(path: String) -> Error:
	reader = ReplayFileReader.new()
	var err: Error = reader.load_file(path)
	if err != OK:
		push_error("ReplayPlayback: failed to load '%s' (error %d)" % [path, err])
		reader = null
		return err

	# Prime the initial snapshot window at t = 0.
	_snap_a      = reader.read_snapshot_at(0.0)
	_snap_b      = reader.get_snapshot_after(0.0)
	_snap_a_time = 0.0
	_snap_b_time = _snap_b_time_from_index(0) if not reader.snapshot_index.is_empty() else 0.2

	_pending_events = reader.read_events_in_range(0.0, _snap_b_time)

	current_time = 0.0
	replay_loaded.emit()
	return OK


## Register the GhostShip array (indexed by ship_id) and apply the initial
## snapshot so the ships appear at their t=0 positions immediately.
func setup_ghost_ships(ships: Array) -> void:
	ghost_ships = ships
	if _snap_a.is_empty():
		return
	for ship_id in _snap_a:
		_apply_snap_to_ghost(ship_id, _snap_a[ship_id])


## Jump to replay time t and rebuild all interpolation / in-flight projectile state.
func seek(t: float) -> void:
	if reader == null:
		return

	_begin_seeking()

	t = clampf(t, 0.0, reader.total_duration)
	current_time = t

	# ---- Snapshot window around t ----
	_snap_a = reader.read_snapshot_at(t)
	_snap_b = reader.get_snapshot_after(t)

	var snap_idx: int = _find_snapshot_index(t)
	_snap_a_time = reader.snapshot_index[snap_idx].timestamp \
		if snap_idx >= 0 and snap_idx < reader.snapshot_index.size() \
		else 0.0
	_snap_b_time = reader.snapshot_index[snap_idx + 1].timestamp \
		if snap_idx + 1 < reader.snapshot_index.size() \
		else _snap_a_time + 0.2

	# ---- Apply snapshot to every ghost ship ----
	for ship_id in _snap_a:
		_apply_snap_to_ghost(ship_id, _snap_a[ship_id])
		if not _snap_b.is_empty() and _snap_b.has(ship_id):
			_set_interp_targets(ship_id, _snap_a[ship_id], _snap_b[ship_id])

	# ---- Reload pending events (only those still in the future) ----
	_pending_events = reader.read_events_in_range(_snap_a_time, _snap_b_time)
	_pending_events = _pending_events.filter(
		func(e: Dictionary) -> bool:
			return e.get("timestamp", 0.0) > t
	)

	# ---- Reload in-flight shells and torpedoes ----
	if shell_replayer != null:
		shell_replayer.clear_all()
	if torpedo_replayer != null:
		torpedo_replayer.clear_all()

	var lookback_start: float = maxf(0.0, t - _LOOKBACK_SECONDS)
	var past_events: Array    = reader.read_events_in_range(lookback_start, t)

	# Build a set of torpedo_ids that were destroyed before t.
	var destroyed_torp_ids: Dictionary = {}
	for ev in past_events:
		if ev.get("type") == ReplayEvent.TORPEDO_DESTROYED:
			destroyed_torp_ids[ev.get("torpedo_id", -1)] = true

	# Build a set of shell UIDs that have already hit something before t.
	# UIDs are globally unique (never reused), so a simple set is correct.
	var hit_shell_uids: Dictionary = {}
	for ev in past_events:
		if ev.get("type") == ReplayEvent.SHELL_HIT:
			var uid: int = ev.get("shell_uid", -1)
			if uid > 0:
				hit_shell_uids[uid] = true

	for ev in past_events:
		var ev_type: int = ev.get("type", -1)
		match ev_type:
			ReplayEvent.SHELL_FIRED:
				if shell_replayer == null:
					continue
				# Skip shells whose unique UID was already hit before the seek point.
				var uid: int = ev.get("shell_uid", -1)
				if uid > 0 and hit_shell_uids.has(uid):
					continue
				# spawn_shell pre-builds the ShellParams, so is_shell_alive uses the
				# same params object afterwards.  Here we only need a transient one
				# to decide whether the shell is still alive at seek time t.
				var _params := ReplayBallistics.make_shell_params(ev.get("drag", 0.001))
				if ReplayBallistics.is_shell_alive(
						ev.get("muzzle_pos", Vector3.ZERO),
						ev.get("velocity",   Vector3.ZERO),
						_params,
						ev.get("timestamp",  0.0),
						t):
					shell_replayer.spawn_shell(ev, t)

			ReplayEvent.TORPEDO_FIRED:
				if torpedo_replayer == null:
					continue
				var tid: int = ev.get("torpedo_id", -1)
				if not destroyed_torp_ids.has(tid):
					torpedo_replayer.spawn_torpedo(ev)
					# Re-apply armed / detected state if those events already happened.
					for state_ev in past_events:
						match state_ev.get("type", -1):
							ReplayEvent.TORPEDO_ARMED:
								if state_ev.get("torpedo_id", -1) == tid:
									torpedo_replayer.mark_armed(tid)
							ReplayEvent.TORPEDO_DETECTED:
								if state_ev.get("torpedo_id", -1) == tid:
									torpedo_replayer.mark_detected(tid)

	time_changed.emit(t)
	seek_jumped.emit(t)

	# Defer the clear so the seeking flags stay hot through the first
	# _process() frame after seek — preventing emitter allocation on that frame.
	call_deferred("_end_seeking")


## Begin (or resume) playback.  If the cursor is at the end, rewind to 0 first.
func play() -> void:
	if reader == null:
		return
	if current_time >= reader.total_duration:
		seek(0.0)
	is_playing = true
	if armor_trail_visualizer != null:
		armor_trail_visualizer.is_playing = true


## Pause playback.
func pause() -> void:
	is_playing = false
	if armor_trail_visualizer != null:
		armor_trail_visualizer.is_playing = false


## Set the playback speed multiplier (0.25 – 8.0 typical).
func set_speed(s: float) -> void:
	playback_speed = s


## Return the total duration of the loaded replay, or 0 if no replay is loaded.
func get_duration() -> float:
	return reader.total_duration if reader != null else 0.0

# ---------------------------------------------------------------------------
# Godot callbacks
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not is_playing or reader == null:
		return

	current_time += delta * playback_speed

	# ---- End-of-replay guard ----
	if current_time >= reader.total_duration:
		current_time = reader.total_duration
		is_playing   = false
		playback_ended.emit()
		time_changed.emit(current_time)
		return

	# ---- Advance snapshot window if we have crossed into the next interval ----
	if current_time >= _snap_b_time:
		# Roll the window forward: B becomes the new A.
		_snap_a      = _snap_b
		_snap_a_time = _snap_b_time

		# Fetch the next snapshot.  Use _snap_a_time (the old B time) as the query.
		_snap_b = reader.get_snapshot_after(_snap_a_time)

		# Determine the next snapshot timestamp from the index for accuracy.
		# Fall back to a 0.2 s step if the index lookup fails.
		var found_idx: int = _find_snapshot_index(_snap_a_time)
		if found_idx >= 0 and found_idx + 1 < reader.snapshot_index.size():
			_snap_b_time = reader.snapshot_index[found_idx + 1].timestamp
		else:
			_snap_b_time = _snap_a_time + 0.2

		# If there are no more snapshots, let the end-of-replay guard handle it.
		if _snap_b.is_empty():
			is_playing = false
			playback_ended.emit()
			time_changed.emit(current_time)
			return

		# Apply the new A snapshot to every ghost ship and set interpolation targets.
		for ship_id in _snap_a:
			_apply_snap_to_ghost(ship_id, _snap_a[ship_id])
			if _snap_b.has(ship_id):
				_set_interp_targets(ship_id, _snap_a[ship_id], _snap_b[ship_id])

		# Load discrete events for the new interval and APPEND to any events
		# from the old window that were not yet dispatched.  Replacing here
		# would silently drop events whose timestamp fell just above the
		# previous frame's current_time but below _snap_b_time — exactly
		# the condition that causes consistent whole-salvo misses.
		# The two ranges are [old_snap_a, old_snap_b) and [old_snap_b, new_snap_b)
		# so there is no overlap and no risk of duplicate dispatch.
		var _new_events: Array = reader.read_events_in_range(_snap_a_time, _snap_b_time)
		_pending_events.append_array(_new_events)

	# ---- Dispatch pending events whose timestamps have been reached ----
	var still_pending: Array = []
	for ev in _pending_events:
		if ev.get("timestamp", 0.0) <= current_time:
			_handle_event(ev)
			event_fired.emit(ev)
		else:
			still_pending.append(ev)
	_pending_events = still_pending

	# ---- Interpolate ghost ships ----
	var range_size: float = _snap_b_time - _snap_a_time
	var alpha: float = 0.0
	if range_size > 0.001:
		alpha = clampf((current_time - _snap_a_time) / range_size, 0.0, 1.0)

	for ship in ghost_ships:
		if ship != null and is_instance_valid(ship):
			ship.advance_interpolation(alpha)

	# ---- Update projectile visuals ----
	if shell_replayer != null:
		shell_replayer.update_shells(current_time)
	if torpedo_replayer != null:
		torpedo_replayer.update_torpedos(current_time)

	time_changed.emit(current_time)

# ---------------------------------------------------------------------------
# Event dispatch
# ---------------------------------------------------------------------------

func _handle_event(ev: Dictionary) -> void:
	var ev_type: int = ev.get("type", -1)
	match ev_type:
		ReplayEvent.SHELL_FIRED:
			if shell_replayer != null:
				shell_replayer.spawn_shell(ev, current_time)

		ReplayEvent.TORPEDO_FIRED:
			if torpedo_replayer != null:
				torpedo_replayer.spawn_torpedo(ev)

		ReplayEvent.TORPEDO_ARMED:
			if torpedo_replayer != null:
				torpedo_replayer.mark_armed(ev.get("torpedo_id", -1))

		ReplayEvent.TORPEDO_DETECTED:
			if torpedo_replayer != null:
				torpedo_replayer.mark_detected(ev.get("torpedo_id", -1))

		ReplayEvent.TORPEDO_DESTROYED:
			if torpedo_replayer != null:
				torpedo_replayer.destroy_torpedo(
					ev.get("torpedo_id", -1),
					ev.get("pos", Vector3.ZERO)   # reader writes "pos", not "position"
				)

		ReplayEvent.FIRE_STARTED:
			# Fire/flood state is carried in the snapshot mask and applied via
			# apply_snapshot() each time the window advances.  Nothing extra needed
			# unless a future GhostShip version exposes an instant-set API.
			pass

		ReplayEvent.FIRE_ENDED:
			pass   # handled by snapshot mask

		ReplayEvent.FLOOD_STARTED:
			pass   # handled by snapshot mask

		ReplayEvent.FLOOD_ENDED:
			pass   # handled by snapshot mask

		ReplayEvent.SHELL_HIT:
			if shell_replayer != null:
				shell_replayer.on_shell_hit(ev)
			if armor_trail_visualizer != null:
				armor_trail_visualizer.on_shell_hit(ev)

		ReplayEvent.SHIP_SUNK:
			var ship_id: int = ev.get("victim_ship_id", -1)
			if ship_id >= 0 and ship_id < ghost_ships.size():
				var gs = ghost_ships[ship_id]
				if gs != null and is_instance_valid(gs):
					gs.start_sinking()
					if is_instance_valid(HitEffects):
						# Sizes match hp_manager.gd sink() / sink_c() exactly.
						HitEffects.he_explosion_effect(gs.global_position, 30.0, Vector3.UP)
						HitEffects.sparks_effect(gs.global_position, 20.0, Vector3.UP)

		ReplayEvent.MATCH_END:
			is_playing = false
			playback_ended.emit()

# ---------------------------------------------------------------------------
# Seek emitter management
# ---------------------------------------------------------------------------

## Freeze all spatial-displacement emitters before seek work begins.
## Called at the top of seek() so that re-spawned shells/torpedoes cannot
## start allocating new trails until the seek has fully settled.
func _begin_seeking() -> void:
	if shell_replayer != null:
		shell_replayer.is_seeking = true
	if torpedo_replayer != null:
		torpedo_replayer.is_seeking = true
	if armor_trail_visualizer != null:
		armor_trail_visualizer.is_seeking = true
		armor_trail_visualizer.on_begin_seek()
	for gs in ghost_ships:
		if is_instance_valid(gs):
			gs.freeze_particles()


## Re-enable emitter allocation and thaw ship particles.
## Called deferred (one frame after seek()) so the first post-seek _process()
## frame also skips emitter allocation, preventing a single-frame burst.
func _end_seeking() -> void:
	if shell_replayer != null:
		shell_replayer.is_seeking = false
	if torpedo_replayer != null:
		torpedo_replayer.is_seeking = false
	if armor_trail_visualizer != null:
		armor_trail_visualizer.is_seeking = false
		armor_trail_visualizer.on_end_seek()
		armor_trail_visualizer.is_playing = is_playing
	for gs in ghost_ships:
		if is_instance_valid(gs):
			gs.thaw_particles()


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Binary search: return the index of the last snapshot with timestamp <= t,
## or -1 if no such snapshot exists (t is before the first snapshot).
func _find_snapshot_index(t: float) -> int:
	if reader == null or reader.snapshot_index.is_empty():
		return -1
	var lo: int = 0
	var hi: int = reader.snapshot_index.size() - 1
	# Upper-bound variant: find rightmost index where timestamp <= t.
	while lo < hi:
		var mid: int = (lo + hi + 1) >> 1
		if reader.snapshot_index[mid].timestamp <= t:
			lo = mid
		else:
			hi = mid - 1
	return lo if reader.snapshot_index[lo].timestamp <= t else -1


## Return the timestamp of the snapshot AFTER index 0 (i.e. index 1), used
## to seed _snap_b_time on first load.
func _snap_b_time_from_index(a_idx: int) -> float:
	if reader == null or reader.snapshot_index.is_empty():
		return 0.2
	var next_idx: int = a_idx + 1
	if next_idx < reader.snapshot_index.size():
		return reader.snapshot_index[next_idx].timestamp
	return reader.snapshot_index[a_idx].timestamp + 0.2


## Apply a snapshot data dict to the GhostShip at ship_id (bounds-checked).
func _apply_snap_to_ghost(ship_id: int, snap_data: Dictionary) -> void:
	if ship_id < 0 or ship_id >= ghost_ships.size():
		return
	var gs = ghost_ships[ship_id]
	if gs != null and is_instance_valid(gs):
		gs.apply_snapshot(snap_data)


## Set interpolation targets on the GhostShip at ship_id (bounds-checked).
func _set_interp_targets(ship_id: int, from_data: Dictionary, to_data: Dictionary) -> void:
	if ship_id < 0 or ship_id >= ghost_ships.size():
		return
	var gs = ghost_ships[ship_id]
	if gs != null and is_instance_valid(gs):
		gs.set_interpolation_targets(from_data, to_data)
