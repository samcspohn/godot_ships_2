extends Node3D
class_name Fire

@onready var fire: GPUParticles3D = $GPUParticles3D
@onready var smoke: GPUParticles3D = $GPUParticles3D2
var _ship: Ship
var hp: HitPointsManager
# @export var duration: float = 50.0
# @export var buildUp: float = 100.0
# @export var total_dmg_p: float = .1
# var dps: float
var curr_buildup: float = 0
var lifetime: float = 0
var manager: FireManager = null
var _params: FireParams:
	get:
		return manager.params.params() as FireParams
	set(value):
		pass
var _owner: Ship = null

func _apply_build_up(a, __owner: Ship) -> bool:
	if lifetime <= 0:
		curr_buildup += a
		if curr_buildup >= _params.max_buildup:
			_owner = __owner
			fire.emitting = true
			smoke.emitting = true
			_sync_activate.rpc()
			lifetime = 1
			curr_buildup = 0
			return true
	return false

func init():
	_ship = get_parent().get_parent() as Ship
	# Only await if ship is not already ready
	if not _ship.is_node_ready():
		await _ship.ready
	hp = _ship.health_controller
	var s = _ship.get_node("Hull").get_aabb().size.length() / 10.0
	fire.scale = Vector3(s,s,s)
	smoke.scale = Vector3(s,s,s)
	(fire.process_material as ParticleProcessMaterial).scale_min = s
	#(fire.process_material as ParticleProcessMaterial).scale_max = s * 3
	(smoke.process_material as ParticleProcessMaterial).scale_min = s * 2
	(smoke.process_material as ParticleProcessMaterial).scale_max = s * 3
	fire.emitting = false
	smoke.emitting = false

func _ready():
	init.call_deferred()


func _physics_process(delta: float) -> void:
	if _Utils.authority():
		if lifetime > 0:
			_sync.rpc(lifetime)
			damage(delta)
			var d = _params.dur
			lifetime -= delta / d
			if lifetime <= 0:
				fire.emitting = false
				smoke.emitting = false
				_sync_deactivate.rpc()
		elif curr_buildup < _params.max_buildup if _params else false:
			curr_buildup -= delta * _params.max_buildup * _params.buildup_reduction_rate
			curr_buildup = max(curr_buildup, 0.0)

func damage(delta):
	if hp.is_alive():
		var max_hp = hp.max_hp
		var dmg_rate = _params.dmg_rate
		var dmg = max_hp * dmg_rate
		var dmg_sunk = hp.take_damage(dmg * delta, position)
		_owner.stats.fire_damage += dmg_sunk[0]
		_owner.stats.total_damage += dmg_sunk[0]
		if dmg_sunk[1]:
			_owner.stats.frags += 1

@rpc("any_peer")
func _sync(l):
	lifetime = l

@rpc("any_peer", "reliable")
func _sync_activate():
	fire.emitting = true
	smoke.emitting = true

@rpc("any_peer", "reliable")
func _sync_deactivate():
	fire.emitting = false
	smoke.emitting = false
