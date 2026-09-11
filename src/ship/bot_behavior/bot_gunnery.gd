class_name BotGunnery
extends RefCounted

## Picks the shell and the aim point by firing test shells at the target.
##
## A candidate aim point is scored by walking one shell through
## ProjectileManager.sim_process_travel() - the NATIVE armour walk, the same one
## the real shells go through - and paying its HitResult at the rate
## ProjectileManager pays it. The best candidate wins; nothing in this file
## models armour itself.
##
## The answer depends on the target's aspect and range and on nothing else that
## moves, so it is computed per BUCKET of those two and shared by every bot in
## the process. Buckets are refined a few walks a frame (see _probe_bucket).
##
## solve_secondary() asks the same question of the secondary battery, over the
## same grid, walks and table. The difference is that a secondary battery is
## often several calibres at once, so a candidate is scored by what every mount
## that can reach it does there, summed by rate of fire (see _slot_value).

## Damage multipliers by outcome. Mirrors the result switch in
## ProjectileManager::process_hit (projectile_manager.cpp).
##
## Dealt damage, not damage net of repair: heals are limited and on a cooldown,
## so damage a ship has to spend a charge undoing is still damage done.
const DMG_CITADEL: float = 1.0
const DMG_CITADEL_OVERPEN: float = 0.5
const DMG_PENETRATION: float = 1.0 / 3.0
const DMG_OVERPENETRATION: float = 0.1

## What a shell that goes through a TURRET is worth, as a fraction of a shell
## that citadels. HpManager treats a hit on a Type.MODULE part as light damage
## (hp_manager.gd:174).
##
## Applied as a CEILING rather than as a replacement, so results that already
## pay less than a turret penetration keep their own number.
const DMG_TURRET: float = DMG_CITADEL * 0.1
# SHATTER and RICOCHET pay nothing and are represented by scoring zero.


## What a fire is worth, as a fraction of the target's maximum HP.
const FIRE_VALUE_PER_FIRE: float = 0.06

const REASONABLE_NUMBER_OF_FIRES: float = 2.5

## How many shells are walked at each aim point, for each shell type, from each
## mount. Spent a few walks at a time across as many frames as it takes, so this
## sets how well a bucket is answered rather than what a frame can afford.
##
## Twenty because the aim point is a maximum over a thirty-nine point grid, and a
## maximum over noisy estimates is biased upward by roughly the noise itself: at
## a handful of shells apiece the winner is whichever point drew the kindest
## group.
##
## The shells are drawn from ONE DispersionCalculator run continuously rather
## than from a fixed number of independent salvos, the way Gun.fire() draws
## them, because the citadel guarantee counts shells across salvo boundaries.
const SHELLS_PER_SLOT: int = 20

## Aspect bucketing: buckets grow geometrically away from bow-on, are capped at
## the old flat width, and are mirrored about the beam so stern aspects are
## resolved like bow aspects.
##
## Resolution has to be dense near bow-on and nowhere else. The armour walk's
## ricochet angle is a function of T/D - Yamato AP bounces at 55 degrees off
## normal against 410mm, 85 against 25mm - which in aspect is a cliff edge
## somewhere between 5 and 35 degrees depending on the plate the shell finds.
## Above about 60 degrees moving the survey ten degrees changes which plates get
## hit and not what happens when they do. The geometric scale gives
## 0-5-7.5-11-17-25-38: six buckets under forty degrees where there were two.
const ASPECT_BUCKET_DEG: float = 15.0
const ASPECT_BUCKET_RATIO: float = 1.5
const ASPECT_FLOOR_DEG: float = 5.0

## Range bucketing: buckets grow GEOMETRICALLY until their width hits the cap and
## are a fixed width after that.
##
## A bucket is walked at its middle, so flat 2 km buckets answered every fight
## from 0 to 2000 m with shells fired from 1000 m - and how a shell meets a hull
## is governed by range relative to the length of the ship, which moves fast down
## there. On a 281 m hull the bow sits 12.6 degrees off the bearing to the centre
## at 500 m, 6.4 at 1000 m and 1.5 at 4000 m, so point blank the solver surveyed
## a bow it saw nearly square and liked what AP did to it. Ratio 1.5 from a 300 m
## floor gives six buckets under 2 km where there was one.
##
## The width is capped because past a few kilometres what a bucket has to resolve
## is the ballistics - fall angle and striking velocity - which do not flatten out
## with range. Uncapped, ratio 1.5 would hand the 15-23 km band a single bucket.
## The cap is the old flat width, so no bucket is ever coarser than before.
const RANGE_BUCKET_RATIO: float = 1.5
const RANGE_BUCKET_M: float = 2000.0
const RANGE_FLOOR_M: float = 50.0
const RANGE_TOP_M: float = 30000.0

## Which battery a bucket belongs to. The two share the grid, the walks and the
## table, and differ only in what is firing.
const KIND_MAIN: int = 0
const KIND_SECONDARY: int = 1

## The same scale for the secondary battery. Secondaries live inside eight
## kilometres and their penetration falls away across that span, so the main
## battery's cap would put an entire brawl in three buckets.
const SEC_RANGE_BUCKET_M: float = 1000.0
const SEC_RANGE_FLOOR_M: float = 50.0
const SEC_RANGE_TOP_M: float = 12000.0

## Bucket key field indices.
const KEY_KIND: int = 0
const KEY_SHOOTER: int = 1
const KEY_TARGET: int = 2
const KEY_ASPECT: int = 3
const KEY_RANGE: int = 4

## The aim-point matrix, as fractions of the target's length, half-beam and
## above-water extent. Every point is tried with the salvo the guns really throw
## at it - offsets from a live DispersionCalculator with this mount's own sigma
## and this battery's own TargetMod - so no shell in the survey is perfectly
## accurate.
##
## Sampling along the length is most of the point: on an angled ship a shell
## aimed at the bow meets plating at a far better angle than one aimed amidships,
## which is invisible to any model that only varies height. Heights run to the
## top of the whole above-water extent rather than the freeboard, because that is
## where the superstructure is and where battleships shoot each other.
##
## Lateral offsets are fractions of the half-beam, toward the shooter. Aiming at
## the centreline is not aiming at the ship: a shell from abeam strikes the near
## side metres before it reaches x=0, so a point picked for the waterline lands
## on the deck edge above the belt. On Des Moines at 15 km a centreline waterline
## aim overpenetrates 27mm while the same height 6.7m outboard citadels through
## 152mm.
##
## The stations are not uniform because the ship is not: at the ends only the
## centreline is worth a walk, at the quarters all three are, amidships only the
## outboard point is because that is the belt.
##
## Only the near side is sampled - the bucket's geometry puts the shooter at +X
## (see _walk_payout) and solve() mirrors the answer when the shooter is to port,
## so both beams share one bucket.
const HULL_STATIONS := [
	[0.0, [0.95]],
	[-0.25, [0.0, 0.55, 0.95]],
	[0.25, [0.0, 0.55, 0.95]],
	[-0.4, [0.0]],
	[0.4, [0.0]],
]

## Hull heights, as fractions of freeboard: waterline, belt, upper works.
const HULL_HEIGHT_FRACS := [0.05, 0.50, 0.9]

## The superstructure is its own target with its own grid, sized from its own
## mesh: scaling its sample points off the whole hull put them in the water or
## above the masts. Fractions are of the superstructure's own extent.
const SUPER_ALONG_FRACS := [0.2, 0.5, 0.8]
const SUPER_HEIGHT_FRACS := [0.1, 0.6]
const SUPER_LATERAL_FRACS := [0.0, 0.6]

