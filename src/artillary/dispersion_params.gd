## The dispersion ellipse of one gun mount, split out of GunParams so that every
## ship in a line can point at the same resource (all the German battleships
## share res://src/artillary/Dispersion/ger_bb_main.tres, for instance).
##
## `h_disp` / `v_disp` are the ellipse size in metres at a fixed REFERENCE range
## — 20 km for a main battery, 5 km for a secondary — not at the gun's own
## maximum range. That is what lets one resource describe a whole line: two
## ships with 15 km and 18.5 km of range quote the same number and the shorter-
## ranged one simply never reaches the part of the curve where it applies.
##
## The curves are shape only, normalised so that 1.0 is the value at the gun's
## maximum range; the reference number sets the scale. Past the end of the curve
## (which is where a 15 km gun sits when the reference is 20 km) the last
## segment's slope is continued linearly.
##
## To see what a set of params works out to in metres for a real gun, read the
## read-only "Dispersion At Max Range" row the owning GunParams shows in the
## inspector, or call dispersion_at_max_range() yourself.
@tool
extends Resource
class_name DispersionParams

## Reference range for a main battery. Secondaries are authored at
## SECONDARY_REFERENCE_RANGE instead: extrapolating a 4 km gun's curve out to
## 20 km multiplies it by five, which turns a small curve tweak into a huge
## change in the spread the gun actually throws.
const MAIN_REFERENCE_RANGE := 20000.0
const SECONDARY_REFERENCE_RANGE := 5000.0

## WoWs-style sigma: how many standard deviations the edge of the ellipse is.
## Higher values cluster shells toward the middle, lower ones spread them out.
@export var sigma: float = 1.8

@export var h_curve: Curve = preload("res://src/artillary/default_dispersion.tres")
@export var v_curve: Curve = preload("res://src/artillary/default_v_dispersion.tres")

## Range, in metres, that h_disp / v_disp are quoted at.
@export var reference_range: float = MAIN_REFERENCE_RANGE
## Ellipse width in metres at reference_range.
@export var h_disp: float = 250.0
## Ellipse height in metres at reference_range.
@export var v_disp: float = 100.0


## Curve value at range fraction `t` (dist / max_range), continuing the last
## segment's slope linearly past t = 1.0 so that a gun firing beyond its base
## range — a range upgrade, or a reference range longer than the gun's own —
## keeps getting a wider group instead of flat-lining at the curve's end.
static func sample_curve(curve: Curve, t: float) -> float:
	if curve == null or curve.point_count == 0:
		return 0.0
	if t <= 1.0:
		return curve.sample(maxf(t, 0.0))
	var slope := curve.get_point_left_tangent(curve.point_count - 1)
	return curve.sample(1.0) + slope * (t - 1.0)


## Metres of ellipse per unit of curve for a gun with this base range, picked so
## that the ellipse comes out at exactly h_disp / v_disp at reference_range.
func h_scale(max_range: float) -> float:
	return h_disp / _reference_fraction(h_curve, max_range)


func v_scale(max_range: float) -> float:
	return v_disp / _reference_fraction(v_curve, max_range)


## The curve value the reference number is pinned to. A curve that reads zero
## there carries no scale information, so fall back to treating the number as
## the value at maximum range (curves are normalised to 1.0 there).
func _reference_fraction(curve: Curve, max_range: float) -> float:
	var f := sample_curve(curve, reference_range / maxf(max_range, 1.0))
	return f if f > 0.0001 else 1.0


## Ellipse size in metres at `dist`, for a gun whose base range is `max_range`.
func dispersion_at(dist: float, max_range: float) -> Vector2:
	var t := maxf(dist, 0.0) / maxf(max_range, 1.0)
	return Vector2(
		sample_curve(h_curve, t) * h_scale(max_range),
		sample_curve(v_curve, t) * v_scale(max_range))


func h_at(dist: float, max_range: float) -> float:
	return sample_curve(h_curve, maxf(dist, 0.0) / maxf(max_range, 1.0)) * h_scale(max_range)


func v_at(dist: float, max_range: float) -> float:
	return sample_curve(v_curve, maxf(dist, 0.0) / maxf(max_range, 1.0)) * v_scale(max_range)


## The widest group the gun actually throws: the ellipse at its own maximum
## range, as opposed to the reference-range number it is authored with.
func dispersion_at_max_range(max_range: float) -> Vector2:
	return dispersion_at(max_range, max_range)
