@tool
class_name FireArc
extends Resource

## A counter-clockwise arc on the XZ plane defined by a min and max yaw angle
## (radians). Same convention as Turret slew limits: when min > max the arc
## wraps across 0. When min == max the arc covers the full circle (TAU).
##
## Used by Turret/Gun to define one or more permissible firing sectors that are
## independent of the slew limits. A torpedo launcher, for example, may slew
## through 360 degrees but only be permitted to fire within port and starboard
## arcs.

@export var min_angle: float = 0.0
@export var max_angle: float = TAU

## Returns true if the given yaw angle (radians, any range) lies inside this
## arc. Implementation matches Turret's offset-from-min framing for consistency.
func contains(angle: float) -> bool:
	var width: float = wrapf(max_angle - min_angle, 0.0, TAU)
	if width == 0.0:
		return true # full-circle convention
	return wrapf(angle - min_angle, 0.0, TAU) <= width