## How far outside the target's own bounds the swept walk segment has to begin
## and end, and the floors under those distances.
##
## The segment has to enter the hull from the side the shell is coming from, and
## at a shallow aspect a fixed straddle does not: a flat secondary trajectory
## 60 m short of a point twenty metres abaft amidships starts on the CENTRELINE,
## inside the armour box, and the walk then meets the belt from behind with no
## bow plating in front of it. On Montana at 1500 m and 22.5 degrees that had a
## 105mm AP shell citing a CITADEL through [409mm, 155mm].
const WALK_MARGIN_M: float = 15.0
const WALK_ENTRY_MIN_M: float = 60.0
const WALK_EXIT_MIN_M: float = 80.0

## How many AIM POINTS of the grid each ACTIVE bucket is walked at per physics
## frame. A point costs one shell of each type from every mount, so a bucket
## spends POINTS_PER_BUCKET_PER_FRAME x 2 x (mounts) walks a frame and takes
## (grid / POINTS_PER_BUCKET_PER_FRAME) frames to complete one pass over it.
##
## The slice is measured in POINTS and not in whole passes because the grid is
## thirty-nine of them and a fleet action is two dozen live buckets: a pass
## apiece was seventy-eight walks per bucket per frame, and the frame paid for
## every point on every hull before any bot had an answer worth more than the
## first. Walking a few points a frame spreads the same survey over more frames
## at a tenth of the per-frame cost, and costs nothing in quality because the
## bucket is finished to exactly the same sample count either way.
##
## What makes a part-walked pass usable is the candidate ORDER: _iterate() goes
## point by point and _aim_candidates() emits HULL_STATIONS in priority order,
## so the points a slice reaches first are the ones most worth reaching. A bot
## asking mid-pass gets the best of the points surveyed so far - see
## _best_so_far() - which starts at the middle of the hull and only improves.
##
## Measuring the slice in points rather than in walks also makes a bucket take
## the same number of frames however many mounts it has to score, so a
## three-calibre secondary battery converges with the main battery instead of
## three times slower.
##
## The budget is per bucket rather than global, and is spent only on buckets
## somebody is asking about THIS frame, so nothing is queued behind anything
## else: a fleet that all sees the same ship from the same quarter costs one
## bucket, and twenty-four separate duels cost twenty-four but are each answered
## in the same number of frames.
##
## Two, measured: a native walk costs tens of microseconds, so four walks is
## about a fifth of a millisecond per bucket per frame and two dozen live buckets
## fit inside a physics frame with room to spare. A full pass was seventy-eight
## walks and twenty-four of those did not fit at all.
const POINTS_PER_BUCKET_PER_FRAME: int = 2

## How many physics frames a bucket stays active after the last request, so a bot
## that solves on alternate ticks does not keep dropping out of the working set.
## Past that the bucket stops being refined but its partial survey is KEPT.
const ACTIVE_WINDOW_FRAMES: int = 1

## Buckets somebody is currently asking about. key -> the physics frame it was
## last requested on.
static var _active: Dictionary = {}
static var _budget_frame: int = -1

## The physics space the survey is walked in: the target's broadphase box, and
## nothing else that exists.
##
## The walk cannot run in the live space, for two reasons that survive the walk
## being the native one.
##
## The terrain ray is collision_mask 1 with no exclude list, and every turret
## carries a GLB-imported `-col` StaticBody3D on layer 1 - so a shell crossing
## the target's own turrets comes back HitResult.TERRAIN, which _walk_payout
## scores as a clean miss, i.e. the whole superstructure row of the grid worth
## nothing. Live shells mostly escape this because
## NativeArmorInteraction::should_raycast_terrain gates the cast behind a
## navigation-map SDF check, but that is a distance test against the map and not
## a promise, and a survey run near an island would take the cast and eat the
## turrets. Here the ray is simply cast into a space with no terrain in it.
##
## And the OBB ray sees other ships' bounding boxes, which would then get baked
## into an answer cached by scene path and shared by the whole team.
##
## Only the OBB has to be here, because that is the broadphase the narrowphase
## hangs off - the armour itself already lives in the ship's own
## PrecisionPhysicsWorld space. There is deliberately no sea: a shell that falls
## short finds nothing and _walk_payout pays that the same as a miss, and the one
## shape that would model an ocean, WorldBoundaryShape3D, hangs a Jolt space.
static var _survey_space: RID = RID()
static var _survey_obbs: Dictionary = {}
## Shape resources are owned here, because a Shape3D whose last reference goes
## away frees its RID out from under the body still using it.
static var _survey_shapes: Array = []


## The native _ProjectileManager, which is where the armour walk lives.
##
## Reached PAST the ProjectileManager autoload deliberately. That autoload is
## ProfiledProjectileManager, a GDScript proxy whose whole job is to make
## projectile calls show up in the profiler as named GDScript frames; a survey
## makes thousands of walks a second and has no use for a profiler frame on each
## of them. Cached because get_raw() is an @onready node lookup.
static var _native_pm: Object = null


## The node to walk shells on, or null before the autoload is up.
static func _projectile_native() -> Object:
	if _native_pm == null or not is_instance_valid(_native_pm):
		_native_pm = ProjectileManager.get_raw() if ProjectileManager != null else null
	return _native_pm


## Payouts by result, from ProjectileManager::process_hit.
##
## Keyed on NativeArmorInteraction's codes, which is the enum the walk in
## _walk_payout() actually reports. SHATTER, RICOCHET, WATER and TERRAIN are
## absent rather than zero: `get` defaults them, and a result that pays nothing
## and a result nobody thought about should not be spelled the same way.
const RESULT_PAYOUT := {
	NativeArmorInteraction.CITADEL: DMG_CITADEL,
	NativeArmorInteraction.CITADEL_OVERPEN: DMG_CITADEL_OVERPEN,
	NativeArmorInteraction.PENETRATION: DMG_PENETRATION,
	NativeArmorInteraction.PARTIAL_PEN: 0.0667,
	NativeArmorInteraction.OVERPENETRATION: DMG_OVERPENETRATION,
}

## Finished buckets, shared by every bot in the process: armour geometry does not
## vary between two ships off the same scene, so neither does the answer.
## key -> { "offset": Vector3, "ammo": int, "payout": float }
static var _aim_table: Dictionary = {}

## Buckets still being probed. key -> { "i": int, "payout": float,
## "offset": Vector3, "ammo": int }
static var _aim_progress: Dictionary = {}

## Range bucket edges per battery kind, built on first use by _range_edges().
static var _range_edge_cache: Dictionary = {}

## Aspect bucket edges, built on first use by _aspect_edges().
static var _aspect_edge_cache: PackedFloat64Array = PackedFloat64Array()


## The shell each battery is currently loaded with against each target, keyed by
## [battery kind, target id]. Per bot, not static: this is the ship's magazine.
##
## Committed only from a FINISHED bucket. Aim can be refined continuously, but
## ammo cannot: engage_target() applies the choice every tick and a salvo fires
## over about a second, so a shell type that changes mid-refinement splits the
## salvo down the middle.
var _committed: Dictionary = {}


## The shell and aim point the MAIN battery should use against `target`, or an
## empty dictionary when no solution can be formed (no armour data, no guns).
##
## `ammo` indexes GunParams.shell1/shell2 the way ArtilleryController.shell_index
## does: 0 for shell1, 1 for shell2. `offset` is in the target's local space.
func solve(shooter: Ship, target: Ship) -> Dictionary:
	return _solve(shooter, target, KIND_MAIN)


## The same question asked of the SECONDARY battery, where the shooter is usually
## more than one calibre: each mount is scored at every candidate and added up by
## rate of fire (see _slot_value), because a point the 150mm penetrates and the
## 105mm shatters on is worth what the SHIP does there.
##
## Worth asking separately rather than reusing the main battery's answer: the
## shells are an order of magnitude lighter and the ranges a third as long, so
## the point that citadels a cruiser with 380mm AP is often the one spot a 105mm
## cannot scratch.
func solve_secondary(shooter: Ship, target: Ship) -> Dictionary:
	return _solve(shooter, target, KIND_SECONDARY)


