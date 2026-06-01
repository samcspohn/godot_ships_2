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
const MAX_R := 2.4477  # sqrt(-2 * log(0.05)) — Rayleigh 95th percentile

var _shell_index := 0
var _shuffled_radii := PackedFloat64Array()
var _angles := PackedFloat64Array()
var _sigma := 1.0

# Citadel ellipse for post-processing (in angular fraction space, set externally)
var _citadel_h_frac := 0.5   # citadel semi-width as fraction of base_spread
var _citadel_v_frac := 0.05  # citadel semi-height as fraction of base_spread


func _init(sigma: float = 1.0) -> void:
	_sigma = maxf(sigma, 1.0)
	_new_salvo(1.0, 1.0)


func set_sigma(sigma: float) -> void:
	_sigma = maxf(sigma, 1.0)


## Set citadel ellipse size as fractions of base_spread.
## e.g. for a ship that is half the dispersion width and 1/10 the height:
##   set_citadel_fractions(0.5, 0.1)
func set_citadel_fractions(h_frac: float, v_frac: float) -> void:
	_citadel_h_frac = maxf(h_frac, 0.01)
	_citadel_v_frac = maxf(v_frac, 0.01)


func _new_salvo(h_grouping: float, v_grouping: float) -> void:
	_shell_index = 0
	var half: int = SHELL_COUNT >> 1  # SHELL_COUNT / 2

	# ── Rayleigh-stratified radii, sorted inner (small) to outer (large) ──
	var sorted_r := PackedFloat64Array()
	sorted_r.resize(SHELL_COUNT)
	for i in SHELL_COUNT:
		var u_low := float(i) / SHELL_COUNT
		var u_high := float(i + 1) / SHELL_COUNT
		var u := u_low + randf() * (u_high - u_low)
		sorted_r[i] = minf(sqrt(-2.0 * log(1.0 - u + 1e-12)) / MAX_R, 1.0)
	sorted_r.sort()

	# ── Assign radii: interleave inner and outer within each consecutive pair ──
	# Shell 2i   : sorted_r[i]         — inner, accurate, lands close to aim
	# Shell 2i+1 : sorted_r[N-1-i]     — outer, spread, lands far from aim
	# Every 2 shells = one tight + one wide shot.
	# Every 4 shells = innermost + outermost pair AND second inner + second outer pair,
	# covering the full quality range.
	_shuffled_radii.resize(SHELL_COUNT)
	for i in half:
		_shuffled_radii[i * 2]     = sorted_r[i]
		_shuffled_radii[i * 2 + 1] = sorted_r[SHELL_COUNT - 1 - i]

	# ── Angles: 2 upper + 2 lower per group of 4 ──
	# Generate `half` angles stratified across [0, PI]   (upper half-circle)
	# and   `half` angles stratified across [PI, 2*PI]   (lower half-circle).
	# Shuffle each group independently so left-right position stays random.
	# Then build two groups of 4 (one per gun pair), each containing exactly
	# 2 upper + 2 lower angles, and shuffle within each group so the up/down
	# order varies each salvo. A single gun firing 2 shells can get 2 lows or
	# 2 highs, but across any 4 shells the split is always guaranteed 2 and 2.
	var upper_angles := PackedFloat64Array()
	var lower_angles := PackedFloat64Array()
	upper_angles.resize(half)
	lower_angles.resize(half)
	var sector := PI / half
	for i in half:
		var jitter := (randf() - 0.5) * sector * 0.7
		upper_angles[i] = (float(i) + 0.5) * sector + jitter
		lower_angles[i] = PI + (float(i) + 0.5) * sector + jitter

	for i in range(half - 1, 0, -1):
		var j := randi_range(0, i)
		var tmp := upper_angles[i]
		upper_angles[i] = upper_angles[j]
		upper_angles[j] = tmp

	for li in range(half - 1, 0, -1):
		var lj := randi_range(0, li)
		var ltmp := lower_angles[li]
		lower_angles[li] = lower_angles[lj]
		lower_angles[lj] = ltmp

	_angles.resize(SHELL_COUNT)
	# Fill two groups of 4, each containing exactly 2 upper + 2 lower angles,
	# then shuffle within each group so the order varies each salvo.
	# A single gun firing its 2-shell salvo can get 2 lows or 2 highs,
	# but across any 4 consecutive shells the split is always 2 and 2.
	var group_buf := PackedFloat64Array()
	group_buf.resize(4)
	for gi in 2:
		group_buf[0] = upper_angles[gi * 2]
		group_buf[1] = upper_angles[gi * 2 + 1]
		group_buf[2] = lower_angles[gi * 2]
		group_buf[3] = lower_angles[gi * 2 + 1]
		for ki in range(3, 0, -1):
			var mi := randi_range(0, ki)
			var bt := group_buf[ki]
			group_buf[ki] = group_buf[mi]
			group_buf[mi] = bt
		for ki in 4:
			_angles[gi * 4 + ki] = group_buf[ki]

	_apply_citadel_guarantee(h_grouping, v_grouping)


