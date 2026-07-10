# Naval Artillery Dispersion Calculator for GODOT 4.X
class_name DispersionCalculator

# const SHELL_COUNT := 8

# var _shell_index := 0
# var _salvo_index := 0
# var _salvo_rotation := 0.0


# func _init() -> void:
# 	_new_salvo()


# func _new_salvo() -> void:
# 	_shell_index = 0
# 	_salvo_rotation = randf() * TAU
# 	_salvo_index += 1


# ## Halton sequence — low-discrepancy quasi-random in [0, 1]
# ## Base 2 and 3 give good 2D coverage with minimal correlation.
# static func _halton(index: int, base: int) -> float:
# 	var f := 1.0
# 	var r := 0.0
# 	var i := index
# 	while i > 0:
# 		f /= base
# 		r += f * (i % base)
# 		i /= base
# 	return r


# func calculate_dispersed_launch(
# 		aim_point: Vector3,
# 		gun_position: Vector3,
# 		shell_params: ShellParams,
# 		h_grouping: float,
# 		v_grouping: float,
# 		base_spread: float) -> Vector3:

# 	var a = ProjectilePhysicsWithDragV2.calculate_launch_vector(gun_position, aim_point, shell_params)
# 	var launch_velocity: Vector3 = a[0]

# 	if _shell_index >= SHELL_COUNT:
# 		_new_salvo()

# 	# Each salvo uses a different slice of the Halton sequence
# 	var idx := _salvo_index * SHELL_COUNT + _shell_index + 1
# 	_shell_index += 1

# 	var u1 := _halton(idx, 2)  # radial
# 	var u2 := _halton(idx, 3)  # angular

# 	# Rayleigh CDF inversion, normalized to [0, 1]
# 	# sqrt(-2 * log(0.05)) ≈ 2.45 — captures 95% of the distribution
# 	# Clamp the last 5% to the edge so base_spread is the hard ceiling
# 	const MAX_R := 2.4477  # sqrt(-2 * log(0.05))
# 	var r := minf(sqrt(-2.0 * log(1.0 - u1 + 1e-12)) / MAX_R, 1.0)
# 	var angle := u2 * TAU + _salvo_rotation

# 	# Decompose into lateral (h) and vertical (v) offsets
# 	var h_raw := r * cos(angle)
# 	var v_raw := r * sin(angle)

# 	# Apply per-axis grouping
# 	var h_offset: float = sign(h_raw) * pow(absf(h_raw), h_grouping)
# 	var v_offset: float = sign(v_raw) * pow(absf(v_raw), v_grouping)

# 	var h_angle := h_offset * base_spread * 0.5
# 	var v_angle := v_offset * base_spread * 0.5

# 	# Build local frame around launch direction
# 	var forward := launch_velocity.normalized()
# 	var world_up := Vector3.UP
# 	var right := forward.cross(world_up).normalized()
# 	if right.length_squared() < 0.001:
# 		right = Vector3.RIGHT
# 	var up := right.cross(forward).normalized()

# 	var speed := launch_velocity.length()
# 	var dispersed := forward
# 	dispersed = dispersed.rotated(up, h_angle)
# 	dispersed = dispersed.rotated(right, v_angle)

# 	return dispersed * speed


const SHELL_COUNT := 3
const CITADEL_GUARANTEE_NUM := 4
var citadel_guarantee_counter = 0

var _shell_index := 0
var _h_offsets := PackedFloat64Array()
var _v_offsets := PackedFloat64Array()
var _sigma := 1.0

# Citadel ellipse for post-processing (in normalised fraction space, set externally)
var _citadel_h_frac := 0.5
var _citadel_v_frac := 0.2
var _citadel_guarantee_enabled := true

func _init(sigma: float = 1.0) -> void:
	_sigma = maxf(sigma, 1.0)
	# Force a fresh salvo on the first shot so it uses the gun's real sigma
	# (passed into calculate_dispersed_launch) instead of a placeholder.
	_shell_index = SHELL_COUNT