func _solve(shooter: Ship, target: Ship, kind: int) -> Dictionary:
	if not is_instance_valid(shooter) or not is_instance_valid(target):
		return {}
	var key := _bucket_key(shooter, target, kind)
	var probed := _probe_bucket(key, shooter, target)
	var ck := [kind, target.get_instance_id()]

	if probed.is_empty():
		# Nothing solved and nothing solvable: no armour data, nothing aboard
		# reaches this far, or this was asked outside the physics step. Point at
		# the middle of the hull and keep whatever shell is already loaded;
		# `walked` marks the offset as a guess.
		var held = _committed.get(ck, {})
		return {
			"offset": aim_hint(target),
			"ammo": int(held.get("ammo", _loaded_shell(shooter, kind))),
			"probed": false,
			"walked": false,
		}

	# Commit the shell only once the bucket is finished. Until then the partial
	# answer still steers the guns but may not reload them.
	if _aim_table.has(key):
		_committed[ck] = {"ammo": int(probed["ammo"]), "bucket": key}
	var commitment = _committed.get(ck, {})
	# The bucket was solved with the shooter at +X, since aspect is unsigned.
	# Mirror the answer back onto the side the shooter is really on.
	var offset: Vector3 = probed["offset"]
	if _shooter_side(shooter, target) < 0.0:
		offset.x = -offset.x
	return {
		"offset": offset,
		"ammo": int(commitment.get("ammo", probed["ammo"])),
		"probed": _aim_table.has(key),
		"walked": true,
	}


## What this battery currently has loaded, so a bot with no answer yet keeps
## shooting what it was shooting instead of snapping to a default.
static func _loaded_shell(shooter: Ship, kind: int) -> int:
	var wc = shooter.secondary_controller if kind == KIND_SECONDARY \
		else shooter.artillery_controller
	return int(wc.shell_index) if wc != null and is_instance_valid(wc) else 0


## Upper bucket edges on a scale that starts at `floor_v` and grows by `ratio`
## until a step would exceed `cap`, flat at `cap` thereafter, stopping once
## `top` is covered. Bucket i covers [edges[i - 1], edges[i]) and bucket 0
## everything below edges[0].
static func _geometric_edges(floor_v: float, ratio: float, cap: float,
		top: float) -> PackedFloat64Array:
	var edges := PackedFloat64Array()
	var edge: float = floor_v
	while true:
		edges.append(minf(edge, top))
		if edge >= top:
			break
		edge += minf(edge * (ratio - 1.0), cap)
	return edges


## The upper edges of this battery's range buckets, ascending. Built once per
## kind and held: _bucket_key() asks for it on every solve of every bot against
## every contact.
static func _range_edges(kind: int) -> PackedFloat64Array:
	var cached = _range_edge_cache.get(kind)
	if cached != null:
		return cached
	var sec: bool = kind == KIND_SECONDARY
	var edges := _geometric_edges(
		SEC_RANGE_FLOOR_M if sec else RANGE_FLOOR_M,
		RANGE_BUCKET_RATIO,
		SEC_RANGE_BUCKET_M if sec else RANGE_BUCKET_M,
		SEC_RANGE_TOP_M if sec else RANGE_TOP_M)
	_range_edge_cache[kind] = edges
	return edges


## The upper edges of the aspect buckets, ascending, 0 to 180. The bow half is
## the geometric scale and the stern half is that scale reflected through the
## beam, both meeting at exactly 90 so no bucket straddles the beam.
static func _aspect_edges() -> PackedFloat64Array:
	if not _aspect_edge_cache.is_empty():
		return _aspect_edge_cache
	var bow := _geometric_edges(ASPECT_FLOOR_DEG, ASPECT_BUCKET_RATIO,
		ASPECT_BUCKET_DEG, 90.0)
	var edges := PackedFloat64Array(bow)
	for i in range(bow.size() - 2, -1, -1):
		edges.append(180.0 - bow[i])
	edges.append(180.0)
	_aspect_edge_cache = edges
	return edges


## Which aspect bucket `deg` falls in.
static func _aspect_index(deg: float) -> int:
	var edges := _aspect_edges()
	return mini(edges.bsearch(deg, false), edges.size() - 1)


## The aspect a bucket is solved at: the geometric middle measured from whichever
## end of the scale the bucket is on, because that is the end its resolution was
## bought for. The first and last buckets have no outer edge and borrow the ratio
## for one, which puts them on the steep side of the ricochet cliff.
static func _aspect_center(index: int) -> float:
	var edges := _aspect_edges()
	var i: int = clampi(index, 0, edges.size() - 1)
	var hi: float = edges[i]
	var lo: float = edges[i - 1] if i > 0 else 0.0
	if lo >= 90.0:
		var f_hi: float = 180.0 - lo
		var f_lo: float = 180.0 - hi
		if f_lo <= 0.0:
			f_lo = f_hi / ASPECT_BUCKET_RATIO
		return 180.0 - sqrt(f_lo * f_hi)
	if lo <= 0.0:
		lo = hi / ASPECT_BUCKET_RATIO
	return sqrt(lo * hi)


## The space state the survey walks in, with `target` mirrored into it at its
## live transform. Null when the target has no armour registered, or when the
## physics server will not hand out a state for the space right now.
##
## Public because the probe rig has to walk its shells in the same world.
static func survey_space_state(target: Ship) -> PhysicsDirectSpaceState3D:
	if not is_instance_valid(target):
		return null
	if not _survey_space.is_valid():
		_survey_space = PhysicsServer3D.space_create()
		PhysicsServer3D.space_set_active(_survey_space, true)
		# A space is not queryable until the server has stepped it once, so the
		# frame that creates it gets no state and the caller comes back.
		return null
	var sid: int = target.get_instance_id()
	var body: RID = _survey_obbs.get(sid, RID())
	if not body.is_valid():
		body = _mirror_obb(target)
		if not body.is_valid():
			return null
		_survey_obbs[sid] = body
	# The aim points are read off the target's LIVE transform, so the mirror has
	# to sit on it too. One server call per _iterate(), not per walk.
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM,
		target.global_transform)
	return PhysicsServer3D.space_get_direct_state(_survey_space)


## Copy the target's broadphase box into the survey space.
##
## The body answers as the REAL OBB node's instance id, because that is the
## identity the rest of the pipeline knows the ship by: the armour walk hands
## the ray's collider to PrecisionPhysicsWorld.get_ship_from_obb(), which reads
## its "ship" meta.
static func _mirror_obb(target: Ship) -> RID:
	var entry: Dictionary = PrecisionPhysicsWorld.get_ship_entry(target)
	if entry.is_empty():
		return RID()
	var obb_node = entry.get("obb_body")
	if obb_node == null or not is_instance_valid(obb_node):
		return RID()
	var col: CollisionShape3D = null
	for child in (obb_node as Node).get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			col = child
			break
	if col == null:
		return RID()
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_space(body, _survey_space)
	PhysicsServer3D.body_set_collision_layer(body,
		PrecisionPhysicsWorld.OBB_COLLISION_LAYER)
	PhysicsServer3D.body_set_collision_mask(body, 0)
	PhysicsServer3D.body_attach_object_instance_id(body, obb_node.get_instance_id())
	_survey_shapes.append(col.shape)
	PhysicsServer3D.body_add_shape(body, col.shape.get_rid(), col.transform)
	return body


## Tear the survey space down. RIDs are server-owned and are not collected with
## the script, so they have to go back explicitly.
static func _free_survey_space() -> void:
	for body in _survey_obbs.values():
		PhysicsServer3D.free_rid(body)
	_survey_obbs.clear()
	if _survey_space.is_valid():
		PhysicsServer3D.free_rid(_survey_space)
		_survey_space = RID()
	_survey_shapes.clear()


