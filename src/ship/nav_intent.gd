extends RefCounted

## NavIntent — Lightweight data class returned by behaviors to describe
## the navigation target for the bot controller.
##
## V5: Unified API — all navigation modes collapsed into (position, heading, hold_radius).

class_name NavIntent

## Target world position
var target_position: Vector3 = Vector3.ZERO

## Target heading in radians (0 = +Z)
var target_heading: float = 0.0

## Hold radius: 0 = arrive and stop, >0 = station-keep within this radius
var hold_radius: float = 0.0

## Optional throttle override (-1 = navigator decides)
var throttle_override: int = -1

## Heading tolerance: acceptable heading error to consider settled (radians, default ~15°)
var heading_tolerance: float = 0.2618

## Near-terrain flag: relaxes terrain collision avoidance so the ship can hug islands
var near_terrain: bool = false


## Create a navigation intent
static func create(pos: Vector3, heading: float, radius: float = 0.0, tol: float = 0.2618) -> NavIntent:
	var i = NavIntent.new()
	i.target_position = pos
	i.target_heading = heading
	i.hold_radius = radius
	i.heading_tolerance = tol
	return i
