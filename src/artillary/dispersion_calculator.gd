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
var _period: float = 8.0
var _shell_index: float = 0.0
var quality: float = 0.5
var over_under_toggle: bool = false
# var randomised_strata: Array[Array] = []
# var strata_idx: int = 0
# var good_normal_toggle: bool = false
# var good_region: float = 1.0

# const GUARANTEE_STRATA = 1.0 / 10.0
# func compute_stratum():
# 	shell_index = 0.0
# 	randomised_strata.clear()
# 	# randomised_strata.append([0.0, GUARANTEE_STRATA])
# 	var i = 0;
# 	while shell_index < period:
# 		# {strat_id: [start, size]}
# 		randomised_strata.append([0.0, 0.0])
# 		i += 1
# 		shell_index += 1.0
# 	shell_index -= period


# 	var first_good = false

# 	# var strata_size = (1.0 - GUARANTEE_STRATA) / i
# 	#										 v guaranteed
# 	# convert to 2 strata with random order |--|----- good ------|------------ normal ------------|
# 	good_normal_toggle = true
# 	for j in range(1, randomised_strata.size()):
# 		# var start = GUARANTEE_STRATA + (j - 1) * strata_size
# 		if good_normal_toggle and first_good:
# 			randomised_strata[j] = [0.0, GUARANTEE_STRATA * 0.2]
# 			first_good = false
# 		else:
# 			var strata_size = good_region - GUARANTEE_STRATA if good_normal_toggle else (1.0 - good_region)
# 			var start = GUARANTEE_STRATA if good_normal_toggle else good_region
# 			randomised_strata[j] = [start, strata_size]
# 		# good_normal_toggle = !good_normal_toggle
# 	randomised_strata.shuffle()

func _init():
	angle = randf_range(0, TAU)
	over_under_toggle = randf() < 0.5
	_shell_index = randf_range(0.0, _period)
	# good_region = pow(0.5, (h_grouping + v_grouping) / 2.0)
	# shell_index = randf_range(0.0, period)
	# for i in range(int(period)):
	# 	randomised_strata.append(i)
	# randomised_strata.shuffle()
	# var guarantee_strata = 1.0 / 32.0
	# randomised_strata.append({0: [0.0, guarantee_strata]})
	# var strata_value = guarantee_strata
	# var strata_size = (1.0 - guarantee_strata) / int(period)
	# shell_index = 1.0
	# strata_idx = 1
	# while shell_index < period:
	# 	randomised_strata.append({shell_index: [strata_value, strata_value + guarantee_strata]})
	# 	strata_value += guarantee_strata
	# 	# randomised_strata.append(shell_index)
	# 	shell_index += 1.0
	# shell_index -= period
	# randomised_strata.shuffle()
	# compute_stratum()

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
		# var strata = randomised_strata[strata_idx]
		# strata_idx += 1
		# if strata_idx >= randomised_strata.size():
		# 	strata_idx = 0
		# 	# randomised_strata.clear()
		# 	# for i in range(int(period)):
		# 	# 	randomised_strata.append(i)
		# 	# randomised_strata.shuffle()
		# 	compute_stratum()
		# p = random_point_in_ellipse_stratified(1.0,1.0, strata[0], strata[1], h_grouping, v_grouping)
		# p *= 1.6

		# if shell_index >= period:
		# 	# p *= randf_range(0.0, 0.1)
		# 	var accurate_period = 30
		# 	p = random_point_in_ellipse_stratified(1.0,1.0, 0, accurate_period, h_grouping, v_grouping)
		# 	shell_index -= period
		# else:
		# 	p = random_point_in_ellipse_stratified(1.0,1.0, strata, int(period), h_grouping, v_grouping)

		# shell_index += 1.0

		#if strata <= 1.0 and period > 1.0:
			#p *= randf_range(0.0, 0.1)

		# the closer p is in quality to the desired quality, the more likely the next shell will have less quality (higher dispersion), and vice versa, creating a dynamic feedback loop that simulates the natural variability in shell dispersion while maintaining an overall average quality level.
		p = random_point_in_ellipseV4(1.0, 1.0, h_grouping, v_grouping)


		# if shell_index >= period:
		# 	# p *= randf_range(0.0, 0.05)
		# 	p.y *= randf_range(0.0, 0.025)
		# 	p.x *= 0.33
		# 	shell_index -= period
		# shell_index += 1.0

		# if _shell_index >= _period:
		# 	p.y *= randf_range(0.0, 0.025)
		# 	p.x *= 0.33
		# 	_shell_index -= _period
		# _shell_index += 1.0
	else:
		p = random_point_in_ellipseV3(1.0, 1.0, h_grouping, v_grouping)

	# angle += 2.7 + randf_range(0.0, 2.0) * sign(randf() - 0.5)
	# angle += PI / 2 + randf_range(0.0, PI)
	# angle = fposmod(angle, TAU)
	angle = randf_range(0, PI) if over_under_toggle else randf_range(PI, TAU)
	over_under_toggle = !over_under_toggle


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