## Which range bucket `dist` falls in.
static func _range_index(kind: int, dist: float) -> int:
	var edges := _range_edges(kind)
	# false: the index past any exact match, so an edge belongs to the bucket
	# ABOVE it and the intervals stay half-open the way _range_center() reads
	# them. Anything past the last edge saturates on the top bucket, which
	# _batteries() finds nothing to reach with.
	return mini(edges.bsearch(dist, false), edges.size() - 1)


## The range a bucket is solved at: the GEOMETRIC middle, because the buckets are
## geometric and so is parallax across the hull, which goes as 1/range. Bucket
## zero has no lower edge and borrows the ratio for one.
static func _range_center(kind: int, index: int) -> float:
	var edges := _range_edges(kind)
	var i: int = clampi(index, 0, edges.size() - 1)
	var hi: float = edges[i]
	var lo: float = edges[i - 1] if i > 0 else hi / RANGE_BUCKET_RATIO
	return sqrt(lo * hi)


## Which beam the shooter is off, in the target's frame: +1 starboard, -1 port.
static func _shooter_side(shooter: Ship, target: Ship) -> float:
	var local: Vector3 = target.to_local(shooter.global_position)
	return 1.0 if local.x >= 0.0 else -1.0


## Where to point for a target this bot is only CONSIDERING - scoring it as a
## candidate, or asking whether terrain is in the way. Deliberately not a solve:
## pick_target() and led_target_points() ask this of every enemy on the map every
## tick, and they are deciding whether a shot EXISTS, not what it is worth.
func aim_hint(target: Ship) -> Vector3:
	if not is_instance_valid(target) or target.movement_controller == null:
		return Vector3.ZERO
	var freeboard: float = target.movement_controller.ship_height \
		- target.movement_controller.ship_draft
	return Vector3(0.0, maxf(freeboard, 1.0) * 0.35, 0.0)


## Drop cached state for targets that no longer exist.
func forget_dead() -> void:
	pass  # nothing per-target is held any more; the table is keyed by hull


## Throw away everything the solver holds between matches.
##
## The queue and the in-progress buckets hold the actual Ship that opened them,
## and those are freed when the world is torn down (`state["target"]` in
## _iterate). The finished table goes too: a bucket folds in the shooter's
## upgrades and skills, and buckets refill within an engagement anyway.
static func clear_all() -> void:
	_active.clear()
	_aim_progress.clear()
	_aim_table.clear()
	_budget_frame = -1
	_free_survey_space()


## Ask the solver for this bucket's aim point: the best answer worked out so far,
## or empty when there is not one yet.
##
## This is a request, not a computation. Asking is what marks the bucket active,
## and an active bucket is walked at a few more aim points every frame until it
## is done (see _drain).
##
## Opening a bucket walks NOTHING. The caller leaves with an empty answer and
## _solve() points it at the middle of the hull, which is where a survey that
## has seen one shell would point it anyway - the grid leads with the centre
## precisely because it is the answer to fall back on. Paying for a walk here
## made every bot that acquired a target spend an armour traversal inside its own
## tick, off the frame's budget and outside it, and bought a first answer no
## better than the free one. From the next frame on the drain is walking the
## priority stations and each ask picks up whatever that has found.
func _probe_bucket(key: Array, shooter: Ship, target: Ship) -> Dictionary:
	if key.is_empty():
		return {}
	_service_frame()
	if _aim_table.has(key):
		return _aim_table[key]

	if not _aim_progress.has(key):
		var state := _begin_bucket(key, shooter, target)
		if state.is_empty():
			return {}
		_aim_progress[key] = state

	# Asked for this frame, so it is refined this frame - whether it was opened
	# just now or has been sitting half surveyed.
	_active[key] = Engine.get_physics_frames()
	return _best_so_far(key)


## Advance every active bucket, once per physics frame.
##
## Runs on the first solve of the frame, so the working set it reads is
## everything asked for on the PREVIOUS frame. A frame's requests are not all in
## yet when the first bot asks, so scheduling on them would give whichever bot
## ticks first a budget computed from a working set of one.
static func _service_frame() -> void:
	var frame: int = Engine.get_physics_frames()
	if frame == _budget_frame:
		return
	_budget_frame = frame
	_drain()


## Give each active bucket its slice of the grid for this frame. Every active
## bucket gets the same number of aim points, so none is starved by another being
## older, busier or carrying more mounts, and nothing is spent on buckets nobody
## asked for.
static func _drain() -> void:
	var stale: Array = []
	for key in _active:
		if _budget_frame - int(_active[key]) > ACTIVE_WINDOW_FRAMES:
			stale.append(key)  # the fight moved on; keep the survey, drop the claim
			continue
		var state: Dictionary = _aim_progress.get(key, {})
		if state.is_empty():
			stale.append(key)  # finished, or abandoned by _iterate
			continue
		if _iterate(key, POINTS_PER_BUCKET_PER_FRAME * int(state["per_point"])) == 0:
			# No progress possible: called outside the physics step, or the
			# ships that opened the bucket are gone.
			stale.append(key)
	for key in stale:
		_active.erase(key)


## Set up a bucket: the candidates to try, the geometry to try them at, and the
## mounts to try them with. Empty when the request cannot be served.
static func _begin_bucket(key: Array, shooter: Ship, target: Ship) -> Dictionary:
	if not is_instance_valid(shooter) or not is_instance_valid(target):
		return {}
	var kind: int = int(key[KEY_KIND])
	# The middle of the bucket, so the answer is right across it rather than at
	# one edge. Taken from the key, NOT from where the ships happen to be now:
	# the requester may have moved on and the bucket has to stay worth finishing
	# for whoever asks next.
	var range_m: float = _range_center(kind, int(key[KEY_RANGE]))
	var batteries := _batteries(shooter, kind, range_m)
	if batteries.is_empty():
		return {}
	var candidates := _aim_candidates(target)
	if candidates.is_empty():
		return {}
	# Shells per second the whole battery puts out, so a measured per-shell
	# payout converts to a rate.
	var total_rate: float = 0.0
	for b in batteries:
		total_rate += float((b as Dictionary)["rate"])
	# One pass is one shell at every candidate, of both types, from every mount,
	# which is also exactly one of each accumulator - so the slot count and the
	# pass width are the same number.
	var slots: int = candidates.size() * 2 * batteries.size()
	return {
		"i": 0,
		# What one aim point costs in walks, which is what _drain() budgets in.
		"per_point": 2 * batteries.size(),
		"sums": _zeros(slots),
		"counts": _zeros(slots),
		# Walks that actually struck the target, per slot. Separate from `sums`
		# because a shell can land and pay nothing - a shatter starts a fire and
		# does no damage - so the damage mean cannot tell a miss from a bounce.
		"hits": _zeros(slots),
		"target": target,
		"owner": shooter,
		"candidates": candidates,
		"batteries": batteries,
		# Centre of the presented silhouette, for breaking ties between aim
		# points that score the same.
		"center": Vector3(0.0,
			(target.aabb.position.y + target.aabb.size.y) * 0.25, 0.0),
		"salvo_rate": total_rate,
		"aspect": _aspect_center(int(key[KEY_ASPECT])),
		"range": range_m,
	}


