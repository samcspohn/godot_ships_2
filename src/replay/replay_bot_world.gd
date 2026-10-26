class_name ReplayBotWorld
extends BotDebugView.World
## BotDebugView.World for a replay ghost: poses from snapshots, projectiles from the replayers.

var ghosts: Array
var own: Node3D
var state: Dictionary
var enemies: Dictionary
var time: float
var shells: ShellReplayer
var torpedos: TorpedoReplayer


func own_pos() -> Vector3:
	return own.global_position


func own_heading() -> float:
	var fwd: Vector3 = -own.global_transform.basis.z
	return atan2(fwd.x, fwd.z)


func ship_pos(id: int) -> Vector3:
	if id < 0 or id >= ghosts.size() or not is_instance_valid(ghosts[id]):
		return Vector3.INF
	return ghosts[id].global_position


func trajectory() -> PackedVector3Array:
	var inputs: PackedFloat32Array = state.get("arc_ship", PackedFloat32Array()) + state.get("arc", PackedFloat32Array())
	return ShipNavigator.simulate_debug_arc(inputs, own_pos(), own_heading())


func shell_threats() -> Array:
	var p := own_pos()
	return shells.threats_near(Vector2(p.x, p.z), BotControllerV4.SHELL_QUERY_RANGE, enemies, time)


func torpedo_threats() -> Array:
	return torpedos.threat_points(own_pos(), enemies, time)
