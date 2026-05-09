class_name ShellReplayer
extends Node3D

## Manages shell projectile visuals, muzzle effects, water splashes, and gun
## audio during replay playback.  ReplayPlayback adds this as a child node and
## calls update_shells() every frame.
##
## Shell positions are tracked via GPUProjectileRenderer (the same GPU-instanced
## quad shader used by the live game).  Effects and audio reuse the same
## HitEffects autoload and AudioStreamPlayer3D pattern as the live client.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

## If a shell is spawned within this many seconds of its recorded event
## timestamp it is considered a "fresh" spawn (normal forward playback).
## Only fresh spawns emit muzzle effects and gun audio — seek restores skip them.
const MUZZLE_EFFECT_THRESHOLD: float = 0.5

# _ProjectileManager C++ RPC enum — written by destroy_bullet_rpc into every
# SHELL_HIT event.  Must stay in sync with the enum in projectile_manager.h.
const HIT_PENETRATION:    int = 0
const HIT_RICOCHET:       int = 1
const HIT_OVERPENETRATION:int = 2
const HIT_SHATTER:        int = 3
const HIT_NOHIT:          int = 4
const HIT_CITADEL:        int = 5
const HIT_WATER:          int = 6

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## Active shell entries keyed by shell_id (int → Dictionary).
## Each entry:
##   event        : Dictionary  – original SHELL_FIRED event dict
##   shell_params : ShellParams – pre-built params (drag / vt / tau)
##   slot_id      : int         – GPUProjectileRenderer slot (-1 if alloc failed)
##   was_alive    : bool        – used to detect the first dead frame for splash
var _active_shells: Dictionary = {}

## GPU renderer child — owns the quad-mesh instanced rendering.
var _gpu_renderer: GPUProjectileRenderer = null

## GhostShip array (indexed by ship_id) — set by match_replay.gd before play().
## Used to look up the Gun node for audio parameters.
var ghost_ships: Array = []

# ---------------------------------------------------------------------------
# Godot callbacks
# ---------------------------------------------------------------------------

func _ready() -> void:
	_gpu_renderer = GPUProjectileRenderer.new()
	add_child(_gpu_renderer)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Spawn a shell visual from a SHELL_FIRED event dictionary.
## current_replay_time is the playback cursor when the event is processed;
## it equals event["timestamp"] during normal forward playback but is greater
## after a seek (in which case muzzle effects and audio are suppressed).
func spawn_shell(event: Dictionary, current_replay_time: float) -> void:
	var shell_uid: int  = event.get("shell_uid", -1)
	var event_ts: float = event.get("timestamp", 0.0)
	var is_fresh: bool  = (current_replay_time - event_ts) < MUZZLE_EFFECT_THRESHOLD

	var shell_size: float   = event.get("size",        1.0)
	var shell_type: int     = event.get("shell_type",  0)
	var drag:       float   = event.get("drag",       0.001)
	var muzzle_pos: Vector3 = event.get("muzzle_pos", Vector3.ZERO)
	var vel:        Vector3 = event.get("velocity",   Vector3.ZERO)

	# Colours distinguish battery type; size comes directly from ShellParams.size.
	var color: Color
	if shell_type == 0:
		color = Color(2.0, 1.5, 0.5, 1.0)   # main battery — warm yellow-orange glow
	else:
		color = Color(1.2, 1.0, 0.4, 1.0)   # secondary — dimmer

	# Allocate a GPU renderer slot.
	var slot_id: int = -1
	if _gpu_renderer != null:
		slot_id = _gpu_renderer.fire_shell(muzzle_pos, vel, drag, shell_size, shell_type, color)

	# One-shot muzzle effects and audio only on fresh spawns.
	if is_fresh:
		_emit_muzzle_effects(event)
		_play_gun_sound(event)

	var entry := {
		"event"        : event,
		"shell_params" : ReplayBallistics.make_shell_params(drag),
		"slot_id"      : slot_id,
	}

	if shell_uid > 0:
		_active_shells[shell_uid] = entry
	else:
		# Fallback for shells without a UID (should not occur with current recorder).
		var fallback_key: int = -(hash(event) & 0x7FFFFFFF) - 1
		_active_shells[fallback_key] = entry


## Called by ReplayPlayback when a SHELL_HIT event is dispatched.
## Finds the shell by its recorded shell_id, removes it from the active set,
## destroys its GPU slot, and emits the correct hit effects.
func on_shell_hit(ev: Dictionary) -> void:
	var shell_uid: int   = ev.get("shell_uid", -1)
	var hit_pos: Vector3 = ev.get("hit_pos", Vector3.ZERO)
	var hit_type: int    = ev.get("hit_type", HIT_PENETRATION)

	# Find the entry — prefer exact ID match, fall back to proximity search
	# for shells fired without a recorded ID.
	var entry = null
	if shell_uid > 0 and _active_shells.has(shell_uid):
		entry = _active_shells[shell_uid]
		_active_shells.erase(shell_uid)

	# Destroy GPU slot.
	if entry != null:
		var slot_id: int = entry.get("slot_id", -1)
		if slot_id >= 0 and _gpu_renderer != null:
			_gpu_renderer.destroy_shell(slot_id)

	# Emit hit effects using the shell's recorded size (same as live game radius).
	if not is_instance_valid(HitEffects):
		return
	var radius: float = 1.0
	if entry != null:
		radius = entry.event.get("size", 1.0)

	match hit_type:
		HIT_WATER:          # 6
			HitEffects.splash_effect(Vector3(hit_pos.x, 0.0, hit_pos.z), radius)
		HIT_CITADEL:        # 5
			HitEffects.he_explosion_effect(hit_pos, radius * 1.2, Vector3.UP)
			HitEffects.sparks_effect(hit_pos, radius * 0.6, Vector3.UP)
		HIT_RICOCHET, HIT_OVERPENETRATION, HIT_SHATTER:  # 1, 2, 3
			HitEffects.sparks_effect(hit_pos, radius * 0.5, Vector3.UP)
		HIT_NOHIT:          # 4 — friendly fire, excluded ships: no visual effect
			pass
		_:                  # PENETRATION = 0
			HitEffects.he_explosion_effect(hit_pos, radius * 0.8, Vector3.UP)
			HitEffects.sparks_effect(hit_pos, radius * 0.5, Vector3.UP)