## The mounts that can reach `range_m`, as the solver needs them: two shells, a
## spread, and how fast they put shells in the air.
##
## A main battery is one entry. A secondary battery is one entry per calibre,
## because a 150mm and a 105mm meeting the same plate do not get the same answer
## and averaging them describes a gun nobody carries. A mount that cannot reach
## the bucket's range is left out entirely rather than scored zero, or a
## long-armed calibre would look weaker the more short-armed mounts a hull has.
##
## The TargetMod comes along because SecondaryController.fire() hands a gun
## target_mod.dynamic_mod only when its target is the priority target, which is
## exactly the target solve_secondary() is asked about. It comes at its PEAK
## rather than its current value: Advanced Secondary Training ramps over forty
## seconds of continuous fire, a bucket is opened the moment a bot acquires a
## target, and the answer is then cached for the life of the process - so the
## live mod would freeze the fleet's answer at somebody's first salvo.
static func _batteries(shooter: Ship, kind: int, range_m: float) -> Array:
	var found: Array = []
	if kind == KIND_SECONDARY:
		var sec = shooter.secondary_controller
		if sec == null or not is_instance_valid(sec):
			return found
		var mod := _peak_target_mod(shooter, sec.target_mod, true)
		for sc in sec.sub_controllers:
			if sc == null or not is_instance_valid(sc):
				continue
			# The priority target's calculator has the citadel guarantee off
			# (SecondaryController._physics_process), so the solver's must too.
			found.append(_battery(sc.get_params(), sc.get_base_params(), mod,
				(sc.guns as Array).size(), range_m, false))
	else:
		var ac = shooter.artillery_controller
		if ac == null or not is_instance_valid(ac):
			return found
		found.append(_battery(ac.get_params(), ac.get_base_params(),
			_peak_target_mod(shooter, ac.target_mod, false), ac.guns.size(), range_m, true))

	var live: Array = []
	for b in found:
		if b != null:
			live.append(b)
	return live


## The battery's TargetMod as it will be once every skill that ramps has finished
## ramping. A copy, never the live object: the mod layers are rebuilt in place
## whenever a dynamic mod changes.
static func _peak_target_mod(shooter: Ship, mod: Moddable, peak: bool) -> TargetMod:
	var out := TargetMod.new()
	var now := (mod.p() if mod != null else null) as TargetMod
	if now != null:
		out.grouping = now.grouping
		out.h_spread = now.h_spread
		out.v_spread = now.v_spread
	# Only the secondary battery has a mod that ramps, and the hook is named for
	# it: raising the main battery's mod by a secondary skill's ceiling would
	# credit the turrets with a bonus the secondaries earned.
	if peak and shooter.skills != null and is_instance_valid(shooter.skills):
		for id in shooter.skills.skills:
			var skill: Skill = shooter.skills.skills[id]
			if skill != null:
				skill.peak_secondary_target_mod(out)
	return out


## One mount, or null when it has nothing to contribute at this range.
##
## `offsets` is the group this mount actually throws, drawn from a real
## DispersionCalculator with its own sigma once per bucket and reused by every
## walk in it.
static func _battery(p: GunParams, base: GunParams, mod: TargetMod,
		gun_count: int, range_m: float, citadel_guarantee: bool) -> Variant:
	if p == null or gun_count <= 0 or p.reload_time <= 0.0:
		return null
	if p.shell1 == null and p.shell2 == null:
		return null
	if p._range < range_m:
		return null
	var h_spread: float = mod.h_spread if mod != null else 1.0
	var v_spread: float = mod.v_spread if mod != null else 1.0
	var grouping: float = p.grouping * (mod.grouping if mod != null else 1.0)
	# Gun.fire() normalises the range fraction against the BASE range, so a range
	# upgrade widens the group at a given distance rather than moving the whole
	# curve out with it.
	var base_range: float = base._range if base != null else p._range
	return {
		"shell1": p.shell1,
		"shell2": p.shell2,
		"dispersion": _dispersion_at(p, base_range, h_spread, v_spread, range_m),
		"offsets": _salvo_offsets(grouping, citadel_guarantee),
		"rate": float(gun_count) / p.reload_time,
	}


## The shell offsets this mount actually throws, in the -1..1 units
## DispersionCalculator works in: SHELLS_PER_SLOT of them, one per walk pass.
##
## A real DispersionCalculator rather than a model of one - the offsets are a
## stratified truncated Gaussian at the gun's own sigma, shuffled within a salvo,
## with one shell every CITADEL_GUARANTEE_NUM nudged onto the citadel ellipse.
## Taken one shell at a time from a single calculator, refilling when it runs
## dry, exactly the way Gun.fire() takes them: requesting whole salvos instead
## would discard the part of the generator that spans them, since the citadel
## guarantee counts shells and not salvos.
static func _salvo_offsets(grouping: float, citadel_guarantee: bool) -> Array:
	var calc := DispersionCalculator.new(grouping)
	calc._citadel_guarantee_enabled = citadel_guarantee
	var out: Array = []
	for _shell in SHELLS_PER_SLOT:
		if calc._shell_index >= DispersionCalculator.SHELL_COUNT:
			calc._new_salvo(grouping)
		out.append(Vector2(calc._h_offsets[calc._shell_index],
			calc._v_offsets[calc._shell_index]))
		calc._shell_index += 1
	return out


static func _zeros(n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n)
	return out


## Run up to `budget` walks for a bucket. Returns how many it actually spent.
##
## One walk is one shell: an aim point, a shell type, a mount, and one of the
## places a shell aimed there comes down. The bucket is finished when every aim
## point has had all SHELLS_PER_SLOT of them from every mount.
##
## `budget` is a slice of a pass, not a whole one - _drain() sizes it from
## POINTS_PER_BUCKET_PER_FRAME - so this resumes mid-grid from `state["i"]` and
## leaves off mid-grid, and the survey is only ever complete or a priority-
## ordered prefix of a pass ahead of the rest of it.
static func _iterate(key: Array, budget: int) -> int:
	var state: Dictionary = _aim_progress.get(key, {})
	if state.is_empty():
		return 0
	# Read untyped first. A bucket outlives the ships that opened it, and
	# assigning a freed instance to a Ship-typed variable is itself the error,
	# raised before is_instance_valid() gets to answer.
	var target_obj: Object = state["target"]
	var owner_obj: Object = state["owner"]
	if not is_instance_valid(target_obj) or not is_instance_valid(owner_obj):
		_aim_progress.erase(key)
		return 0
	var target: Ship = target_obj
	var owner: Ship = owner_obj
	var space := survey_space_state(target)
	if space == null:
		return 0  # no armour registered yet, or no state right now; try again

	var candidates: Array = state["candidates"]
	var batteries: Array = state["batteries"]
	var nb: int = batteries.size()
	# Breadth first, aim point by aim point: every point gets one shell of each
	# type from every mount before any gets a second look. Walking one shell type
	# or one calibre to exhaustion first would leave the bucket choosing between a
	# full survey and a single data point - and this way a bucket stopped on a
	# pass boundary is a whole survey at a smaller sample rather than part of a
	# survey.
	#
	# A frame's slice is smaller than a pass (see POINTS_PER_BUCKET_PER_FRAME),
	# so the usual stopping point is mid-pass: the leading points at n + 1 shells
	# and the trailing ones at n. That is why the aim point is the SLOWEST-moving
	# index here rather than the fastest - it makes the part of the grid a slice
	# has reached a prefix of _aim_candidates(), which is in priority order, so
	# the extra shell always goes to the points most worth having it.
	var per_pass: int = candidates.size() * 2 * nb
	var total: int = per_pass * SHELLS_PER_SLOT
	var sums: PackedFloat64Array = state["sums"]
	var counts: PackedFloat64Array = state["counts"]
	var hits: PackedFloat64Array = state["hits"]
	var spent: int = 0
	while int(state["i"]) < total and spent < budget:
		var i: int = state["i"]
		var pass_i: int = i / per_pass
		var within: int = i % per_pass
		var bi: int = within % nb
		var rest: int = within / nb
		var ammo: int = rest % 2
		var ci: int = rest / 2
		var battery: Dictionary = batteries[bi]
		var shell: ShellParams = battery["shell1"] if ammo == 0 else battery["shell2"]
		if shell != null:
			var slot: int = (ammo * candidates.size() + ci) * nb + bi
			# Every aim point in a pass is walked with the SAME offset, so two
			# points are compared on one shell of one draw rather than on two
			# different ones.
			var walk: Vector2 = _walk_payout(target, owner, shell, candidates[ci],
				(battery["offsets"] as Array)[pass_i], float(state["aspect"]),
				float(state["range"]), battery["dispersion"], space)
			sums[slot] += walk.x
			hits[slot] += walk.y
			counts[slot] += 1.0
		state["i"] = i + 1
		spent += 1

	if int(state["i"]) >= total:
		_aim_progress.erase(key)
		_aim_table[key] = _best_of(state)
	else:
		_aim_progress[key] = state
	return spent