func set_sigma(sigma: float) -> void:
	_sigma = maxf(sigma, 1.0)


## Set citadel ellipse size as fractions of base_spread.
## e.g. for a ship that is half the dispersion width and 1/10 the height:
##   set_citadel_fractions(0.5, 0.1)
func set_citadel_fractions(h_frac: float, v_frac: float) -> void:
	_citadel_h_frac = maxf(h_frac, 0.01)
	_citadel_v_frac = maxf(v_frac, 0.01)


## erf approximation, max |error| < 1.5e-7  (Abramowitz & Stegun 7.1.26).
static func _erf(x: float) -> float:
	const P  := 0.3275911
	const A1 := 0.254829592
	const A2 := -0.284496736
	const A3 := 1.421413741
	const A4 := -1.453152027
	const A5 := 1.061405429
	var t := 1.0 / (1.0 + P * absf(x))
	var poly := t * (A1 + t * (A2 + t * (A3 + t * (A4 + t * A5))))
	return signf(x) * (1.0 - poly * exp(-x * x))


## erfinv approximation, max |error| < 1.2e-4  (Winitzki 2008, eq. 4).
static func _erfinv(x: float) -> float:
	const A := 0.147
	const TWO_OVER_PI_A := 2.0 / (PI * A)
	var w := log(maxf(1.0 - x * x, 1e-30))
	var inner := TWO_OVER_PI_A + w * 0.5
	return signf(x) * sqrt(sqrt(inner * inner - w / A) - inner)


## Generate SHELL_COUNT independent samples from N(0, 1/s²) truncated to [-1, 1].
## Stratified across SHELL_COUNT equal CDF bins then Fisher-Yates shuffled.
## With SHELL_COUNT = 4, bins [0,.25) [.25,.5) [.5,.75) [.75,1) map to
## large-negative, small-negative, small-positive, large-positive — guaranteeing
## exactly 2 negative + 2 positive and 2 inner + 2 outer values per call.
## erf_bound = erf(s / sqrt(2)), precomputed by the caller.
func _generate_axis(s: float, erf_bound: float) -> PackedFloat64Array:
	var arr := PackedFloat64Array()
	arr.resize(SHELL_COUNT)
	var inv_s_sqrt2 := sqrt(2.0) / s
	for i in SHELL_COUNT:
		var u_low  := float(i)     / SHELL_COUNT
		var u_high := float(i + 1) / SHELL_COUNT
		var u := u_low + randf() * (u_high - u_low)
		# Invert the CDF of the truncated Gaussian on [-1, 1]:
		#   F(x) = 0.5 + 0.5 * erf(x * s / sqrt(2)) / erf_bound
		#   x    = sqrt(2)/s * erfinv(erf_bound * (2u - 1))
		arr[i] = inv_s_sqrt2 * _erfinv(erf_bound * (2.0 * u - 1.0))
	for i in range(SHELL_COUNT - 1, 0, -1):
		var j := randi_range(0, i)
		var tmp := arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
	return arr


func _new_salvo(sigma: float) -> void:
	_shell_index = 0
	var s := maxf(sigma, 0.01)
	# erf(s / sqrt(2)) = fraction of the full Gaussian within ±1 std-dev of the
	# truncation boundary; used as the CDF normalisation constant for each axis.
	var erf_bound := _erf(s / sqrt(2.0))
	_h_offsets = _generate_axis(s, erf_bound)
	_v_offsets = _generate_axis(s, erf_bound)
	citadel_guarantee_counter += SHELL_COUNT

	if _citadel_guarantee_enabled and citadel_guarantee_counter >= CITADEL_GUARANTEE_NUM:
		_apply_citadel_guarantee()
		citadel_guarantee_counter -= CITADEL_GUARANTEE_NUM


