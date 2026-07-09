extends Node3D
class_name Aircraft

# Aircraft never navigate independently - they only ever try to reach and
# match this formation slot (owned by the Squadron; moves/rotates as the
# squadron flies). The squadron controls all flight and attack timing, and
# calls fire_ordnance() directly once it reaches the attack point.
var target: Node3D
var _ship: Ship
var params: AircraftParams
var should_recall: bool = false
# set by the squadron each tick: true while it's on its attack run, so
# aircraft snap into the tighter attack formation faster (see fly_toward()).
var attacking: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	if not _Utils.authority():
		return

	if target == null:
		return

	fly_toward(target.global_position, delta)

# distance over which the catch-up speed boost ramps from none (at the
# target) to max (at or beyond this range). There's no dead zone: any nonzero
# lag gets a proportional speed boost, so a lagging aircraft always has some
# excess speed over its target and its distance error converges to zero
# instead of settling into a permanent pursuit-curve offset.
const CATCHUP_RANGE: float = 300.0

func fly_toward(pos: Vector3, delta: float) -> void:
	var p = params.p() as AircraftParams
	var dist := global_position.distance_to(pos)
	var t: float = clampf(dist / CATCHUP_RANGE, 0.0, 1.0)
	var mult: float = p.attack_catch_up_speed_mult if attacking else p.catch_up_speed_mult
	var speed: float = lerpf(p.speed, p.speed * mult, t)
	attract(self, pos, speed, delta)

# Aircraft are magnetically attracted to their target position: move straight
# toward it at the given speed (never overshooting) and face the direction of
# travel. No turn-rate simulation, so there's nothing to oscillate or
# overshoot around.
static func attract(node: Node3D, target_pos: Vector3, speed: float, delta: float) -> void:
	var disp: Vector3 = target_pos - node.global_position
	var dist := disp.length()
	if dist < 0.0001:
		return
	var dir := disp / dist
	var move_dist: float = minf(speed * delta, dist)
	node.global_position += dir * move_dist
	node.look_at(node.global_position + dir)

# Turn-rate-limited flight simulation used by the squadron leader node: turns
# toward the target heading at a constant angular rate (speed / turning_radius)
# and advances at constant speed, so the formation flies (and turns) like a
# real aircraft rather than snapping straight at its next waypoint.
#
# Altitude is deliberately handled separately from the horizontal turn: the
# node climbs/descends toward target_altitude at a constant climb_rate,
# independent of how far away target_xz is. Coupling the two (steering
# straight at a 3D point including altitude) would only reach the target
# altitude by the time the horizontal distance also reaches zero - fine for a
# short final approach, but a squadron cruising for kilometers home would
# barely climb until the very end.
static func steer(node: Node3D, target_xz: Vector2, target_altitude: float, speed: float, turning_radius: float, climb_rate: float, delta: float) -> void:
	var current_pos: Vector3 = node.global_position
	var forward_xz := Vector2(-node.global_transform.basis.z.x, -node.global_transform.basis.z.z)
	if forward_xz.length_squared() < 0.0001:
		forward_xz = Vector2(0.0, 1.0)
	forward_xz = forward_xz.normalized()

	var disp_xz: Vector2 = target_xz - Vector2(current_pos.x, current_pos.z)
	if disp_xz.length_squared() > 0.0001:
		var desired_dir := disp_xz.normalized()
		# constant-speed turn: angular rate = speed / turning_radius
		var max_turn_angle: float = (speed / turning_radius) * delta
		var turn_angle: float = clampf(forward_xz.angle_to(desired_dir), -max_turn_angle, max_turn_angle)
		forward_xz = forward_xz.rotated(turn_angle)

	var horizontal_move: Vector2 = forward_xz * speed * delta
	var new_y: float = move_toward(current_pos.y, target_altitude, climb_rate * delta)
	var new_pos := Vector3(current_pos.x + horizontal_move.x, new_y, current_pos.z + horizontal_move.y)
	node.global_position = new_pos

	var look_dir := Vector3(horizontal_move.x, new_y - current_pos.y, horizontal_move.y)
	if look_dir.length_squared() > 0.0001:
		node.look_at(new_pos + look_dir.normalized())

# Called once by the squadron when it reaches the attack point. Subclasses
# implement their actual ordnance drop / spotting behavior here, firing from
# wherever they currently are (their formation slot, which the squadron has
# already spread out for the attack run).
# Returns true if this aircraft should be recalled after firing (one-shot
# ordnance runs), or false to keep it on station (e.g. spotting).
func fire_ordnance(_direction: Vector2) -> bool:
	return true