## The best (aim point, shell) pair.
##
## The two halves are not decided the same way, because the battery does not get
## to. The AIM POINT is chosen by its best value: the guns are told where to
## point and they point there. The SHELL is chosen by the grid's mean, because a
## magazine is committed for a whole engagement, every mount fires it, and mounts
## engaging anything but the priority target are aimed at the deckhouse by
## SecondaryController rather than at the solved point at all.
##
## Deciding both by the best point is what had secondaries loading AP into
## bow-on battleships: AP's value across the grid is bimodal where HE's is flat,
## so the best of thirty-nine noisy AP estimates sits far above AP's mean while
## the best HE estimate sits close to HE's. On Montana at 1500 m and 22.5
## degrees, AP's best point read 301 damage a shell against HE's 173, while over
## the whole bucket the two were level at 171 apiece.
##
## The mean is weighted by how often shells aimed at a point actually arrive.
## Points where AP ricochets are NOT excluded - they are the measurement.
##
## Ties on the aim point go to the one nearest the centre of mass: whole bands of
## the hull resolve identically, and without a rule the winner is whichever the
## loop happened to reach first.
static func _best_of(state: Dictionary) -> Dictionary:
	var candidates: Array = state["candidates"]
	var center: Vector3 = state["center"]
	var target: Ship = state["target"]
	var n: int = candidates.size()

	# What AP is actually worth here, measured - ricochets, overpenetrations and
	# all - rather than assumed from nominal shell damage.
	var ap_mean: float = _ammo_mean(state, 0, 0.0)

	# A fire is damage over TIME, so it is only worth what the guns could not have
	# done in the same time. Where AP out-damages the burn the bonus is cut in
	# proportion; where AP mostly bounces the fire keeps its full value.
	var fire_scale: float = 1.0
	var ap_dps: float = ap_mean * float(state["salvo_rate"])
	if ap_dps > 0.0:
		var fp := target.fire_manager.fparams.p() as DOTParams \
			if target.fire_manager != null and target.fire_manager.fparams != null else null
		if fp != null:
			var fire_dps: float = fp.dmg_rate * target.health_controller.max_hp
			fire_scale = clampf(fire_dps / ap_dps, 0.0, 1.0)

	var he_mean: float = _ammo_mean(state, 1, fire_scale)

	# Second choice is a real fallback: the shell that wins the average can still
	# have no point worth firing at, and an empty answer would drop the bot back
	# to whatever it had loaded rather than to the shell that works here.
	for ammo in ([1, 0] if he_mean > ap_mean else [0, 1]):
		var best: float = 0.0
		var best_ci: int = -1
		var best_dist: float = INF
		for ci in n:
			var value: float = _slot_value(state, ammo * n + ci)
			if value <= 0.0:
				continue
			# HE slots carry the fire the shell would start where it lands,
			# times how often a shell aimed there lands at all.
			if ammo == 1:
				value += _fire_value_rated(state, ci) * fire_scale
			var dist: float = (candidates[ci] as Vector3).distance_to(center)
			if value > best or (is_equal_approx(value, best) and dist < best_dist):
				best = value
				best_dist = dist
				best_ci = ci
		if best_ci >= 0:
			return {
				"offset": candidates[best_ci] as Vector3,
				"ammo": ammo,
				"payout": best,
			}
	return {}


## What one shell of `ammo` is worth here, averaged across the grid. This is the
## number the magazine is committed on.
##
## An average and not a maximum because the battery cannot spend the whole
## engagement firing at one point on one hull at one aspect, and because the
## maximum of a set of noisy estimates is not an estimate of anything - see
## _best_of(). Weighted by arrivals; a point that lands and pays nothing still
## counts in full, because a ricochet is the measurement.
static func _ammo_mean(state: Dictionary, ammo: int, fire_scale: float) -> float:
	var n: int = (state["candidates"] as Array).size()
	var total: float = 0.0
	var weight: float = 0.0
	for ci in n:
		var slot: int = ammo * n + ci
		var value: float = _slot_value(state, slot)
		if value < 0.0:
			continue  # nothing walked here yet
		var w: float = _landed(state, slot)
		if w <= 0.0:
			continue
		if ammo == 1:
			value += _fire_value_rated(state, ci) * fire_scale
		total += value * w
		weight += w
	return total / weight if weight > 0.0 else 0.0


## How often a shell aimed at this slot's point reaches the target at all,
## rate-weighted across the mounts the same way the damage is, in 0..1.
static func _landed(state: Dictionary, slot: int) -> float:
	var batteries: Array = state["batteries"]
	var counts: PackedFloat64Array = state["counts"]
	var hits: PackedFloat64Array = state["hits"]
	var rate: float = float(state["salvo_rate"])
	if rate <= 0.0:
		return 0.0
	var total: float = 0.0
	for bi in batteries.size():
		var idx: int = slot * batteries.size() + bi
		if counts[idx] <= 0.0:
			continue
		total += (hits[idx] / counts[idx]) * float((batteries[bi] as Dictionary)["rate"])
	return total / rate


## What one shell of this ship's fire is worth at one aim point with one shell
## type, in damage. Negative when nothing has been walked there yet.
##
## `slot` is an (ammo, aim point) pair and every mount that can reach stores its
## own running mean underneath it. They are summed weighted by how fast each
## mount fires - a 150mm penetration and a 105mm shatter are different events, so
## a mean over both would describe neither - and then divided by the ship's total
## rate, which leaves the answer in damage-per-shell. The division is by a
## constant and cannot change which point wins; it keeps the number in the same
## units as when only a single turret battery ever asked.
static func _slot_value(state: Dictionary, slot: int) -> float:
	var batteries: Array = state["batteries"]
	var sums: PackedFloat64Array = state["sums"]
	var counts: PackedFloat64Array = state["counts"]
	var nb: int = batteries.size()
	var rate: float = float(state["salvo_rate"])
	if rate <= 0.0:
		return -1.0
	var total: float = 0.0
	var walked: bool = false
	for bi in nb:
		var idx: int = slot * nb + bi
		if counts[idx] <= 0.0:
			continue
		walked = true
		total += (sums[idx] / counts[idx]) * float((batteries[bi] as Dictionary)["rate"])
	return total / rate if walked else -1.0


## The fire an HE shell of this ship's starts at candidate `ci`, rate-weighted
## across the mounts the same way the direct damage is, and weighted by how often
## a shell aimed there actually arrives.
##
## The hit rate keeps the comparison honest. Fire chance is a property of the
## shell, so without it every candidate carried the same fire bonus whether the
## salvo lands on the hull or throws three of four shells into the sea, while the
## AP slots pay for their misses - which is HE looking best exactly where gunnery
## is worst.
##
## Landed, not damaging: process_hit() applies fire buildup on every hit on an
## enemy hull, so a shatter counts here.
static func _fire_value_rated(state: Dictionary, ci: int) -> float:
	var batteries: Array = state["batteries"]
	var candidates: Array = state["candidates"]
	var counts: PackedFloat64Array = state["counts"]
	var hits: PackedFloat64Array = state["hits"]
	var target: Ship = state["target"]
	var nb: int = batteries.size()
	var rate: float = float(state["salvo_rate"])
	if rate <= 0.0:
		return 0.0
	var local_aim: Vector3 = candidates[ci]
	var total: float = 0.0
	for bi in nb:
		var b: Dictionary = batteries[bi]
		var he: ShellParams = b["shell2"]
		if he == null:
			continue
		# The HE slot for this mount at this point. Unwalked mounts abstain
		# rather than vote zero, the same way _slot_value() treats them.
		var idx: int = (candidates.size() + ci) * nb + bi
		if counts[idx] <= 0.0:
			continue
		var landed: float = hits[idx] / counts[idx]
		total += _fire_value(he, target, local_aim) * landed * float(b["rate"])
	return total / rate


