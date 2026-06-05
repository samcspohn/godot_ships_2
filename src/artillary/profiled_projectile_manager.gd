extends Node

class_name ProfiledProjectileManager

## GDScript proxy around the native _ProjectileManager.
## Purpose: make projectile-manager calls visible as named GDScript calls in the profiler.

@onready var _impl: Node = $ProjectileManagerNative


func _ready() -> void:
	var is_server := OS.get_cmdline_args().has("--server")
	_impl.set_process(false)
	_impl.set_physics_process(false)
	set_process(not is_server)
	set_physics_process(is_server)


func _process(delta: float) -> void:
	_impl.profiled_process(delta)


func _physics_process(delta: float) -> void:
	_impl.profiled_physics_process(delta)


func get_raw() -> Node:
	return _impl


func calculate_penetration_power(shell_params: Resource, velocity: float) -> float:
	return _impl.calculate_penetration_power(shell_params, velocity)


func calculate_impact_angle(velocity: Vector3, surface_normal: Vector3) -> float:
	return _impl.calculate_impact_angle(velocity, surface_normal)


func find_ship(node: Node) -> Object:
	return _impl.find_ship(node)


func findShip(node: Node) -> Object:
	return _impl.findShip(node)


func _process_trails_only(current_time: float) -> void:
	_impl._process_trails_only(current_time)


func sync_time(server_time: float) -> void:
	_impl.sync_time(server_time)


func fire_bullet(vel: Vector3, pos: Vector3, shell: Resource, t: float, owner_node: Object, exclude: Array = []) -> int:
	return _impl.fire_bullet(vel, pos, shell, t, owner_node, exclude)


func fireBullet(vel: Vector3, pos: Vector3, shell: Resource, t: float, owner_node: Object, exclude: Array = []) -> int:
	return _impl.fireBullet(vel, pos, shell, t, owner_node, exclude)


func fire_bullet_client(
	pos: Vector3,
	vel: Vector3,
	t: float,
	id: int,
	shell: Resource,
	owner_node: Object,
	muzzle_blast: bool = true,
	basis: Basis = Basis()
) -> void:
	_impl.fire_bullet_client(pos, vel, t, id, shell, owner_node, muzzle_blast, basis)


func fireBulletClient(
	pos: Vector3,
	vel: Vector3,
	t: float,
	id: int,
	shell: Resource,
	owner_node: Object,
	muzzle_blast: bool = true,
	basis: Basis = Basis()
) -> void:
	_impl.fireBulletClient(pos, vel, t, id, shell, owner_node, muzzle_blast, basis)


func destroy_bullet_rpc(id: int, position: Vector3, hit_result: int, normal: Vector3) -> void:
	_impl.destroy_bullet_rpc(id, position, hit_result, normal)


func destroy_bullet_rpc2(id: int, pos: Vector3, hit_result: int, normal: Vector3) -> void:
	_impl.destroy_bullet_rpc2(id, pos, hit_result, normal)


func destroy_bullet_rpc3(data: PackedByteArray) -> void:
	_impl.destroy_bullet_rpc3(data)


func destroyBulletRpc(id: int, position: Vector3, hit_result: int, normal: Vector3) -> void:
	_impl.destroyBulletRpc(id, position, hit_result, normal)


func destroyBulletRpc2(id: int, pos: Vector3, hit_result: int, normal: Vector3) -> void:
	_impl.destroyBulletRpc2(id, pos, hit_result, normal)


func destroyBulletRpc3(data: PackedByteArray) -> void:
	_impl.destroyBulletRpc3(data)


func apply_fire_damage(projectile: Variant, ship: Object, hit_position: Vector3) -> void:
	_impl.apply_fire_damage(projectile, ship, hit_position)


func print_armor_debug(armor_result: Dictionary, ship: Object) -> void:
	_impl.print_armor_debug(armor_result, ship)


func validate_penetration_formula() -> void:
	_impl.validate_penetration_formula()


func clear_all() -> void:
	_impl.clear_all()


func create_ricochet_rpc(
	original_shell_id: int,
	new_shell_id: int,
	ricochet_position: Vector3,
	ricochet_velocity: Vector3,
	ricochet_time: float
) -> void:
	_impl.create_ricochet_rpc(original_shell_id, new_shell_id, ricochet_position, ricochet_velocity, ricochet_time)


func create_ricochet_rpc2(data: PackedByteArray) -> void:
	_impl.create_ricochet_rpc2(data)


func createRicochetRpc(
	original_shell_id: int,
	new_shell_id: int,
	ricochet_position: Vector3,
	ricochet_velocity: Vector3,
	ricochet_time: float
) -> void:
	_impl.createRicochetRpc(original_shell_id, new_shell_id, ricochet_position, ricochet_velocity, ricochet_time)


func createRicochetRpc2(data: PackedByteArray) -> void:
	_impl.createRicochetRpc2(data)


func get_shells_near_position(position: Vector2, radius: float, exclude_team_id: int) -> Array:
	return _impl.get_shells_near_position(position, radius, exclude_team_id)


func get_current_time() -> float:
	return _impl.get_current_time()


func get_shell_time_multiplier() -> float:
	return _impl.get_shell_time_multiplier()


func get_next_id() -> int:
	return _impl.get_next_id()


func get_projectiles() -> Array:
	return _impl.get_projectiles()


func get_ids_reuse() -> Array:
	return _impl.get_ids_reuse()


func get_shell_param_ids() -> Dictionary:
	return _impl.get_shell_param_ids()


func get_bullet_id() -> int:
	return _impl.get_bullet_id()


func get_last_shell_uid() -> int:
	return _impl.get_last_shell_uid()


func get_gpu_renderer() -> Node:
	return _impl.get_gpu_renderer()


func get_compute_particle_system() -> Node:
	return _impl.get_compute_particle_system()


func get_trail_template() -> Resource:
	return _impl.get_trail_template()


func get_camera() -> Camera3D:
	return _impl.get_camera()


func set_shell_time_multiplier(value: float) -> void:
	_impl.set_shell_time_multiplier(value)


func set_next_id(value: int) -> void:
	_impl.set_next_id(value)


func set_projectiles(value: Array) -> void:
	_impl.set_projectiles(value)


func set_ids_reuse(value: Array) -> void:
	_impl.set_ids_reuse(value)


func set_shell_param_ids(value: Dictionary) -> void:
	_impl.set_shell_param_ids(value)


func set_bullet_id(value: int) -> void:
	_impl.set_bullet_id(value)


func set_gpu_renderer(value: Node) -> void:
	_impl.set_gpu_renderer(value)


func set_compute_particle_system(value: Node) -> void:
	_impl.set_compute_particle_system(value)


func set_trail_template(value: Resource) -> void:
	_impl.set_trail_template(value)


func set_camera(value: Camera3D) -> void:
	_impl.set_camera(value)
