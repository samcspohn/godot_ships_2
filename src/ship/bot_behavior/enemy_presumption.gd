extends RefCounted
class_name EnemyPresumption

## Where the enemy probably is, for the ships nobody currently has a fix on.
##
## A human reading the minimap does not think "there is one enemy and it is at
## the only place I can see one". They think "their line came off that spawn,
## something is off my flank by now, and nothing has come round the north island
## yet". Bots had none of that: an enemy that had never been spotted did not
## exist at all, so a cruiser would take cover from the single contact it could
## see while sitting broadside to the half of the map it had never looked at.
##
## This builds the missing half of the picture out of things the whole lobby
## already has - the spawn positions, the clock, and the enemy team list - plus
## whatever the team has actually observed. It never reads a live enemy position.
##
## `server` is left untyped on purpose. GameServer publishes this same picture
## into the shared threat registry, so naming the type here would make the two
## scripts reference each other and leave the parser resolving a cycle.
##
## What comes out is deliberately coarse: a position, and a radius saying how
## wrong it might be. It is for POSITIONING ONLY - cover, standoff, where to
## send a search. Nothing here may pick a target or aim a weapon. A guess is not
## a contact, and ordnance is only ever committed against something the team is
## genuinely holding (see Behavior._contact_is_strikeable).

## How fast a fleet is presumed to advance out of its spawn, in m/s. Well under
## what a ship can steam: a line advances at the pace of its slowest, angling and
## turning the whole way, and stops entirely once the shooting starts.
const ADVANCE_SPEED: float = 30.0
## The advance stops here - fleets settle at roughly a gun range apart and trade
## rather than steaming into each other, so nobody is presumed to be past the
## point where that would have happened.
const ENGAGEMENT_GAP: float = 16000.0
## Half-width of the front the enemy line is presumed to be spread across. Not
## the map width: fleets converge on the middle, they do not hug the edges.
const LINE_HALF_WIDTH: float = 9000.0

## Uncertainty, as a radius around the presumed position: where it starts, how
## fast it grows with time since anything was actually observed, and the point
## past which "somewhere over there" stops getting any vaguer.
const RADIUS_MIN: float = 1500.0
const RADIUS_GROWTH: float = 6.0
const RADIUS_MAX: float = 9000.0

# Geometry of this battle, resolved once: the spawn axis everything is measured
# along, its perpendicular, and how far up it a fleet is presumed to come.
var _ready_geometry: bool = false
var _enemy_spawn: Vector3 = Vector3.ZERO
var _axis: Vector3 = Vector3.ZERO
var _lateral: Vector3 = Vector3.ZERO
var _max_advance: float = 0.0

# One build per physics frame is plenty - several systems ask per tick.
var _cache: Array[Dictionary] = []
var _cache_frame: int = -1


## Every enemy `my_team` is not holding right now, as
## {ship, position, radius, advance_mult}. One instance serves one team - the
## per-frame cache does not distinguish them. `lead` projects the whole picture
## that many seconds further on, for deciding where something should be SENT
## rather than where it is now.
func contacts(my_team: int, server, lead: float = 0.0) -> Array[Dictionary]:
	if server == null:
		return []
	if lead <= 0.0 and _cache_frame == Engine.get_physics_frames():
		return _cache

	var enemy_team: int = 1 - my_team
	if not _resolve_geometry(server, my_team, enemy_team):
		return []

	var roster: Array = server.get_team_ships(enemy_team)
	var lkp: Dictionary = server.get_unspotted_enemies(my_team)
	var times: Dictionary = server.get_unspotted_enemy_times(my_team)
	var now: float = Time.get_ticks_msec() / 1000.0
	var out: Array[Dictionary] = []

	for i in range(roster.size()):
		var enemy: Ship = roster[i]
		if not is_instance_valid(enemy) or not enemy.is_alive():
			continue
		# Held for real: there is nothing to presume about a ship the team can
		# see, and a guess must never displace an observation.
		if enemy.visible_to_enemy:
			continue
		var anchor: Vector3
		var age: float
		if lkp.has(enemy):
			# Last seen somewhere specific. That still says which flank it is
			# on, however old it is - the guess is how much further along it has
			# got since, not a fresh position.
			anchor = lkp[enemy]
			age = maxf(now - float(times.get(enemy, now)), 0.0)
		else:
			# Never seen at all. Everything known about it is that it came off
			# their spawn, so it is placed in the line abreast of its fleet and
			# advanced with it (see _line_station).
			anchor = _line_station(i, roster.size())
			age = server.match_elapsed
		var elapsed: float = age + lead
		out.append({
			ship = enemy,
			position = _advance(anchor, elapsed, _advance_mult(enemy)),
			radius = clampf(RADIUS_MIN + elapsed * RADIUS_GROWTH, RADIUS_MIN, RADIUS_MAX),
			advance_mult = _advance_mult(enemy),
		})

	if lead <= 0.0:
		_cache = out
		_cache_frame = Engine.get_physics_frames()
	return out


