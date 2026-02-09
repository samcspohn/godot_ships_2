extends Node3D
class_name Flood

@onready var water: GPUParticles3D = $GPUParticles3D
@onready var bubbles: GPUParticles3D = $GPUParticles3D2
var _ship: Ship
var hp: HPManager

var curr_buildup: float = 0
var lifetime: float = 0
var manager: FloodManager = null
var _params: FloodParams:
	get:
		return manager.params.p() as FloodParams
	set(value):
		pass
var _owner: Ship = null

func _apply_build_up(a, __owner: Ship) -> bool:
	if lifetime <= 0:
		curr_buildup += a
		if curr_buildup >= _params.max_buildup:
			_owner = __owner
			_owner.stats.damage_events.append({"type": "flood"})
			_owner.stats.flood_count += 1
			water.emitting = true
			bubbles.emitting = true
			_sync_activate.rpc()
			lifetime = 1
			curr_buildup = 0
			return true
	return false

func _ready():
	_ship = get_parent().get_parent() as Ship
	await _ship.ready
	hp = _ship.health_controller
	var s = _ship.get_node("Hull").get_aabb().size.length() / 10.0
	water.scale = Vector3(s, s, s)
	bubbles.scale = Vector3(s, s, s)
	(water.process_material as ParticleProcessMaterial).scale_min = s
	(bubbles.process_material as ParticleProcessMaterial).scale_min = s * 0.5
	(bubbles.process_material as ParticleProcessMaterial).scale_max = s * 1.5
	water.emitting = false
	bubbles.emitting = false
	if _Utils.authority():
		set_physics_process(true)
	else:
		set_physics_process(false)

func _physics_process(delta: float) -> void:
	if _Utils.authority():
		if lifetime > 0:
			_sync.rpc(lifetime)
			damage(delta)
			var d = _params.dur
			lifetime -= delta / d
			if lifetime <= 0:
				water.emitting = false
				bubbles.emitting = false
				_sync_deactivate.rpc()
		elif curr_buildup < _params.max_buildup:
			curr_buildup -= delta * _params.max_buildup * _params.buildup_reduction_rate
			curr_buildup = max(curr_buildup, 0.0)

func damage(delta):
	if hp.is_alive():
		var max_hp = hp.max_hp
		var dmg_rate = _params.dmg_rate
		var dmg = max_hp * dmg_rate
		var dmg_sunk = hp.apply_light_damage(dmg * delta)
		_owner.stats.flood_damage += dmg_sunk[0]
		_owner.stats.total_damage += dmg_sunk[0]
		if dmg_sunk[1]:
			_owner.stats.frags += 1

@rpc("any_peer")
func _sync(l):
	lifetime = l

@rpc("any_peer", "reliable")
func _sync_activate():
	water.emitting = true
	bubbles.emitting = true

@rpc("any_peer", "reliable")
func _sync_deactivate():
	water.emitting = false
	bubbles.emitting = false
