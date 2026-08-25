class_name DropShadow

# Terrain dead zone for air-dropped ordnance.
#
# An attack run comes in over the carrier's side of the target, so what the
# squadron has to clear on the way down is the terrain between the drop point
# and the carrier. Model that run-in as a straight line leaving the ground under
# the drop point at APPROACH_ANGLE, aimed back at the carrier: if an island
# breaks that line the squadron cannot get down onto the mark, and the drop is
# refused. Only terrain standing above the drop point's own ground counts, which
# is what keeps the near shore of an island - where the island is behind the
# mark, shielding nothing - out of the dead zone.
#
# The consequence is the point of it - a ship tucked in behind an island is
# covered from the air for the same reason it is covered from gunfire, out to
# the distance where the run-in has climbed over the ridge. That distance is
# the island's height divided by SLOPE - several metres of water per metre of
# rock at any angle this shallow - so tall terrain shelters a wide band and a
# low reef barely shelters anything.
#
# Everything here reads the NavigationMap height grid, which every peer builds
# from the same map (see GameServer._ready), so the client's preview and the
# server's ruling agree without anything being replicated.

## Angle the run-in climbs at, measured up from horizontal at the drop point.
##
## This is the dial that decides how much cover an island is worth, and what it
## is really measured against is the slope of the terrain it has to clear: a
## run-in climbing faster than an island's flank out-climbs the island and is
## shadowed by nothing past the shoreline. The islands on this map rise at
## 5.5-7.8 degrees, so the zone behind them is a narrow collar at 9 degrees and
## widens sharply below about 6 - roughly 200 m of shadow at 9, 700 m at 6 and
## 1450 m at 4, behind the tallest island on the map.
const APPROACH_ANGLE: float = deg_to_rad(9.0)
## Rise over run of that same line - what the height grid is actually walked against.
const SLOPE: float = tan(APPROACH_ANGLE)

## How far the tallest terrain on the map can throw a shadow. Nothing outside
## this radius of land is ever in a dead zone.
static func max_shadow_length() -> float:
	return NavigationMapManager.get_map().get_max_terrain_height() / SLOPE

## Metres of terrain standing above the run-in between `drop` and `carrier`.
## Zero means the line is clear.
static func depth(drop: Vector2, carrier: Vector2) -> float:
	return NavigationMapManager.get_map().terrain_shadow_depth(drop, carrier, SLOPE)

## Whether ordnance may be put on `drop` by a squadron flying off `carrier`.
static func is_blocked(drop: Vector2, carrier: Vector2) -> bool:
	return NavigationMapManager.get_map().is_terrain_shadowed(drop, carrier, SLOPE)

## How much further from the carrier a blocked drop point would have to sit to
## come clear. Moving directly away raises the run-in over every blocker on the
## line at one metre of height per metre of travel, so this is just the depth
## converted back into distance. Zero for a point that is already clear.
static func escape_distance(drop: Vector2, carrier: Vector2) -> float:
	return depth(drop, carrier) / SLOPE