## The best answer for a bucket so far, finished or not.
##
## Scored at most ONCE per bucket per frame and handed out from there. _best_of()
## is a sweep of the whole grid - two means over it, plus a fire lookup per
## candidate - and this is asked on every solve() of every bot, twice per bot per
## tick (behavior.gd calls it for the aim point and again for the shell) and once
## more for every bot sharing the bucket. Twenty-four duels came to a hundred
## sweeps a frame over an answer that changes at most once in it.
##
## The cache is keyed on the bucket's walk count, so it survives exactly as long
## as the survey has not moved: _iterate() advancing `i` retires it on its own
## with nothing to invalidate. A bucket nobody is draining holds its answer, and
## a finished one is in _aim_table and never reaches here.
static func _best_so_far(key: Array) -> Dictionary:
	if _aim_table.has(key):
		return _aim_table[key]
	var state: Dictionary = _aim_progress.get(key, {})
	if state.is_empty():
		return {}
	# Nothing walked yet, so there is nothing to be best. Says so without
	# sweeping a grid of empty accumulators to find it out - the frame a bucket
	# is opened, every bot on it takes this path.
	if int(state["i"]) == 0:
		return {}
	# Same freed-instance guard as _iterate(): _best_of() reads the target as a
	# Ship, so an unfinished bucket whose target has gone is dropped, not scored.
	if not is_instance_valid(state["target"]) or not is_instance_valid(state["owner"]):
		_aim_progress.erase(key)
		return {}
	if int(state.get("best_i", -1)) == int(state["i"]):
		return state["best"]
	var best := _best_of(state)
	state["best_i"] = state["i"]
	state["best"] = best
	return best


## Candidate aim points in the target's local space, in PRIORITY ORDER.
##
## Order is load-bearing, not cosmetic. A bucket is walked a couple of aim points
## a frame (see POINTS_PER_BUCKET_PER_FRAME), so at any moment before it finishes
## the part of the grid that has been surveyed is a PREFIX of this list, and the
## answer a bot leaves with is the best of that prefix. Reordering this changes
## what every bot in the process aims at for the first few seconds of every
## engagement.
##
## HULL_STATIONS leads, in its own order - amidships outboard, then the quarters,
## then the ends - and each station is walked waterline first, because that is
## where the citadels come from. The superstructure grid comes last: it is the
## answer when nothing can penetrate, and nothing-can-penetrate is a conclusion
## the hull points have to be walked to reach.
static func _aim_candidates(target: Ship) -> Array:
	var mc = target.movement_controller
	if mc == null:
		return []
	var length: float = mc.ship_length
	var freeboard: float = mc.ship_height - mc.ship_draft
	if length <= 0.0 or freeboard <= 0.0:
		return []
	var half_beam: float = target.aabb.size.x * 0.5
	if half_beam <= 0.0:
		half_beam = maxf(target.beam, 1.0) * 0.5

	var out: Array = []
	for station in HULL_STATIONS:
		var along: float = float(station[0])
		for lf in (station[1] as Array):
			for hf in HULL_HEIGHT_FRACS:
				out.append(Vector3(half_beam * float(lf), freeboard * float(hf),
					length * along))

	var ss: AABB = _superstructure_bounds(target)
	if ss.size.y > 0.0:
		for af in SUPER_ALONG_FRACS:
			for hf in SUPER_HEIGHT_FRACS:
				for lf in SUPER_LATERAL_FRACS:
					out.append(Vector3(
						ss.position.x + ss.size.x * (0.5 + 0.5 * float(lf)),
						ss.position.y + ss.size.y * float(hf),
						ss.position.z + ss.size.z * float(af)))
	return out


## The salvo's spread in metres at `dist`, horizontal and vertical. Same curve
## sampling DispersionCalculator._sample_dispersion() does, including the linear
## extrapolation past maximum range, and the same TargetMod scaling on the
## ceilings that Gun.fire() applies.
static func _dispersion_at(p: GunParams, base_range: float, h_spread: float,
		v_spread: float, dist: float) -> Vector2:
	var t: float = maxf(dist / maxf(base_range, 1.0), 0.0)
	return Vector2(
		_sample_curve(p.dispersion_, t, p.max_h_disp * h_spread),
		_sample_curve(p.v_dispersion_, t, p.max_v_disp * v_spread))


static func _sample_curve(curve: Curve, t: float, max_disp: float) -> float:
	if curve == null:
		return 0.0
	if t <= 1.0:
		return curve.sample(t) * max_disp
	var slope: float = curve.get_point_left_tangent(curve.point_count - 1)
	return (curve.sample(1.0) + slope * (t - 1.0)) * max_disp


## Where one shell of a salvo aimed at `candidate` comes down, given that shell's
## own offset from the draw.
##
## As DispersionCalculator.calculate_dispersed_launch() does it, including that
## the ellipse lies in the plane perpendicular to the GUN-TO-AIM-POINT line and
## not to the shell's terminal path. A shell lobbed fifteen kilometres leaves on
## a chord a few degrees below horizontal and arrives at thirty, so an ellipse
## built on the arrival direction walks short and long of the target instead of
## up and down its side.
static func _sample_point(target: Ship, candidate: Vector3, offset: Vector2,
		dispersion: Vector2, from: Vector3) -> Vector3:
	var aim: Vector3 = target.to_global(candidate)
	var forward: Vector3 = (aim - from).normalized()
	var right: Vector3 = forward.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = forward.cross(Vector3.RIGHT)
	right = right.normalized()
	var up: Vector3 = right.cross(forward).normalized()
	var world: Vector3 = aim \
		+ right * (offset.x * dispersion.x * 0.5) \
		+ up * (offset.y * dispersion.y * 0.5)
	return target.to_local(world)


## The superstructure's extent in the target's local space, or a zero-size AABB
## when the hull has none.
##
## Anchored at the node's own position, which IS the deck, rather than taken from
## the transformed mesh AABB: the mesh is authored in ship coordinates, so its
## AABB spans the whole hull - on Montana 36m wide by 35m tall from 0.6m up,
## masts and funnels included.
##
## Ship.gd records the superstructure MESH, not its ArmorPart, because
## ArmorPart.position is never assigned and reads (0,0,0) for every zone on every
## hull.
static func _superstructure_bounds(target: Ship) -> AABB:
	var ss = target.super_structure
	if ss == null or not is_instance_valid(ss) or not (ss is MeshInstance3D):
		return AABB()
	var mesh_aabb: AABB = (ss as MeshInstance3D).get_aabb()
	if mesh_aabb.size == Vector3.ZERO:
		return AABB()

	# Corners through the mesh transform into ship space, so a rotated or offset
	# deckhouse still bounds correctly.
	var to_ship: Transform3D = target.global_transform.affine_inverse() \
		* (ss as Node3D).global_transform
	var box := AABB(to_ship * mesh_aabb.position, Vector3.ZERO)
	for i in 8:
		box = box.expand(to_ship * mesh_aabb.get_endpoint(i))

	# Raise the floor to the deck and take the same amount off the HEIGHT, so the
	# box spans deck to masthead. Moving the floor without shrinking the box
	# would just push the sample points higher into the masts.
	var deck_y: float = target.to_local((ss as Node3D).global_position).y
	if deck_y > box.position.y:
		var lift: float = deck_y - box.position.y
		box.position.y = deck_y
		box.size.y = maxf(box.size.y - lift, 0.0)
	return box


