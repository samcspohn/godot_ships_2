class_name Shell
extends Node3D

var vel: Vector3 = Vector3(0,0,0)
var id: int
const shell_speed = 10
var init = false
#var prev_pos: Vector3
var query: PhysicsRayQueryParameters3D
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	#prev_pos = position
	query = PhysicsRayQueryParameters3D.create(position, position)
	query.collide_with_areas = true


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	self.position += delta * self.vel
	self.vel += Vector3(0,-.981,0) * delta
	if multiplayer.is_server():
		#if position.y < 0:
		#var query = PhysicsRayQueryParameters3D.create(prev_pos, position)
		query.from = query.to
		query.to = position
		if not init:
			init = true
		else:
			var a = get_world_3d().direct_space_state.intersect_ray(query)
			if not a.is_empty():
				ProjectileManager.destroyBulletRpc(self.id)
