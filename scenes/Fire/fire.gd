extends Node3D
class_name Fire

@onready var fire: GPUParticles3D = $GPUParticles3D
@onready var smoke: GPUParticles3D = $GPUParticles3D2
var _ship: Ship
var hp: HitPointsManager
@export var duration: float = 50.0
@export var buildUp: float = 100.0
var curr_buildup: float = 0
var lifetime: float = 0

func _apply_build_up(a):
	if lifetime <= 0:
		curr_buildup += a
		if curr_buildup >= buildUp:
			fire.emitting = true
			smoke.emitting = true
			_sync_activate.rpc()
			lifetime = 1
			curr_buildup = 0

func _ready():
	var csgbox = get_parent().get_node("Hull") as CSGBox3D
	_ship = get_parent()
	hp = _ship.get_node("Modules").get_node("HPManager")
	var s = csgbox.size.z / 10.0
	fire.scale = Vector3(s,s,s)
	smoke.scale = Vector3(s,s,s)
	(fire.process_material as ParticleProcessMaterial).scale_min = s
	(smoke.process_material as ParticleProcessMaterial).scale_min = s
	fire.emitting = false
	smoke.emitting = false

func _physics_process(delta: float) -> void:
	if multiplayer.is_server() && lifetime > 0:
		_sync.rpc(lifetime)
		damage()
		lifetime -= delta / duration
		if lifetime <= 0:
			fire.emitting = false
			smoke.emitting = false
			_sync_deactivate.rpc()
	

func damage():
	var max_hp = hp.max_hp
	hp.take_damage(max_hp / 10000.0, position)
	
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
	