## What a fire started at `local_aim` is worth, or zero if that section of the
## ship is already alight: Fire._apply_build_up() ignores a hit while
## lifetime > 0, so a shell landing on a burning section buys nothing. Hence the
## aim point rather than just the shell.
static func _fire_value(shell: ShellParams, target: Ship,
		local_aim: Vector3) -> float:
	if shell.fire_buildup <= 0.0 or not is_instance_valid(target):
		return 0.0
	var fm = target.fire_manager
	if fm == null or fm.rparams == null:
		return 0.0
	var rp := fm.rparams.p() as ResistanceParams
	if rp == null or rp.max_buildup <= 0.0:
		return 0.0

	# The section this aim point belongs to is the nearest fire node to it.
	var nearest: Fire = null
	var nearest_d: float = INF
	for f in fm.fires:
		if f == null:
			continue
		var d: float = (f as Fire).position.distance_squared_to(local_aim)
		if d < nearest_d:
			nearest_d = d
			nearest = f
	if nearest != null and nearest.lifetime > 0.0:
		return 0.0

	var chance: float = clampf(shell.fire_buildup / rp.max_buildup, 0.0, 1.0)
	return chance * target.health_controller.max_hp * FIRE_VALUE_PER_FIRE


## How far back along `dir` the swept segment has to start, and how far past the
## aim point it has to end, so that it crosses the target from outside to
## outside. A slab test against the hull's own bounding box in the hull's own
## frame, which is what makes the answer aspect-aware: abeam it asks for barely a
## beam's worth and the floors win, bow-on it asks for most of a ship length.
##
## The box is grown by a margin because a dispersed sample can land outside it,
## and because entering exactly at the box face is entering too late.
static func _walk_span(target: Ship, to: Vector3, dir: Vector3) -> Vector2:
	var box: AABB = target.aabb
	if box.size == Vector3.ZERO:
		return Vector2(WALK_ENTRY_MIN_M, WALK_EXIT_MIN_M)
	box = box.grow(WALK_MARGIN_M)
	var lp: Vector3 = target.to_local(to)
	var ld: Vector3 = (target.global_basis.inverse() * dir).normalized()
	var lo: Vector3 = box.position
	var hi: Vector3 = box.end
	var t_enter: float = -INF
	var t_exit: float = INF
	for axis in 3:
		var d: float = ld[axis]
		if absf(d) < 0.0001:
			continue
		var t0: float = (lo[axis] - lp[axis]) / d
		var t1: float = (hi[axis] - lp[axis]) / d
		t_enter = maxf(t_enter, minf(t0, t1))
		t_exit = minf(t_exit, maxf(t0, t1))
	# A ray parallel to every axis it could leave by, or an aim point the slabs
	# disagree about, leaves these infinite. The diagonal caps both.
	var cap: float = box.size.length()
	return Vector2(
		maxf(minf(-t_enter, cap), WALK_ENTRY_MIN_M),
		maxf(minf(t_exit, cap), WALK_EXIT_MIN_M))


## Fire one real shell at one aim point and return what the game would pay for
## the result, as (damage, landed): what the hit paid, and 1 if the shell reached
## the target ship at all. A shatter or a ricochet pays nothing and still counts
## as landed, because ProjectileManager::process_hit calls apply_fire_damage() on
## every hit on an enemy hull.
##
## The firing position is synthesised from the bucket rather than read off the
## shooter, which is what lets a bucket be shared and finished later. `owner` is
## still a real ship because process_travel() treats an owner-less projectile as
## visual-only: it skips find_valid_obb_hit() entirely and takes the raw
## broadphase hit, so the shell can meet the shooter's own hull.
static func _walk_payout(target: Ship, owner: Ship, shell: ShellParams,
		candidate: Vector3, offset: Vector2, aspect_deg: float, range_m: float,
		dispersion: Vector2, space: PhysicsDirectSpaceState3D) -> Vector2:
	var a := deg_to_rad(aspect_deg)
	# Aspect 0 is bow-on; the hull faces -Z.
	var bearing: Vector3 = target.global_basis * Vector3(sin(a), 0.0, -cos(a))
	var from: Vector3 = target.global_position + bearing * range_m \
		+ Vector3(0.0, maxf(owner.movement_controller.ship_draft * 0.5, 5.0), 0.0)

	# Where this shell of the group comes down. The ellipse is built off the
	# firing position, exactly as the guns build it, so no second launch solve is
	# needed to find the arrival direction first.
	var local_aim: Vector3 = _sample_point(target, candidate, offset, dispersion, from)
	var to: Vector3 = target.to_global(local_aim)

	var launch: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(from, to, shell)
	if launch.is_empty() or not launch[0]:
		return Vector2.ZERO
	var tof: float = launch[1]
	var impact_vel: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
		launch[0], tof, shell)
	var dir: Vector3 = impact_vel.normalized()

	# Cross the hull from outside to outside, and start clear of the sea: a
	# segment beginning underwater is rejected outright. The span is measured
	# against the target rather than fixed - see _walk_span().
	var span: Vector2 = _walk_span(target, to, dir)
	var prev_pos: Vector3 = to - dir * span.x
	if prev_pos.y <= 1.0:
		return Vector2.ZERO

	var proj := ProjectileData.new()
	proj.initialize(to + dir * span.y, launch[0], 0.0, shell, owner, [])
	proj.set_frame_count(1)

	# The NATIVE walk, the one live shells go through. Not the GDScript
	# ArmorInteraction autoload of the same name: that is the pre-port
	# implementation, it is still loaded for legacy and debug callers, and it does
	# not answer the same as the shells do - which makes it worthless as the thing
	# a survey measures. See _ProjectileManager::sim_process_travel_impl.
	var pm := _projectile_native()
	if pm == null:
		return Vector2.ZERO
	var res: Dictionary = pm.sim_process_travel(proj, prev_pos, tof, space)
	if not bool(res.get("hit", false)):
		return Vector2.ZERO
	# Whatever the shell met, it has to have been the ship being asked about. The
	# segment straddles the aim point by well over a beam, so in a brawl it can
	# cross a third ship first. A terrain hit lands here too, which is correct:
	# an island in the last hundred metres is a shot not worth taking.
	if res.get("ship") != target:
		return Vector2.ZERO
	var payout: float = float(RESULT_PAYOUT.get(int(res["result_type"]), 0.0))
	if PrecisionPhysicsWorld.is_turret_part(res.get("armor_part")):
		payout = minf(payout, DMG_TURRET)
	var direct: float = payout * shell.damage
	# Direct damage only, and it can legitimately be zero on a landed shell. The
	# fire bonus depends on what AP turned out to be worth against this hull at
	# this geometry and on how often shells aimed here arrive, neither of which
	# is known until the bucket has been walked - see _best_of().
	return Vector2(maxf(direct, 0.0), 1.0)


## A bucket is a battery, a shooter hull, a target hull, an aspect and a range.
## Nothing else changes the answer, so two bots of the same class looking at the
## same enemy from the same quarter are asking one question.
##
## The battery leads because a hull's turrets and its secondaries are different
## questions about the same pair of ships, and do not even bucket range the same
## way (see _range_edges).
static func _bucket_key(shooter: Ship, target: Ship, kind: int = KIND_MAIN) -> Array:
	if shooter.scene_file_path.is_empty() or target.scene_file_path.is_empty():
		return []
	var disp: Vector3 = shooter.global_position - target.global_position
	var aspect: float = rad_to_deg((-(target.global_basis.z as Vector3)).angle_to(disp))
	return [
		kind,
		shooter.scene_file_path,
		target.scene_file_path,
		_aspect_index(aspect),
		_range_index(kind, disp.length()),
	]