# Tests whether any shell in the current salvo will land inside the citadel
# ellipse, and only nudges a shell inward if none do. Offsets are already in
# normalised [-1, 1] space, matching what calculate_dispersed_launch() uses.
func _apply_citadel_guarantee() -> void:
	var ea := _citadel_h_frac
	var eb := _citadel_v_frac
	if ea <= 0.0 or eb <= 0.0:
		return

	var any_inside := false
	var closest_idx := 0
	var closest_d := INF

	for i in SHELL_COUNT:
		var h_frac := _h_offsets[i]
		var v_frac := _v_offsets[i]
		var d := (h_frac * h_frac) / (ea * ea) + (v_frac * v_frac) / (eb * eb)
		if d <= 1.0:
			any_inside = true
			break
		if d < closest_d:
			closest_d = d
			closest_idx = i

	if not any_inside:
		var h_frac := _h_offsets[closest_idx]
		var new_h: float
		if absf(h_frac) > ea:
			new_h = signf(h_frac) * ea * pow(randf(), 1.0)
		else:
			new_h = h_frac
		var v_max := eb * sqrt(1.0 - (new_h / ea) * (new_h / ea))
		var v_sign := 1.0 if randf() < 0.5 else -1.0
		var new_v := v_sign * pow(randf(), 1.6) * v_max
		_h_offsets[closest_idx] = new_h
		_v_offsets[closest_idx] = new_v

## Perturbs a launch vector by applying dispersion as world-space offsets to the aim point.
## h = lateral (perpendicular to aim in horizontal plane)
## v = vertical (elevation angle adjustment)
## sigma_h = WoWs-style sigma: the number of standard deviations the ellipse
##   edge represents. Higher sigma -> shells cluster tighter toward the aim
##   point; lower sigma spreads them out. Typical naval values are ~1.5 - 2.1.
## _sigma_v = reserved for future per-axis sigma asymmetry; unused for now.
## h_spread = max horizontal dispersion half-angle in radians (hard ceiling).
## v_spread = max vertical dispersion half-angle in radians (hard ceiling).
func calculate_dispersed_launch(
		aim_point: Vector3,
		gun_position: Vector3,
		shell_params: ShellParams,
		sigma_h: float,
		_sigma_v: float,
		h_spread: float,
		v_spread: float,
		max_range: float,
		dispersion_curve: Curve,
		max_dispersion: float) -> Vector3:

	var dist_to_target := (aim_point - gun_position).length()
	var t := maxf(dist_to_target / max_range, 0.0)
	var dispersion_m: float
	if t <= 1.0:
		dispersion_m = dispersion_curve.sample(t) * max_dispersion
	else:
		var slope := dispersion_curve.get_point_left_tangent(dispersion_curve.point_count - 1)
		dispersion_m = (dispersion_curve.sample(1.0) + slope * (t - 1.0)) * max_dispersion

	if _shell_index >= SHELL_COUNT:
		_new_salvo(sigma_h)

	var h_offset := _h_offsets[_shell_index]
	var v_offset := _v_offsets[_shell_index]
	_shell_index += 1

	var h_world := h_offset * dispersion_m * 0.5
	var v_world := v_offset * dispersion_m * (v_spread / h_spread) * 0.5

	var forward := (aim_point - gun_position).normalized()
	# Fires straight up/down have no horizontal aim direction to build a
	# lateral axis from - fall back to an arbitrary axis perpendicular to
	# forward instead of normalizing a zero vector (which left right/up as
	# zero and silently collapsed all shells onto the same point).
	var right := forward.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = forward.cross(Vector3.RIGHT)
	right = right.normalized()
	var up := right.cross(forward).normalized()
	var dispersed_aim := aim_point + right * h_world + up * v_world
	var a = ProjectilePhysicsWithDragV2.calculate_launch_vector(gun_position, dispersed_aim, shell_params)
	return a[0]


func get_inner_shell_count() -> int:
	return _shell_index
