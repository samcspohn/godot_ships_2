# Naval Artillery Dispersion Calculator for GODOT 4.X
class_name DispersionCalculator
var period = 0.0


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


const SHELL_COUNT := 8
const MAX_R := 2.4477  # sqrt(-2 * log(0.05)) — 95th percentile, maps to 1.0

var _shell_index := 0
var _salvo_rotation := 0.0
var _shuffled_radii := PackedFloat64Array()
var _angles := PackedFloat64Array()
var _sigma := 1.0

# Citadel ellipse for post-processing (in angular fraction space, set externally)
var _citadel_h_frac := 0.5   # citadel semi-width as fraction of base_spread
var _citadel_v_frac := 0.05  # citadel semi-height as fraction of base_spread


func _init(sigma: float = 1.0) -> void:
	_sigma = maxf(sigma, 1.0)
	_new_salvo()


func set_sigma(sigma: float) -> void:
	_sigma = maxf(sigma, 1.0)


## Set citadel ellipse size as fractions of base_spread.
## e.g. for a ship that is half the dispersion width and 1/10 the height:
##   set_citadel_fractions(0.5, 0.1)
func set_citadel_fractions(h_frac: float, v_frac: float) -> void:
	_citadel_h_frac = maxf(h_frac, 0.01)
	_citadel_v_frac = maxf(v_frac, 0.01)


func _new_salvo() -> void:
	_shell_index = 0
	_salvo_rotation = randf() * TAU

	# ── Radial stratification via Rayleigh CDF, normalized to [0, 1] ──
	_shuffled_radii.resize(SHELL_COUNT)
	for i in SHELL_COUNT:
		var u_low := float(i) / SHELL_COUNT
		var u_high := float(i + 1) / SHELL_COUNT
		var u := u_low + randf() * (u_high - u_low)
		# Rayleigh CDF inversion, scaled so 95th percentile = 1.0
		_shuffled_radii[i] = minf(sqrt(-2.0 * log(1.0 - u + 1e-12)) / MAX_R, 1.0)

	# Fisher-Yates shuffle radii
	for i in range(SHELL_COUNT - 1, 0, -1):
		var j := randi_range(0, i)
		var tmp := _shuffled_radii[i]
		_shuffled_radii[i] = _shuffled_radii[j]
		_shuffled_radii[j] = tmp

	# ── Angular stratification with jitter ──
	_angles.resize(SHELL_COUNT)
	var sector := TAU / SHELL_COUNT
	for i in SHELL_COUNT:
		_angles[i] = float(i) * sector + _salvo_rotation \
			+ (randf() - 0.5) * sector * 0.7

	# ── Post-processing: citadel guarantee ──
	_apply_citadel_guarantee()


func _apply_citadel_guarantee() -> void:
	var ea := _citadel_h_frac  # semi-axis in normalized space
	var eb := _citadel_v_frac
	if ea <= 0.0 or eb <= 0.0:
		return

	# Decompose each shell into h/v offsets and check ellipse
	var any_inside := false
	var closest_idx := 0
	var closest_d := INF

	for i in SHELL_COUNT:
		var r := _shuffled_radii[i]
		var a := _angles[i]
		var hx := r * cos(a)  # lateral offset [-1, 1]
		var vy := r * sin(a)  # vertical offset [-1, 1]

		# Normalized ellipse distance: < 1 = inside
		var d := (hx * hx) / (ea * ea) + (vy * vy) / (eb * eb)
		if d <= 1.0:
			any_inside = true
			break
		if d < closest_d:
			closest_d = d
			closest_idx = i

	if not any_inside:
		# Pull nearest shell to 50–90% inside the ellipse along its current angle
		var scale_factor := (0.5 + randf() * 0.4) / sqrt(closest_d)
		_shuffled_radii[closest_idx] *= scale_factor


## Perturbs a launch vector by applying dispersion as angular offsets.
## h = lateral (perpendicular to aim in horizontal plane)
## v = vertical (elevation angle adjustment)
## base_spread = max dispersion angle in radians at sigma=1
func calculate_dispersed_launch(
		aim_point: Vector3,
		gun_position: Vector3,
		shell_params: ShellParams,
		h_grouping: float,
		v_grouping: float,
		base_spread: float) -> Vector3:

	var a = ProjectilePhysicsWithDragV2.calculate_launch_vector(gun_position, aim_point, shell_params)
	var launch_velocity: Vector3 = a[0]
	# return launch_velocity
	if _shell_index >= SHELL_COUNT:
		_new_salvo()

	var r := _shuffled_radii[_shell_index]
	var angle := _angles[_shell_index]
	_shell_index += 1

	# Decompose into lateral / vertical components (each in [-1, 1])
	var h_raw := r * cos(angle)
	var v_raw := r * sin(angle)

	# Apply per-axis grouping: higher = tighter toward center
	var h_offset: float = sign(h_raw) * pow(absf(h_raw), h_grouping)
	var v_offset: float = sign(v_raw) * pow(absf(v_raw), v_grouping)

	# Scale to actual angular dispersion
	var h_angle := h_offset * base_spread * 0.5
	var v_angle := v_offset * base_spread * 0.5

	# Build local frame around launch direction
	var forward := launch_velocity.normalized()
	var world_up := Vector3.UP
	var right := forward.cross(world_up).normalized()
	if right.length_squared() < 0.001:
		right = Vector3.RIGHT
	var up := right.cross(forward).normalized()

	# Rotate launch vector
	var speed := launch_velocity.length()
	var dispersed := forward
	dispersed = dispersed.rotated(up, h_angle)
	dispersed = dispersed.rotated(right, v_angle)

	return dispersed * speed


func get_inner_shell_count() -> int:
	return _shell_index
