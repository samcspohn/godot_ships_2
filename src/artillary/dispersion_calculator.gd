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


const SHELL_COUNT := 2
const CITADEL_GUARANTEE_NUM := 4
var citadel_guarantee_counter = 0

var _shell_index := 0
var _h_offsets := PackedFloat64Array()
var _v_offsets := PackedFloat64Array()
var _sigma := 1.0

# Citadel ellipse for post-processing (in normalised fraction space, set externally)
var _citadel_h_frac := 0.4
var _citadel_v_frac := 0.5
var _citadel_guarantee_enabled := false

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


# 2D N(0, 1/s²) truncated to the unit disk, stratified in radial CDF and in angle so a salvo always
# spans inner/outer and all sides. Radial CDF: (1 - exp(-s²r²/2)) / (1 - exp(-s²/2)).
func _new_salvo(sigma: float) -> void:
	_shell_index = 0
	var s := maxf(sigma, 0.01)
	var mass := 1.0 - exp(-0.5 * s * s)
	var radial_bins: Array[int] = []
	for i in SHELL_COUNT:
		radial_bins.append(i)
	radial_bins.shuffle()
	var rot := randf() * TAU
	_h_offsets.resize(SHELL_COUNT)
	_v_offsets.resize(SHELL_COUNT)
	for i in SHELL_COUNT:
		var u := (radial_bins[i] + randf()) / SHELL_COUNT
		var r := sqrt(-2.0 * log(maxf(1.0 - u * mass, 1e-30))) / s
		var ang := rot + (i + randf()) * TAU / SHELL_COUNT
		_h_offsets[i] = r * cos(ang)
		_v_offsets[i] = r * sin(ang)
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
## disp = the gun's DispersionParams: sigma plus the ellipse authored at its
##   reference range. Sigma is the number of standard deviations the ellipse edge
##   represents — higher sigma clusters shells toward the aim point, lower spreads
##   them out. Typical naval values are ~1.5 - 2.1.
## max_range = the gun's BASE range, which the dispersion curves are normalised
##   against, so a range upgrade widens the group at a given distance instead of
##   dragging the whole curve out with it.
## sigma_mult / h_spread / v_spread = the firing TargetMod's per-shot scaling.
func calculate_dispersed_launch(
		aim_point: Vector3,
		gun_position: Vector3,
		shell_params: ShellParams,
		max_range: float,
		disp: DispersionParams,
		sigma_mult: float = 1.0,
		h_spread: float = 1.0,
		v_spread: float = 1.0) -> Vector3:

	var dist_to_target := (aim_point - gun_position).length()
	var dispersion: Vector2 = disp.dispersion_at(dist_to_target, max_range)
	var dispersion_h_m := dispersion.x * h_spread
	var dispersion_v_m := dispersion.y * v_spread

	if _shell_index >= SHELL_COUNT:
		_new_salvo(disp.sigma * sigma_mult)

	var h_offset := _h_offsets[_shell_index]
	var v_offset := _v_offsets[_shell_index]
	_shell_index += 1

	var h_world := h_offset * dispersion_h_m * 0.5
	var v_world := v_offset * dispersion_v_m * 0.5

	var forward := (aim_point - gun_position).normalized()
	# Fires straight up/down have no horizontal aim direction to build a
	# lateral axis from - fall back to an arbitrary axis perpendicular to
	# forward instead of normalizing a zero vector (which left right/up as
	# zero and silently collapsed all shells onto the same point).
	var right := forward.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = forward.cross(Vector3.RIGHT)
	right = right.normalized()
	# var up := right.cross(forward).normalized()
	var up := Vector3.UP
	var dispersed_aim := aim_point + right * h_world + up * v_world
	var a = ProjectilePhysicsWithDragV2.calculate_launch_vector(gun_position, dispersed_aim, shell_params)
	return a[0]


func get_inner_shell_count() -> int:
	return _shell_index