## Update every active shell to its analytically-computed position.
## Shells whose ballistic arc has ended are silently removed — all hit effects
## (splash, explosion, sparks) are driven exclusively by on_shell_hit() via
## the SHELL_HIT event stream.  No fallback effects are emitted here.
## Called every frame by ReplayPlayback._process().
func update_shells(current_time: float) -> void:
	var to_remove: Array = []

	for shell_id in _active_shells:
		var shell_entry: Dictionary = _active_shells[shell_id]
		var event:  Dictionary = shell_entry.event
		var params: ShellParams = shell_entry.shell_params
		var slot_id: int        = shell_entry.slot_id

		var muzzle:  Vector3 = event.get("muzzle_pos", Vector3.ZERO)
		var vel:     Vector3 = event.get("velocity",   Vector3.ZERO)
		var fire_ts: float   = event.get("timestamp",  0.0)

		if not ReplayBallistics.is_shell_alive(muzzle, vel, params, fire_ts, current_time):
			# Shell crossed the waterline or exceeded max flight time.
			# Destroy the GPU slot silently — no effect emitted here.
			if slot_id >= 0 and _gpu_renderer != null:
				_gpu_renderer.destroy_shell(slot_id)
			to_remove.append(shell_id)
			continue

		var t_real: float = current_time - fire_ts
		var pos: Vector3  = ReplayBallistics.position_at(muzzle, vel, params, t_real)

		if slot_id >= 0 and _gpu_renderer != null:
			_gpu_renderer.update_shell_position(slot_id, pos)

	for key in to_remove:
		_active_shells.erase(key)


## Immediately destroy every active shell visual.
## Called by ReplayPlayback on seek or scene teardown.
func clear_all() -> void:
	for shell_id in _active_shells:
		var slot_id: int = _active_shells[shell_id].get("slot_id", -1)
		if slot_id >= 0 and _gpu_renderer != null:
			_gpu_renderer.destroy_shell(slot_id)
	_active_shells.clear()

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Emit muzzle blast particles and a surface wake disc at the muzzle position.
func _emit_muzzle_effects(event: Dictionary) -> void:
	if not is_instance_valid(HitEffects):
		return

	var muzzle_pos: Vector3 = event.get("muzzle_pos", Vector3.ZERO)
	var vel:        Vector3 = event.get("velocity",   Vector3.ZERO)
	var shell_size: float   = event.get("size",        1.0)

	# Muzzle blast — direction derived from launch velocity.
	# The live C++ passes size * size to muzzle_blast_effect.
	if vel.length_squared() > 0.001:
		var dir: Vector3 = vel.normalized()
		var up_ref: Vector3 = Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP
		var fire_basis: Basis = Basis.looking_at(dir, up_ref)
		HitEffects.muzzle_blast_effect(muzzle_pos, fire_basis, shell_size * shell_size)

	# Wake disc on the water surface at the muzzle position.
	if HitEffects.wake_template != null:
		var wake_size: float  = shell_size ** 2 * 2.0
		var dir_flat: Vector3 = Vector3(vel.x, 0.0, vel.z)
		var wake_pos: Vector3 = Vector3(muzzle_pos.x, 0.01, muzzle_pos.z)
		if dir_flat.length_squared() > 0.001:
			wake_pos += dir_flat.normalized() * wake_size * 0.5
		var time_mod: float = lerpf(3.0, 1.2, wake_size / 50.0)
		HitEffects.wake_template.emit(wake_pos, dir_flat, wake_size, 1, time_mod)


## Create an ephemeral AudioStreamPlayer3D at the muzzle position using the
## Gun node's own exported audio properties (_sound, pitch, volume, variance).
func _play_gun_sound(event: Dictionary) -> void:
	var ship_id:   int = event.get("ship_id",   -1)
	var gun_index: int = event.get("gun_index",  0)

	if ship_id < 0 or ship_id >= ghost_ships.size():
		return
	var gs = ghost_ships[ship_id]
	if gs == null or not is_instance_valid(gs):
		return
	if gun_index < 0 or gun_index >= gs._gun_pivots.size():
		return
	var gun = gs._gun_pivots[gun_index]
	if not is_instance_valid(gun):
		return

	var caliber:    float   = event.get("caliber",    100.0)
	var muzzle_pos: Vector3 = event.get("muzzle_pos", Vector3.ZERO)

	var player := AudioStreamPlayer3D.new()
	player.stream = gun._sound if gun._sound != null \
			else preload("res://audio/explosion1.wav")
	player.max_polyphony = 4
	player.unit_size  = 100.0 * sqrt(caliber / 100.0) + 100.0
	player.max_db     = linear_to_db(gun.volume * (1.0 + gun.variance))
	player.pitch_scale = gun.pitch  * randf_range(1.0 - gun.variance, 1.0 + gun.variance)
	player.volume_db  = linear_to_db(gun.volume * randf_range(1.0 - gun.variance, 1.0 + gun.variance))
	player.bus        = "Main"
	add_child(player)
	player.global_position = muzzle_pos
	player.play()
	player.finished.connect(player.queue_free)
