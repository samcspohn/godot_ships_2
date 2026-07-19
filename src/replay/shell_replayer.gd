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

## Minimum distance from muzzle before a trail emitter is allocated.
## Mirrors the 15-unit threshold used in _ProjectileManager::_process_trails_only.
const TRAIL_START_DIST_SQ: float = 15.0 * 15.0

## Shell trail particle template — same resource the live game uses.
var _trail_template: ParticleTemplate = preload("res://assets/particles/templates/shell_trail_template.tres")

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

## Cached template_id from UnifiedParticleSystem (set in _ready).
var _trail_template_id: int = -1

## When true, skip GPU trail emitter allocation.
## Set by ReplayPlayback during seek to prevent spurious trails from shells
## that were re-spawned mid-flight and would otherwise start a trail from
## their current position before seek animation has settled.
var is_seeking: bool = false

## GhostShip array (indexed by ship_id) — set by match_replay.gd before play().
## Used to look up the Gun node for audio parameters.
var ghost_ships: Array = []

# ---------------------------------------------------------------------------
# Godot callbacks
# ---------------------------------------------------------------------------

func _ready() -> void:
	_gpu_renderer = GPUProjectileRenderer.new()
	add_child(_gpu_renderer)

	# Register the shell trail template with the GPU particle system so that
	# allocate_emitter calls below have a valid template_id.
	if is_instance_valid(UnifiedParticleSystem) and _trail_template != null:
		_trail_template_id = UnifiedParticleSystem.ensure_template_registered(_trail_template)

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

	# shell_type byte (v2): bit 0 = is_secondary, bit 1 = is_AP
	#   0 = primary HE,  1 = secondary HE,  2 = primary AP,  3 = secondary AP
	# (v1 files: 0 = primary, 1 = secondary — both treated as HE for color)
	var _is_secondary: bool = (shell_type & 1) != 0
	var _is_ap:        bool = (shell_type & 2) != 0

	# GPU renderer expects raw ShellType: 0 = HE, 1 = AP (same as ShellParams.ShellType enum).
	# Never pass the packed replay byte — values 2/3 are undefined to the shader.
	var gpu_shell_type: int = 1 if _is_ap else 0

	# Colours match fire_bullet_client() in projectile_manager.cpp exactly.
	# Secondary battery is slightly dimmed so it reads as a distinct tier.
	var color: Color
	if _is_ap:
		color = Color(0.05, 0.1, 1.0, 1.0) if not _is_secondary else Color(0.04, 0.08, 0.8, 1.0)
	else:
		color = Color(1.0, 0.2, 0.05, 1.0) if not _is_secondary else Color(0.8, 0.16, 0.04, 1.0)

	# Allocate a GPU renderer slot.
	var slot_id: int = -1
	if _gpu_renderer != null:
		slot_id = _gpu_renderer.fire_shell(muzzle_pos, vel, drag, shell_size, gpu_shell_type, color)

	# One-shot muzzle effects and audio only on fresh spawns.
	if is_fresh:
		_emit_muzzle_effects(event)
		_play_gun_sound(event)

	var entry := {
		"event"        : event,
		"shell_params" : ReplayBallistics.make_shell_params(drag),
		"slot_id"      : slot_id,
		"emitter_id"   : -1,	# GPU trail emitter; allocated lazily after shell leaves muzzle
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

	# Destroy GPU slot and trail emitter.
	if entry != null:
		var slot_id: int = entry.get("slot_id", -1)
		if slot_id >= 0 and _gpu_renderer != null:
			_gpu_renderer.destroy_shell(slot_id)
		var emitter_id: int = entry.get("emitter_id", -1)
		if emitter_id >= 0 and is_instance_valid(UnifiedParticleSystem):
			UnifiedParticleSystem.free_emitter(emitter_id)

	# Emit hit effects using the shell's recorded size (same as live game radius).
	if not is_instance_valid(HitEffects):
		return
	var radius: float = 1.0
	if entry != null:
		radius = entry.event.get("size", 1.0)

	match hit_type:
		HIT_WATER:          # 6
			HitEffects.splash_effect(Vector3(hit_pos.x, 0.0, hit_pos.z), radius)
			_play_impact_sound(hit_pos, radius, 1.5 / (radius * 0.4), radius / 12.0 / 10.0)
		HIT_CITADEL:        # 5
			HitEffects.he_explosion_effect(hit_pos, radius * 1.2, Vector3.UP)
			HitEffects.sparks_effect(hit_pos, radius * 0.6, Vector3.UP)
			_play_impact_sound(hit_pos, radius, 1.0 / (radius * 0.45), radius / 4.0 / 10.0)
		HIT_RICOCHET, HIT_OVERPENETRATION, HIT_SHATTER:  # 1, 2, 3
			HitEffects.sparks_effect(hit_pos, radius * 0.5, Vector3.UP)
			_play_impact_sound(hit_pos, radius, 2.0 / (radius * 0.4), (0.1 + radius / 15.0) / 15.0)
		HIT_NOHIT:          # 4 — friendly fire, excluded ships: no visual effect
			pass
		_:                  # PENETRATION = 0
			HitEffects.he_explosion_effect(hit_pos, radius * 0.8, Vector3.UP)
			HitEffects.sparks_effect(hit_pos, radius * 0.5, Vector3.UP)
			_play_impact_sound(hit_pos, radius, 1.3 / (radius * 0.4), radius / 8.0 / 10.0)


## Update every active shell to its analytically-computed position.
## Shells whose ballistic arc has ended are silently removed — all hit effects
## (splash, explosion, sparks) are driven exclusively by on_shell_hit() via
## the SHELL_HIT event stream.  No fallback effects are emitted here.
## Called every frame by ReplayPlayback._process().
func update_shells(current_time: float) -> void:
	for shell_id in _active_shells:
		var shell_entry: Dictionary = _active_shells[shell_id]
		var event:  Dictionary = shell_entry.event
		var params: ShellParams = shell_entry.shell_params
		var slot_id: int        = shell_entry.slot_id

		var muzzle:  Vector3 = event.get("muzzle_pos", Vector3.ZERO)
		var vel:     Vector3 = event.get("velocity",   Vector3.ZERO)
		var fire_ts: float   = event.get("timestamp",  0.0)

		# Stop updating position once the shell is no longer in the air,
		# but keep the entry alive so on_shell_hit() can read the correct
		# size when the SHELL_HIT event fires.  Silently removing shells here
		# would race against the event stream and leave on_shell_hit() with
		# entry == null, causing all hit effects to use the wrong radius.
		if not ReplayBallistics.is_shell_alive(muzzle, vel, params, fire_ts, current_time):
			continue

		var t_real: float = current_time - fire_ts
		var pos: Vector3  = ReplayBallistics.position_at(muzzle, vel, params, t_real)

		if slot_id >= 0 and _gpu_renderer != null:
			_gpu_renderer.update_shell_position(slot_id, pos)

		# ---------- trail emitter ----------
		if not is_seeking and is_instance_valid(UnifiedParticleSystem) and _trail_template_id >= 0:
			var emitter_id: int = shell_entry.get("emitter_id", -1)
			if emitter_id < 0:
				# Allocate lazily once the shell has left the muzzle area.
				# Mirrors the 15-unit threshold in _ProjectileManager::_process_trails_only.
				if (pos - muzzle).length_squared() > TRAIL_START_DIST_SQ:
					var shell_size: float = event.get("size", 1.0)
					var width_scale: float = shell_size * 0.9
					emitter_id = UnifiedParticleSystem.allocate_emitter(
						_trail_template_id, pos, width_scale, 0.05, 1.0, 0.0)
					shell_entry["emitter_id"] = emitter_id
					_active_shells[shell_id] = shell_entry
			# Update existing emitter position every frame.
			if emitter_id >= 0:
				UnifiedParticleSystem.update_emitter_position(emitter_id, pos)


## Immediately destroy every active shell visual and trail emitter.
## Called by ReplayPlayback on seek or scene teardown.
func clear_all() -> void:
	for shell_id in _active_shells:
		var entry: Dictionary = _active_shells[shell_id]
		var slot_id: int = entry.get("slot_id", -1)
		if slot_id >= 0 and _gpu_renderer != null:
			_gpu_renderer.destroy_shell(slot_id)
		var emitter_id: int = entry.get("emitter_id", -1)
		if emitter_id >= 0 and is_instance_valid(UnifiedParticleSystem):
			UnifiedParticleSystem.free_emitter(emitter_id)
	_active_shells.clear()

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Play an impact/explosion sound at world position pos.
## Creates an AudioStreamPlayer3D directly in this node (inside the SubViewport)
## so it is spatialized by the replay camera's AudioListener3D.
## Pitch and volume formulas mirror destroy_bullet_rpc2() in projectile_manager.cpp.
func _play_impact_sound(pos: Vector3, _radius: float, pitch: float, volume: float) -> void:
	var stream: AudioStream = null
	if is_instance_valid(SoundEffectManager):
		stream = SoundEffectManager.get("explosion") as AudioStream
	if stream == null:
		return

	var player := AudioStreamPlayer3D.new()
	player.stream       = stream
	player.unit_size    = 1500.0           # matches sound_effect_pool.gd
	player.pitch_scale  = pitch * 3.0      # matches sound_effect_pool.gd scale
	player.volume_linear = volume * 1.5    # matches sound_effect_pool.gd scale
	player.bus          = "Main"
	add_child(player)
	player.global_position = pos
	player.play()
	player.finished.connect(player.queue_free)


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
		HitEffects.muzzle_blast_effect(muzzle_pos, fire_basis, shell_size )

	var wake_size: float = shell_size ** 2 * 2.0
	WaveManager.add_muzzle_blast(Vector3(muzzle_pos.x, 0.0, muzzle_pos.z), wake_size * 0.5)


## Create an ephemeral AudioStreamPlayer3D at the muzzle position.
## Mirrors _play_shell_sound() in tcp_thread_pool.gd:
##   - secondary shells look up a representative gun from _secondary_gun_pivots
##     (gun_index is local to a SecSubController, so we mod into the flat list)
##   - bus matches the live game: "Sec" for secondaries, "Main" for main battery
func _play_gun_sound(event: Dictionary) -> void:
	var ship_id:    int  = event.get("ship_id",    -1)
	var gun_index:  int  = event.get("gun_index",   0)
	var shell_type: int  = event.get("shell_type",  0)
	var is_secondary: bool = (shell_type & 1) != 0

	if ship_id < 0 or ship_id >= ghost_ships.size():
		return
	var gs = ghost_ships[ship_id]
	if gs == null or not is_instance_valid(gs):
		return

	# Secondary gun_index is local to its SecSubController, not global.
	# Since all secondary guns on a ship share the same audio config, any valid
	# secondary pivot works — we mod into the flat list as a safe fallback.
	var pivots: Array = gs._secondary_gun_pivots if is_secondary else gs._gun_pivots
	if pivots.is_empty():
		return
	var gun = pivots[gun_index % pivots.size()]
	if not is_instance_valid(gun):
		return

	var caliber:    float   = event.get("caliber",    100.0)
	var muzzle_pos: Vector3 = event.get("muzzle_pos", Vector3.ZERO)

	var player := AudioStreamPlayer3D.new()
	player.stream = gun._sound if gun._sound != null \
			else preload("res://assets/audio/explosion1.wav")
	player.max_polyphony = 4
	player.unit_size  = 100.0 * sqrt(caliber / 100.0) + 100.0
	player.max_db     = linear_to_db(gun.volume * (1.0 + gun.variance))
	player.pitch_scale = gun.pitch  * randf_range(1.0 - gun.variance, 1.0 + gun.variance)
	player.volume_db  = linear_to_db(gun.volume * randf_range(1.0 - gun.variance, 1.0 + gun.variance))
	player.bus        = "Sec" if is_secondary else "Main"
	add_child(player)
	player.global_position = muzzle_pos
	player.play()
	player.finished.connect(player.queue_free)
