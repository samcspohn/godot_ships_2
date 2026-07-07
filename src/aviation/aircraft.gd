extends Node3D
class_name Aircraft
var attack_point = null
var attack_direction: Vector2
var attacking: bool = false
var waypoints: Array[Vector2] = []
var idle_pos: Vector2
var _ship: Ship
var params: AircraftParams
var should_recall: bool = false
# @export var circle_range: float = 2000.0

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

const ATTACK_RADIUS: float = 1000.0

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	if not _Utils.authority():
		return
	var p = params.p() as AircraftParams
	var wp = process_waypoints()
	var pos: Vector2 = Vector2(global_position.x, global_position.z)
	if wp == null:
		if attack_point != null:
			wp = attack_point
		else:
			wp = _orbit_target(idle_pos, p.idle_radius, p.speed, delta)
	var disp: Vector2 = wp - pos

	if disp.length_squared() < ATTACK_RADIUS * ATTACK_RADIUS or attacking:
		attacking = true
		if attack_behavior():
			should_recall = true
		return
	# # current forward direction projected onto the xz plane (Godot forward is -Z)
	# var forward: Vector3 = -global_transform.basis.z
	# var current_dir := Vector2(forward.x, forward.z)
	# if current_dir.length_squared() < 0.0001:
	# 	current_dir = Vector2(0.0, 1.0)
	# current_dir = current_dir.normalized()

	# if disp.length_squared() > 0.0001:
	# 	var desired_dir := disp.normalized()
	# 	# constant-speed turn: angular rate = speed / turning_radius
	# 	var max_turn_angle: float = (p.speed / p.turning_radius) * delta
	# 	var turn_angle: float = clampf(current_dir.angle_to(desired_dir), -max_turn_angle, max_turn_angle)
	# 	current_dir = current_dir.rotated(turn_angle)

	# var movement: Vector2 = current_dir * p.speed * delta
	# global_position += Vector3(movement.x, 0.0, movement.y)
	# look_at(global_position + Vector3(current_dir.x, 0.0, current_dir.y))
	var prev_pos = global_position
	fly_toward(Vector3(wp.x, global_position.y, wp.y), delta)
	global_position.y = move_toward(global_position.y, p.altitude, p.speed * delta * 0.1)
	look_at(global_position + (global_position - prev_pos))

	# if attack_point != null:
	# 	attack_behavior()

func fly_toward(pos: Vector3, delta: float) -> void:
	var p = params.p() as AircraftParams
	var disp: Vector3 = pos - global_position
	var forward: Vector3 = -global_transform.basis.z
	var current_dir := forward
	if current_dir.length_squared() < 0.0001:
		current_dir = Vector3.FORWARD
	current_dir = current_dir.normalized()

	if disp.length_squared() > 0.0001:
		var desired_dir := disp.normalized()
		# constant-speed turn: angular rate = speed / turning_radius
		var max_turn_angle: float = (p.speed / p.turning_radius) * delta
		var turn_angle: float = clampf(current_dir.angle_to(desired_dir), 0.0, max_turn_angle)
		var axis := current_dir.cross(desired_dir)
		if axis.length_squared() > 0.0001:
			current_dir = current_dir.rotated(axis.normalized(), turn_angle)

	var movement: Vector3 = current_dir * p.speed * delta
	global_position += movement
	look_at(global_position + current_dir)

# point on a circle around idle_pos, advanced this frame's step; used to keep
# the aircraft circling its last commanded position when it has no waypoint
func _orbit_target(orbit_pos: Vector2, radius: float, speed: float, delta: float) -> Vector2:
	# var center = idle_pos
	var pos: Vector2 = Vector2(global_position.x, global_position.z)
	var from_center = pos - orbit_pos
	if from_center.length_squared() < 0.0001:
		from_center = Vector2(radius, 0.0)

	var angle = atan2(from_center.y, from_center.x)
	angle += (speed * delta) / radius
	return orbit_pos + Vector2(cos(angle), sin(angle)) * radius

# clamp waypoints to within range of ship and return current waypoint
# remove waypoints when the aircraft reaches them
func process_waypoints():
	if waypoints.size() == 0:
		return null
	for i in range(waypoints.size()):
		var wp = waypoints[i]
		var disp = wp - Vector2(_ship.global_position.x, _ship.global_position.z)
		if disp.length_squared() > params.p()._range * params.p()._range:
			disp = disp.normalized() * params.p()._range
			wp = Vector2(_ship.global_position.x, _ship.global_position.z) + disp
			waypoints[i] = wp

	var wp = waypoints[0]
	var disp = wp - Vector2(_ship.global_position.x, _ship.global_position.z)
	if disp.length_squared() < 100.0 : # reached waypoint
		waypoints.remove_at(0)
	if waypoints.size() == 0:
		return null
	return waypoints[0]

func set_waypoint(waypoint: Vector2, append: bool) -> void:
	if append:
		waypoints.append(waypoint)
	else:
		waypoints.clear()
		waypoints.append(waypoint)
	idle_pos = waypoint

# todo: attack point needs to be settable outside a radius from the plane.
# this radius should be dependant on the distance from the aim point to the ship to mimic artillery lead time
func set_attack_point(attack_point: Vector2, aim_direction: Vector2) -> void:
	self.attack_point = attack_point
	self.attack_direction = aim_direction
	self.attacking = false

func attack_behavior() -> bool:
	# Implement attack behavior here
	return true
