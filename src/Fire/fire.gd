extends Node3D
class_name Fire

@onready var fire_emitter: ParticleEmitter = $FireEmitter
var _ship: Ship
var hp: HPManager
var curr_buildup: float = 0
var lifetime: float = 0
var manager: FireManager = null
var last_hit_time: float = 0
# const TIME_TO_DECAY: float = 30.0
var _params: DOTParams:
	get:
		return manager.fparams.p() as DOTParams
	set(value):
		pass
var _rparams: ResistanceParams:
	get:
		return manager.rparams.p() as ResistanceParams
	set(value):
		pass
var _owner: Ship = null

func _apply_build_up(a, __owner: Ship) -> bool:
	if lifetime <= 0:
		curr_buildup += a + 0.33 * (randf() - 0.5) # add some randomness to buildup
		last_hit_time = max(Time.get_ticks_msec() / 1000.0 + a * 0.5 * _rparams.reduction_block_rate, last_hit_time)
		var random_threshold = _rparams.max_buildup * 0.67
		var rand_value = clamp((curr_buildup - random_threshold) / (_rparams.max_buildup * 0.33),0.0,1.0)

		if curr_buildup >= _rparams.max_buildup or (rand_value > 0 and randf() < rand_value):
			_owner = __owner
			_owner.stats.damage_events.append({"type": "fire"})
			_owner.stats.fire_count += 1
			fire_emitter.start_emitting()
			_sync_activate.rpc()
			lifetime = 1.0
			# --- replay hook ---
			if _Utils.authority():
				var zone_index := manager.fires.find(self)
				ReplayRecorder.record_fire_started(_ship, zone_index, __owner)
			curr_buildup = 0
			return true
	return false

func _ready():
	_ship = $"../../.." as Ship
	await _ship.ready
	hp = _ship.health_controller
	var s = _ship.get_node("Hull").get_aabb().size.length() / 10.0
	fire_emitter.set_size(s)
	if _Utils.authority():
		set_physics_process(true)
	else:
		set_physics_process(false)

func _physics_process(_delta: float) -> void:
	if _Utils.authority():
		var sec_tic = Engine.get_physics_frames() % Engine.physics_ticks_per_second == 0
		if lifetime > 0:
			if sec_tic: # tick every second
				_sync.rpc(lifetime)
				damage(1.0)
				var d = _params.dur
				lifetime -= 1.0 / d
				if lifetime <= 0:
					fire_emitter.stop_emitting()
					# --- replay hook ---
					var zone_index := manager.fires.find(self)
					ReplayRecorder.record_fire_ended(_ship, zone_index)
					_sync_deactivate.rpc()
		elif sec_tic and curr_buildup < _rparams.max_buildup and last_hit_time < Time.get_ticks_msec() / 1000.0: # last hit is decay time
			curr_buildup -= _rparams.max_buildup * _rparams.buildup_reduction_rate
			curr_buildup = max(curr_buildup, 0.0)

func damage(delta):
	if hp.is_alive():
		var max_hp = hp.max_hp
		var dmg_rate = _params.dmg_rate
		var dmg = max_hp * dmg_rate
		# var dmg_sunk = hp.apply_light_damage(dmg * delta)
		var dmg_sunk = hp.apply_damage(dmg * delta, dmg * delta, null, false, HPManager.DAMAGE_TYPE.FIRE,HPManager.DAMAGE_LEVEL.LIGHT, _owner)
		_owner.stats.fire_damage += dmg_sunk[0]
		_owner.stats.total_damage += dmg_sunk[0]
		_ship.stats.potential_damage += dmg_sunk[0] # potential damage only increases if the damage actually affected HP (i.e. not fully resisted)
		_owner.stats.damage_ship(_ship, dmg_sunk[0])
		if dmg_sunk[1]:
			_owner.stats.frags += 1
		# --- replay hook (v4): record the actual damage applied this tick so
		# the replay HUD can rebuild fire_damage / total_damage bidirectionally.
		if _Utils.authority() and dmg_sunk[0] > 0.0:
			ReplayRecorder.record_fire_damage(_owner, _ship, dmg_sunk[0])

@rpc("authority", "unreliable_ordered")
func _sync(l):
	lifetime = l

@rpc("authority", "reliable")
func _sync_activate():
	fire_emitter.start_emitting()

@rpc("authority", "reliable")
func _sync_deactivate():
	fire_emitter.stop_emitting()