## How well pinned down a presumption is, 0 (a rumour) to 1 (as good as a
## sighting), from its own uncertainty radius. Consumers map this onto whatever
## scale they work in - how hard to route around it, how much to fear it.
static func certainty(guess: Dictionary) -> float:
	var span: float = RADIUS_MAX - RADIUS_MIN
	if span <= 0.0:
		return 1.0
	return clampf(1.0 - (float(guess.radius) - RADIUS_MIN) / span, 0.0, 1.0)


## Runs one presumed contact further forward - for asking where a ship will be
## by the time something sent after it actually arrives.
func project(guess: Dictionary, seconds: float) -> Vector3:
	if not _ready_geometry or seconds <= 0.0:
		return guess.position
	return _advance(guess.position, seconds, float(guess.get("advance_mult", 1.0)))


## Advances `anchor` along the spawn axis by however far a fleet could have come
## in `seconds`, never past the line where the two sides would have met.
func _advance(anchor: Vector3, seconds: float, mult: float) -> Vector3:
	var travelled: float = (anchor - _enemy_spawn).dot(_axis)
	var room: float = maxf(_max_advance - travelled, 0.0)
	var step: float = minf(maxf(seconds, 0.0) * ADVANCE_SPEED * mult, room)
	return _clamp_to_map(anchor + _axis * step)


## Where in the enemy line a ship nobody has ever seen is presumed to sit. Spread
## evenly across the front by roster order, which is the same list for every bot
## on the team, so they all picture the same enemy line rather than each
## inventing its own.
func _line_station(index: int, count: int) -> Vector3:
	var offset: float = 0.0
	if count > 1:
		offset = (float(index) / float(count - 1) - 0.5) * 2.0 * LINE_HALF_WIDTH
	return _clamp_to_map(_enemy_spawn + _lateral * offset)


## How far up the advance each class is presumed to have pushed. Destroyers lead,
## battleships come along behind their screen, and a carrier has barely left the
## line it spawned on.
static func _advance_mult(enemy: Ship) -> float:
	match enemy.ship_class:
		Ship.ShipClass.DD:
			return 1.3
		Ship.ShipClass.CA:
			return 1.0
		Ship.ShipClass.BB:
			return 0.85
		Ship.ShipClass.CV:
			return 0.25
	return 1.0


static func _clamp_to_map(pos: Vector3) -> Vector3:
	return Vector3(
		clampf(pos.x, -Ship.MAP_BOUNDARY, Ship.MAP_BOUNDARY),
		0.0,
		clampf(pos.z, -Ship.MAP_BOUNDARY, Ship.MAP_BOUNDARY))


func _resolve_geometry(server, my_team: int, enemy_team: int) -> bool:
	if _ready_geometry:
		return true
	var friendly_spawn: Vector3 = server.get_team_spawn_position(my_team)
	_enemy_spawn = server.get_team_spawn_position(enemy_team)
	if friendly_spawn == Vector3.ZERO and _enemy_spawn == Vector3.ZERO:
		return false
	var span: Vector3 = friendly_spawn - _enemy_spawn
	span.y = 0.0
	if span.length_squared() < 1.0:
		return false
	_enemy_spawn.y = 0.0
	_axis = span.normalized()
	_lateral = Vector3(-_axis.z, 0.0, _axis.x)
	_max_advance = maxf((span.length() - ENGAGEMENT_GAP) * 0.5, 0.0)
	_ready_geometry = true
	return true
