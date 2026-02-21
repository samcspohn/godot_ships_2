# Naval Artillery Dispersion Calculator for GODOT 4.X
class_name DispersionCalculator

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

var period: float = 4.0
var angle: float = 0.0
var shell_index: float = 0.0
var randomised_strata: Array[int] = []
var strata_idx: int = 0
func _init():
	angle = randf_range(0, TAU)
	shell_index = randf_range(0.0, period)
	for i in range(int(period)):
		randomised_strata.append(i)
	randomised_strata.shuffle()

## Calculate a point within the dispersion ellipse
# aim_point: The precise point being aimed at
# gun_position: The position of the gun firing the shell
# Returns: A new point representing where the shell will actually go due to dispersion
func calculate_dispersed_launch(
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

	# # Use efficient normal distribution for more realistic dispersion
	# # var p = random_point_in_ellipseV3(1.0, 1.0, h_grouping, v_grouping)
	# # print("base spread: ", base_spread)
	# var p = Vector2(cos(angle), sin(angle)) / 2.0
	# var x = sin(shell_index / (period + 1) * PI)
	# #x = randf_range(x)
	# # print(x)
	# var y = randf_range(0.0,0.01) + lerp(0.01, 1.0, pow(x, sqrt(h_grouping **2 + v_grouping **2)))
	# p *= y
	# p.x /= randf_range(1.0, h_grouping)
	# p.y /= randf_range(1.0, v_grouping)
	# # print(p)

	# angle += 2.7 + randf_range(0.0, 1.5)
	# shell_index += 1.0
	# angle = wrapf(angle, 0.0, TAU)
	# shell_index = wrapf(shell_index, 0.0, period)

	# var r = launch_velocity.cross(Vector3.UP).normalized()
	# var u = launch_velocity.cross(r).normalized()

	# var p = Vector2(cos(angle), sin(angle)) / 2.0
	# shell_index += 1.0
	# # m = midpoint
	# var m = pow(randf_range(0.0, 1.0), sqrt(h_grouping **2 + v_grouping **2))
	# var rho = randf_range(0.0, 1.0)
	# var rho2 = randf_range(0.0, 1.0)
	# var x = clamp((1.0 - pow(rho, h_grouping)) * (1.0 - m) + pow(rho2, h_grouping) * m, 0.0, 1.0)
	# var y = clamp((1.0 - pow(rho, v_grouping)) * (1.0 - m) + pow(rho2, v_grouping) * m, 0.0, 1.0)
	# p.x *= x
	# p.y *= y
	# if shell_index >= period:
	# 	p *= randf_range(0.0, 0.1)
	# 	shell_index -= period

	var p = Vector2.ZERO
	if period != 0:
		var strata = randomised_strata[strata_idx]
		strata_idx += 1
		# shell_index = fposmod(shell_index + 1.0, period)
		if strata_idx >= randomised_strata.size():
			strata_idx = 0
			randomised_strata.clear()
			for i in range(int(period)):
				randomised_strata.append(i)
			randomised_strata.shuffle()

		p = random_point_in_ellipse_stratified(1.0,1.0, strata, int(period), h_grouping, v_grouping)
		#if strata <= 1.0 and period > 1.0:
			#p *= randf_range(0.0, 0.1)
		if shell_index >= period:
			p *= randf_range(0.0, 0.1)
			shell_index -= period
		shell_index += 1.0
	else:
		p = random_point_in_ellipseV3(1.0, 1.0, h_grouping, v_grouping)

	# angle += 2.7 + randf_range(0.0, 2.0) * sign(randf() - 0.5)
	angle += PI / 2 + randf_range(0.0, PI)
	angle = fposmod(angle, TAU)


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

## Equal-area stratified sampling of pow(rho, group).
## Divides the area under rho^group into num_shells equal-area regions,
## and samples within the region corresponding to shell_index.
## Boundaries: x_k = (k / N) ^ (1 / (g + 1))
## Sample within stratum k: rho = ((k + u) / N) ^ (1 / (g + 1))
## Final value: pow(rho, g) = ((k + u) / N) ^ (g / (g + 1))
func random_point_in_ellipse_stratified(width: float, height: float, shell_idx: int, num_shells: int, h_group: float = 1.0, v_group: float = 1.0) -> Vector2:
	var u = randf_range(0.0, 1.0)
	# var phi = randf_range(0.0, TAU)
	var phi = angle
	var a = width / 2.0
	var b = height / 2.0
	var t = (shell_idx + u) / num_shells
	var x = pow(t, h_group) * cos(phi) * a
	var y = pow(t, v_group) * sin(phi) * b
	return Vector2(x, y)

	# var x = cos(phi) * sqrt(rho) * a
	# var y = sin(phi) * sqrt(rho) * b
	# if h_group > 1.0:
	# 	x = sign(x) * pow(abs(x) / a, h_group) * a
	# if v_group > 1.0:
	# 	y = sign(y) * pow(abs(y) / b, v_group) * b
	# return Vector2(x, y)
