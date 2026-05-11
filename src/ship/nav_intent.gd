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

## When true, the navigator will use reverse propulsion to reach the destination.
## Applies to all en-route and approach phases; heading-alignment in the
## maneuver/arrived zones is unaffected and governed by the navigator.
var force_reverse: bool = false

## Heading tolerance: acceptable heading error to consider settled (radians, default ~15°)
var heading_tolerance: float = 0.2618

## Near-terrain flag: relaxes terrain collision avoidance so the ship can hug islands
var near_terrain: bool = false

## When true, _adjust_destination_for_threats will not BFS-push this destination
## out of blocked threat-arc cells.  Set by SkillFindCover and any other skill
## whose computed destination is deliberately inside a detection zone (e.g. a
## cover position behind an island).  The path planner's threat-cost edge weights
## still route the approach around detection for as long as possible; only the
## final waypoint pin is preserved as-is.
var skip_threat_adjustment: bool = false

## Directional flag: when true, the destination is a heading direction rather than a
## fixed world-space point. The bot controller will continuously reproject
## target_position as (currentShipPos + fwd * 5000) every path-update tick,
## preventing the destination from going stale between behavior queries.
var directional: bool = false

## Heading weight: 0 = normal navigation to target_position with heading alignment on
## arrival; 1 = navigator purely pursues target_heading — arc candidates are scored
## by how quickly/closely they align with the desired heading rather than how close
## they travel toward the destination.  Terrain avoidance is always active.
## Intermediate values blend the two scoring modes proportionally.
var heading_weight: float = 0.0


## Create a navigation intent
static func create(pos: Vector3, heading: float, radius: float = 0.0, tol: float = 0.2618, hw: float = 0.0) -> NavIntent:
	var i = NavIntent.new()
	i.target_position = pos
	i.target_heading = heading
	i.hold_radius = radius
	i.heading_tolerance = tol
	i.heading_weight = hw
	return i