# Tests whether any shell in the current salvo will land inside the citadel
# ellipse AFTER grouping is applied, and only nudges a shell inward if none do.
# The grouping exponents must match what `calculate_dispersed_launch()` uses,
# otherwise an inner shell that grouping would have squeezed into the citadel
# can be falsely rejected, causing us to pull yet another shell inward and
# tighten the overall pattern beyond what the curve specifies.
func _apply_citadel_guarantee(h_grouping: float, v_grouping: float) -> void:
	var ea := _citadel_h_frac
	var eb := _citadel_v_frac
	if ea <= 0.0 or eb <= 0.0:
		return

	var any_inside := false
	var closest_idx := 0
	var closest_d := INF

	for i in SHELL_COUNT:
		var h_raw := _shuffled_radii[i] * cos(_angles[i])
		var v_raw := _shuffled_radii[i] * sin(_angles[i])
		# Mirror the grouping transform from calculate_dispersed_launch()
		var hx: float = sign(h_raw) * pow(absf(h_raw), h_grouping)
		var vy: float = sign(v_raw) * pow(absf(v_raw), v_grouping)
		var d := (hx * hx) / (ea * ea) + (vy * vy) / (eb * eb)
		if d <= 1.0:
			any_inside = true
			break
		if d < closest_d:
			closest_d = d
			closest_idx = i

	if not any_inside:
		# Solve for the raw-radius scale that lands the post-grouping shell
		# inside the ellipse. Grouping is a power law on |r|, so scaling raw
		# radius by `s` scales the post-grouping radius by s^grouping. We pick
		# an average exponent for the axis weighting (cheap + close enough).
		var avg_grouping: float = (h_grouping + v_grouping) * 0.5
		var target_d := 0.25 + randf() * 0.56  # final d in [0.25, 0.81]
		var scale_factor: float = pow(target_d / closest_d, 0.5 / maxf(avg_grouping, 0.01))
		_shuffled_radii[closest_idx] *= scale_factor

# Dispersion curve. The maximum physical dispersion (meters at max range) is
# derived from the per-gun `base_spread` (radians) so per-gun tuning works again:
#     MAX_DISPERSION_METERS = base_spread * max_range
# The close-range anchor is expressed as a fraction of that maximum.
# A power curve is fit through (0, 0), (CLOSE_RANGE, fraction*MAX), and (max_range, MAX).
const CLOSE_DISPERSION_FRACTION: float = 0.33  # close-range dispersion as % of max
const CLOSE_RANGE_METERS: float = 3000.0          # the anchor for close-range tuning
const MAX_DISPERSION_ANGLE_RAD: float = 0.5      # safety cap at point-blank

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
		base_spread: float,
		max_range: float) -> Vector3:

	var a = ProjectilePhysicsWithDragV2.calculate_launch_vector(gun_position, aim_point, shell_params)
	var dist_to_target := (aim_point - gun_position).length()
	var launch_velocity: Vector3 = a[0]

	# # Power-curve dispersion in meters: meters(d) = MAX * (d/max_range)^p
	# # MAX is set by the gun's base_spread (radians) projected to max_range,
	# # and p is chosen so meters(CLOSE_RANGE_METERS) == CLOSE_DISPERSION_FRACTION * MAX.
	# # Passes through (0,0) automatically and reaches MAX at max_range.
	# var max_dispersion_m := base_spread * max_range
	# var p := log(CLOSE_DISPERSION_FRACTION) / log(CLOSE_RANGE_METERS / max_range)
	# var dispersion_m := max_dispersion_m \
	# 		* pow(clampf(dist_to_target / max_range, 0.0, 1.0), p)

	# # Convert physical dispersion to the angular spread the rotation code expects.
	# # Clamp distance away from zero and clamp angle to avoid pathological rotations
	# # at extreme close range (where meters/d blows up because p < 1).
	# var _base_spread: float = minf(
	# 		dispersion_m / maxf(dist_to_target, 1.0),
	# 		MAX_DISPERSION_ANGLE_RAD)
	var rate = (1.0 - (dist_to_target / max_range))
	rate = clamp(pow(rate, 2.0), 0.0, 1.0)
	var _base_spread: float = rate * base_spread * 2.0 + base_spread

	if _shell_index >= SHELL_COUNT:
		_new_salvo(h_grouping, v_grouping)

	var r := _shuffled_radii[_shell_index]
	var angle := _angles[_shell_index]
	_shell_index += 1

	var h_raw := r * cos(angle)
	var v_raw := r * sin(angle)

	# Apply per-axis grouping: higher = tighter toward center
	var h_offset: float = sign(h_raw) * pow(absf(h_raw), h_grouping)
	var v_offset: float = sign(v_raw) * pow(absf(v_raw), v_grouping)

	# Scale to actual angular dispersion
	const VERTICAL_SPREAD: float = 0.7
	var h_angle := h_offset * _base_spread * 0.5
	var v_angle := v_offset * base_spread * 0.5 * VERTICAL_SPREAD  # vertical spread is often tighter than horizontal in real guns, and looks better visually

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
