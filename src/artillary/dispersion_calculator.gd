# Naval Artillery Dispersion Calculator for GODOT 4.X
class_name ArtilleryDispersion

## Parameters for shell dispersion

# Base dispersion values at 0.5 km (500 meters)
# @export var base_horizontal_dispersion: float = 10.0 # Meters perpendicular to aim direction
# @export var base_vertical_dispersion: float = 120.0 # Meters in line with aim direction

# # Linear dispersion growth with range (meters per kilometer)
# @export var horizontal_dispersion_modifier: float = 13.56 # Additional meters of dispersion per km
# @export var vertical_dispersion_modifier: float = 13.56 # Additional meters of dispersion per km (typically 1.5-2x horizontal)

# # Grouping values control how tightly shells cluster (higher = tighter grouping, lower variance)
# @export var h_grouping: float = 3.0 # Horizontal grouping factor (higher = less spread)
# @export var v_grouping: float = 3.0 # Vertical grouping factor (higher = less spread)

# @export var base_spread: float = 0.01

# # Normal distribution cache for Box-Muller transform efficiency
# var _has_cached_normal: bool = false
# var _cached_normal: float = 0.0

## Calculate a point within the dispersion ellipse
# aim_point: The precise point being aimed at
# gun_position: The position of the gun firing the shell
# Returns: A new point representing where the shell will actually go due to dispersion
static func calculate_dispersed_launch(
									aim_point: Vector3,
									gun_position: Vector3,
									shell_params: ShellParams,
									h_grouping: float,
									v_grouping: float,
									base_spread: float) -> Vector3:
	# print(aim_point)

	var a = ProjectilePhysicsWithDragV2.calculate_launch_vector(gun_position, aim_point, shell_params)
	var launch_velocity = a[0]
	if launch_velocity == null:
		return (aim_point - gun_position).normalized()
	# return launch_velocity


	var _dist = gun_position.distance_to(aim_point)

	# Use efficient normal distribution for more realistic dispersion
	var p = random_point_in_ellipseV3(1.0, 1.0, h_grouping, v_grouping)


	var r = launch_velocity.cross(Vector3.UP).normalized()
	var u = launch_velocity.cross(r).normalized()
	# var base_spread = 0.01
	var new_launch_velocity = (launch_velocity.normalized() + (r * p.x + u * p.y) * base_spread) * shell_params.speed

	return new_launch_velocity

static func random_point_in_ellipseV3(width: float, height: float, h_group: float = 1.0, v_group: float = 1.0):
	var rho = randf_range(0.0, 1.0)
	var phi = randf_range(0.0, TAU)
	var a = width / 2.0
	var b = height / 2.0
	var x = pow(rho, h_group) * cos(phi) * a
	var y = pow(rho, v_group) * sin(phi) * b
	return Vector2(x, y)

	# var x = cos(phi) * sqrt(rho) * a
	# var y = sin(phi) * sqrt(rho) * b
	# if h_group > 1.0:
	# 	x = sign(x) * pow(abs(x) / a, h_group) * a
	# if v_group > 1.0:
	# 	y = sign(y) * pow(abs(y) / b, v_group) * b
	# return Vector2(x, y)
