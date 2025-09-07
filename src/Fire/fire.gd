extends Node3D
class_name Fire

@onready var fire: GPUParticles3D = $GPUParticles3D
@onready var smoke: GPUParticles3D = $GPUParticles3D2
var _ship: Ship
var hp: HitPointsManager
@export var duration: float = 50.0
@export var buildUp: float = 100.0
@export var total_dmg_p: float = .1
var curr_buildup: float = 0
var lifetime: float = 0
var _owner: Ship = null

func _apply_build_up(a, __owner: Ship) -> bool:
	if lifetime <= 0:
		curr_buildup += a
		if curr_buildup >= buildUp:
			_owner = __owner
			fire.emitting = true
			smoke.emitting = true
			_sync_activate.rpc()
			lifetime = 1
			curr_buildup = 0
			return true
	return false

func _ready():
	#var csgbox = get_parent().get_node("Hull") as CSGBox3D
	_ship = get_parent()
	hp = _ship.get_node("Modules").get_node("HPManager")
	var s = _ship.get_node("Hull").get_aabb().size.length() / 10.0
	fire.scale = Vector3(s,s,s)
	smoke.scale = Vector3(s,s,s)
	(fire.process_material as ParticleProcessMaterial).scale_min = s
	#(fire.process_material as ParticleProcessMaterial).scale_max = s * 3
	(smoke.process_material as ParticleProcessMaterial).scale_min = s * 2
	(smoke.process_material as ParticleProcessMaterial).scale_max = s * 3
	fire.emitting = false
	smoke.emitting = false

func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		if lifetime > 0:
			_sync.rpc(lifetime)
			damage(delta)
			lifetime -= delta / duration
			if lifetime <= 0:
				fire.emitting = false
				smoke.emitting = false
				_sync_deactivate.rpc()
		elif curr_buildup < buildUp:
			curr_buildup -= delta * 0.5

func damage(delta):
	if hp.is_alive():
		var max_hp = hp.max_hp
		var dmg = max_hp * total_dmg_p / duration
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
	
