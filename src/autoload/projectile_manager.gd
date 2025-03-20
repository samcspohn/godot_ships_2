extends Node


var nextId: int = 0;
var projectiles: Dictionary = {};

func CalculateLaunchVector(startPos: Vector3, targetPos: Vector3, launchSpeed: float, gravity: float) -> Vector3:
	gravity = -gravity
	var directionXZ = Vector3(targetPos.x - startPos.x, 0, targetPos.z - startPos.z);
	var distanceXZ = directionXZ.length();
	var heightDifference = targetPos.y - startPos.y;

	# Calculate launch angles using quadratic formula
	var speedSquared = launchSpeed * launchSpeed;
	var horizontalSpeedSquared = speedSquared * speedSquared;

	var gravityDistance = gravity * distanceXZ * distanceXZ;

	var determinant = horizontalSpeedSquared - gravity * (gravityDistance + 2 * heightDifference * speedSquared);

	# Check if target is reachable
	if (determinant < 0):
		#Debug.LogWarning("Target is not reachable with given speed!");
		return Vector3.ZERO
	

	# We usually want the smaller angle for a more direct shot
	var tanTheta = (speedSquared - sqrt(determinant)) / (gravity * distanceXZ);
	var angleInRadians = atan(tanTheta);

	# Construct the launch vector
	var launchDirection = directionXZ.normalized() * cos(angleInRadians);
	launchDirection.y = sin(angleInRadians);

	return launchDirection.normalized() * launchSpeed;

# # Called when the node enters the scene tree for the first time.
# func _ready() -> void:
# 	pass # Replace with function body.


# # Called every frame. 'delta' is the elapsed time since the previous frame.
# func _process(delta: float) -> void:
# 	pass

@rpc("any_peer", "reliable")
func fireBulletClient(pos, vel,_t,id) -> void:
	var bullet: Shell = load("res://scenes/shell.tscn").instantiate()
	bullet.id = id
	get_node("/root").add_child(bullet)
	var t = float(Time.get_ticks_msec()) / 1000.0
	bullet.initialize(pos, vel, t)
	self.projectiles.get_or_add(id, bullet)
	#var shell = bullet.get_script()
	#pass
	
	
	# Adding the request_spawn RPC function
#@rpc("any_peer", "call_remote")
func request_fire(dir, pos):
	#if multiplayer.is_server():
		# Get the game server node - adjust path as needed
		fireBullet(dir,pos)

@rpc("authority","reliable")
func fireBullet(dir,pos) -> void:
	var bullet: Shell = load("res://scenes/shell.tscn").instantiate()
	var id = self.nextId
	self.nextId += 1
	bullet.id = id
	get_node("/root").add_child(bullet)
	var t = float(Time.get_ticks_msec()) / 1000.0
	bullet.initialize(pos, dir * Shell.shell_speed, t)
	#bullet.vel = dir * Shell.shell_speed
	self.projectiles.get_or_add(id, bullet)
	for p in multiplayer.get_peers():
		self.fireBulletClient.rpc_id(p, pos, dir * Shell.shell_speed, t, id)
		#self.destroyBulletRpc2.rpc_id(p,id)
	

@rpc("call_remote", "reliable")
func destroyBulletRpc2(id) -> void:
	var bullet: Shell = self.projectiles.get(id)
	bullet._destroy(true)
	self.projectiles.erase(id)
	
@rpc("authority", "reliable")
func destroyBulletRpc(id) -> void:
	var bullet = self.projectiles.get(id)
	bullet.queue_free()
	self.projectiles.erase(id)
	#if multiplayer.is_server():
	for p in multiplayer.get_peers():
		self.destroyBulletRpc2.rpc_id(p,id)