func random_point_in_ellipseV4(width: float, height: float, h_group: float = 1.0, v_group: float = 1.0):
	# Quality feedback system: bias rho based on previous shell's quality.
	# quality is in [0, 1] where 0 = center hit (perfect), 1 = edge hit (worst).
	# Neutral quality = 0.5 (median rho when uniform), which corresponds to
	# an average shell distance of pow(0.5, avg_grouping).
	#
	# rho_exponent < 1 -> pow(rand, <1) biases rho toward 1 (worse next shot)
	# rho_exponent = 1 -> uniform rho (no bias, neutral)
	# rho_exponent > 1 -> pow(rand, >1) biases rho toward 0 (better next shot)
	#
	# Mapping: rho_exponent = 2.0 * quality
	#   quality = 0.0 (perfect)  -> exp ≈ 0   -> next shell strongly biased outward
	#   quality = 0.5 (average)  -> exp = 1.0  -> next shell uniform (no bias)
	#   quality = 1.0 (worst)    -> exp > 1    -> next shell biased inward
	#
	# feedback_strength amplifies the curve on both sides of the pivot.
	# pow(1.0, k) = 1.0 always, so the neutral point at quality=0.5 is preserved.
	#   strength=1 -> linear (original), strength=2 -> quadratic, etc.
	var feedback_strength = 4.0
	var rho_exponent = clampf(pow(2.0 * quality, feedback_strength), 0.01, 10.0)

	var min_rho = 0.0 if quality > 0.16 else 2 * (0.16 - quality)
	var max_rho = 1.0 if quality < 0.84 else 1.0 - 2 * (quality - 0.84)
	var rho = pow(randf_range(min_rho, max_rho), rho_exponent)
	# var phi = randf_range(0.0, TAU)
	var phi = angle
	var a = width / 2.0
	var b = height / 2.0
	var x = pow(rho, h_group) * cos(phi) * a
	var y = pow(rho, v_group) * sin(phi) * b

	# Update quality for next shell: rho represents where this shell landed
	# (0 = center, 1 = edge), feeding back into the next shot's bias.
	# quality = rho
	quality = quality * 0.667 + rho * 0.333

	return Vector2(x, y)

## Equal-area stratified sampling of pow(rho, group).
## Divides the area under rho^group into num_shells equal-area regions,
## and samples within the region corresponding to shell_index.
## Boundaries: x_k = (k / N) ^ (1 / (g + 1))
## Sample within stratum k: rho = ((k + u) / N) ^ (1 / (g + 1))
## Final value: pow(rho, g) = ((k + u) / N) ^ (g / (g + 1))
func random_point_in_ellipse_stratified(width: float, height: float, start: float, size: float, h_group: float = 1.0, v_group: float = 1.0) -> Vector2:
	var u = randf_range(0.0, 1.0)
	# var phi = randf_range(0.0, TAU)
	var phi = angle
	var a = width / 2.0
	var b = height / 2.0
	var t = start + u * size
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
