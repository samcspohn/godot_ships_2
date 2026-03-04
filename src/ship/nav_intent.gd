extends RefCounted

## NavIntent — Lightweight data class returned by behaviors to describe
## what navigation mode and target the bot controller should use.
##
## Behaviors return a NavIntent from get_nav_intent() instead of a raw Vector3.
## The bot controller reads the intent and calls the appropriate ShipNavigator method.

class_name NavIntent

## Navigation modes matching the C++ NavMode enum in ShipNavigator
enum Mode {
	POSITION,      ## Move to a world position (pathfinds around islands)
	ANGLE,         ## Acquire a specific heading (no position target)
	POSE,          ## Arrive at a position facing a specific direction
	STATION_KEEP,  ## Hold position within a circular zone at a preferred heading
}

## The navigation mode to use
var mode: Mode = Mode.POSITION

## Target world position (used by POSITION, POSE)
var target_position: Vector3 = Vector3.ZERO

## Target heading in radians, 0 = +Z, PI/2 = +X (used by ANGLE, POSE, STATION_KEEP)
var target_heading: float = 0.0

## Station-keeping zone center (used by STATION_KEEP)
var zone_center: Vector3 = Vector3.ZERO

## Station-keeping zone radius in meters (used by STATION_KEEP)
var zone_radius: float = 500.0

## Preferred heading for station keeping (used by STATION_KEEP)
## This is separate from target_heading to allow behaviors to specify both
## a heading for POSE mode and a preferred heading for STATION_KEEP.
var preferred_heading: float = 0.0

## Optional throttle override (-1 means "let the navigator decide")
var throttle_override: int = -1


## Create a POSITION intent — navigate to a world position.
static func position(target: Vector3) -> NavIntent:
	var intent = NavIntent.new()
	intent.mode = Mode.POSITION
	intent.target_position = target
	return intent


## Create an ANGLE intent — acquire a specific heading.
static func angle(heading: float) -> NavIntent:
	var intent = NavIntent.new()
	intent.mode = Mode.ANGLE
	intent.target_heading = heading
	return intent


## Create a POSE intent — arrive at a position facing a specific direction.
static func pose(target: Vector3, heading: float) -> NavIntent:
	var intent = NavIntent.new()
	intent.mode = Mode.POSE
	intent.target_position = target
	intent.target_heading = heading
	return intent


## Create a STATION_KEEP intent — hold position within a zone at a preferred heading.
static func station(center: Vector3, radius: float, heading: float) -> NavIntent:
	var intent = NavIntent.new()
	intent.mode = Mode.STATION_KEEP
	intent.zone_center = center
	intent.zone_radius = radius
	intent.preferred_heading = heading
	intent.target_heading = heading
	return intent
