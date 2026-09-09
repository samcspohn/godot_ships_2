class_name BotGunnery
extends RefCounted

## Picks the shell and the aim point, by firing test shells at the target.
##
## Replaces three per-class tables (BBBehavior/CABehavior/DDBehavior each had
## their own target_aim_offset()) that answered "what is the target and how is
## it angled" with a match on Ship.ShipClass. That works exactly as long as
## every hull of a class carries the same guns, and stops working the moment a
## heavy cruiser mounts 380mm or a battleship mounts 305mm - at which point
## "shooting at a cruiser" and "being a cruiser" have come apart, and only one
## of them was ever the question.
##
## It does not model armour. An earlier version did - patches with normals and
## thicknesses, a line of flight, a plate sequence - and probing it against the
## real walk (test/aim_probe.tscn) showed it confidently wrong where it mattered
## most: it scored citadels through Bismarck's belt, and 180 real walks with her
## own 380mm AP produce not one, at any range, aspect or aim point. Her citadel
## sits behind the belt AND behind a canted plate, and nothing reasoning from
## patch centroids was going to discover that.
##
## So the shells decide. A candidate aim point is tested by firing one at it
## through ArmorInteraction.process_travel() - the same entry point the real
## shells go through, OBB broadphase into precision narrowphase into the
## plate-by-plate walk - and scoring the HitResult at the rate
## ProjectileManager pays it. The best candidate wins. There is no second
## opinion about the physics anywhere in this file.
##
## What makes that affordable is that the answer is coarse. It depends on the
## target's aspect and range and on nothing else that moves, so it is computed
## per BUCKET of those two and shared by every bot in the battle: twenty
## destroyers of one class looking at the same enemy from the same quarter are
## asking one question. Buckets are solved by a budgeted service a few walks per
## frame (see _probe_bucket), so a division of ships lighting up at once costs
## the same as a quiet minute.
##
## The class rules that used to be written out longhand are simply gone. AP at a
## destroyer is not a special case; it is an arming-threshold failure that the
## walk reports as OVERPENETRATION, and HE wins the comparison on payout.
##
## The secondary battery asks the same question through solve_secondary(), and
## gets it answered by the same grid, the same walks and the same table. The one
## thing that differs is that a secondary battery is frequently several calibres
## at once, so a candidate is scored by what EVERY mount that can reach it does
## there, added up by rate of fire (see _slot_value). A point the 150mm penetrates
## and the 105mm shatters on is worth what the ship does there, not what either
## mount would say on its own - and a mount that cannot reach the range at all is
## left out rather than allowed to vote zero.

## Damage multipliers by outcome. Mirrors the result switch in
## ProjectileManager::process_hit (projectile_manager.cpp).
##
## Dealt damage, deliberately - not damage net of repair. Heals are limited in
## number and on a cooldown, so damage a ship has to spend a charge undoing is
## still damage done, and discounting it by the repair rate undervalues volume
## fire against a hull that has already used its charges.
const DMG_CITADEL: float = 1.0
const DMG_CITADEL_OVERPEN: float = 0.5
const DMG_PENETRATION: float = 1.0 / 3.0
const DMG_OVERPENETRATION: float = 0.1
# SHATTER and RICOCHET pay nothing and are represented by scoring zero.

## Bucket widths for the solution cache. A solution is reused while the target
## stays in the same aspect and range bucket, so these decide how often the work
## is redone: wide enough that a fight at steady range recomputes almost never,
## narrow enough that the answer is still right across a bucket.

## ---------------------------------------------------------------------------
## Ground-truth aim table
## ---------------------------------------------------------------------------
##
## The patch model above is an approximation, and probing it against the real
## armour walk (test/aim_probe.tscn) showed it is wrong where it matters most:
## it scores citadels through Bismarck's belt, and 180 real walks with her own
## 380mm AP produce not one, at any range, aspect or aim point. Her citadel is a
## box behind the belt AND behind a canted plate, and no model that reasons from
## patch centroids is going to discover that.
##
## So the real walk decides. For a bucket of (shooter hull, target hull, aspect,
## range) a grid of candidate aim points is fired at with ArmorInteraction.
## process_travel() - the same entry point the shells go through - and the point
## with the best payout is kept. That is one answer per bucket, computed once
## and reused by every bot in the fleet for the rest of the process.
##
## The cost is paid a few walks at a time. Until a bucket is finished the patch
## model answers, which is what it is for: something defensible immediately,
## replaced by something true shortly after.

## What a fire is worth, as a fraction of the target's maximum HP: average
## total fire damage against a hull with a normal commander build and upgrades.
const FIRE_VALUE_PER_FIRE: float = 0.06

const REASONABLE_NUMBER_OF_FIRES: float = 2.5

## The salvo: one perfectly accurate shell, then three placed in the dispersion
## ellipse. Positions are in the -1..1 units DispersionCalculator uses for its
## _h_offsets/_v_offsets, scaled at solve time by the real spread at the real
## range.
##
## The first shell is the point of the exercise - it says what this aim point is
## worth if the gun does what it is told, which is the thing being chosen
## between. The other three say what actually arrives. Scoring only the exact
## shell picks aim points that need perfect gunnery; scoring only the spread
## loses the citadel that a good aim point is FOR, which is how a broadside
## Des Moines ends up being shot at with HE.
const SALVO_SAMPLES := [
	Vector2(0.0, 0.0),
	Vector2(0.58, 0.34),
	Vector2(-0.58, -0.34),
	Vector2(0.58, -0.34),
]

## Bucket widths. Fine enough that a bucket's answer is still right in the
## middle of it, coarse enough that the table fills within an engagement.
const ASPECT_BUCKET_DEG: float = 15.0
const RANGE_BUCKET_M: float = 2000.0

## Which battery a bucket belongs to. The two share everything in this file -
## the same grid, the same walks, the same table - and differ only in what is
## firing: one turret battery throwing one shell, or several mounts of different
## calibres whose results have to be added up before a point can be judged.
const KIND_MAIN: int = 0
const KIND_SECONDARY: int = 1

## Range bucket width for the secondary battery. Secondaries live inside eight
## kilometres and their penetration falls away across that span, so the main
## battery's 2 km buckets would put an entire brawl in three of them.
const SEC_RANGE_BUCKET_M: float = 1000.0

## Bucket key layout. Named because the key grew a leading field and the
## positional reads were getting hard to check.
const KEY_KIND: int = 0
const KEY_SHOOTER: int = 1
const KEY_TARGET: int = 2
const KEY_ASPECT: int = 3
const KEY_RANGE: int = 4

## The aim-point matrix, as fractions of the target's length and of its
## freeboard. Every point is tried with a perfectly accurate shell and the best
## one wins - dispersion is not modelled here, because the question is where
## this gun WANTS to put a shell, not where a given salvo happens to land.
##
## Sampling along the length is not a refinement, it is most of the point. On an
## angled ship the bow is both further ahead and more rounded, so a shell aimed
## there meets plating at a far better angle than one aimed amidships - which is
## how Yamato citadels a battleship through its bow, and is invisible to any
## model that only varies height.
## Heights are fractions of the ship's whole above-water extent, not of its
## freeboard. Freeboard is the HULL - Ship.movement_controller derives it from
## the hull AABB - and stopping there put the top of the grid below the
## superstructure, which is where battleships shoot each other. A shell that
## cannot arm on a belt will bounce off a deck at medium range and arm on the
## way down into the superstructure, and none of that is reachable from an aim
## point six metres up a sixteen-metre ship.
## The hull grid, as stations along the keel and the lateral offsets worth
## trying at each. Lateral offsets are fractions of the half-beam, toward the
## shooter; along fractions are of the ship's length.
##
## Aiming at the centreline is not aiming at the ship: a shell coming in from
## abeam strikes the near side metres before it reaches x=0, so a point picked
## for the waterline lands on the deck edge above the belt, and at long range on
## the deck itself. Measured on Des Moines at 15 km, a centreline waterline aim
## overpenetrates 27mm of plating while the same height 6.7m outboard citadels
## through 152mm. Ballistic drop is not the problem and never was -
## calculate_launch_vector() solves the arc that lands exactly on the aim point,
## so the trajectory is always right for the point chosen. The point was wrong.
##
## The stations are not uniform because the ship is not. At the very ends only
## the centreline is worth a walk - there is no beam left to be outboard of. At
## the quarters all three matter, because that is where a bow or stern citadel
## is reached. Amidships only the outboard point matters, because that is the
## belt, and a centreline aim there is the failure above.
##
## Only the near side is sampled. In the bucket's synthesised geometry the
## shooter always sits at +X (see _walk_payout), and solve() mirrors the answer
## when the real shooter is to port - so both beams share one bucket.
const HULL_STATIONS := [
	[-0.45, [0.0]],
	[-0.25, [0.0, 0.55, 0.95]],
	[0.0, [0.95]],
	[0.25, [0.0, 0.55, 0.95]],
	[0.45, [0.0]],
]

## Hull heights, as fractions of freeboard: waterline, belt, upper works.
const HULL_HEIGHT_FRACS := [0.05, 0.30, 0.70]

## The superstructure is its own target with its own grid, sized from its own
## mesh rather than from the ship. It is where battleships shoot each other -
## a shell that cannot arm on a belt will arm in a deckhouse - and scaling its
## sample points off the whole hull put them either in the water or above the
## masts. Fractions are of the superstructure's own extent.
const SUPER_ALONG_FRACS := [0.2, 0.5, 0.8]
const SUPER_HEIGHT_FRACS := [0.1, 0.6]
const SUPER_LATERAL_FRACS := [0.0, 0.6]

## How many real walks the solver spends per physics frame, across every bot in
## the battle. This is the whole point of routing requests through one service:
## a destroyer lighting up an enemy division must not turn into every bot on the
## team solving at once, and a fixed budget means the worst case costs the same
## as the quiet case.
const SOLVER_BUDGET_PER_FRAME: int = 50

## Buckets waiting for budget, oldest first.
static var _queue: Array = []
static var _budget_frame: int = -1
static var _budget_left: int = 0

## Payouts by result, from ProjectileManager::process_hit. Same table the
## analytic path uses, keyed by HitResult instead of by outcome name.
const RESULT_PAYOUT := {
	ArmorInteraction.HitResult.CITADEL: DMG_CITADEL,
	ArmorInteraction.HitResult.CITADEL_OVERPEN: DMG_CITADEL_OVERPEN,
	ArmorInteraction.HitResult.PENETRATION: DMG_PENETRATION,
	ArmorInteraction.HitResult.PARTIAL_PEN: 0.0667,
	ArmorInteraction.HitResult.OVERPENETRATION: DMG_OVERPENETRATION,
}

## Finished buckets, shared by every bot in the process: armour geometry does
## not vary between two ships off the same scene, so neither does the answer.
## key -> { "offset": Vector3, "ammo": int, "payout": float }
static var _aim_table: Dictionary = {}

## Buckets still being probed. key -> { "i": int, "payout": float,
## "offset": Vector3, "ammo": int }
static var _aim_progress: Dictionary = {}


## The shell each battery is currently loaded with against each target, keyed by
## [battery kind, target id]. Per bot, not static: it is this ship's magazine,
## not a fact about the world.
##
## Ammo is committed only from a FINISHED bucket. Aim can be refined
## continuously - moving the aim point a metre between salvos costs nothing -
## but ammo cannot: engage_target() applies the choice every tick and a salvo
## fires over about a second, so a shell type that changes while a bucket is
## still refining splits the salvo down the middle. Replay 1788733215 has Wotan
## doing exactly that to a Des Moines, twenty AP then nineteen HE inside one
## second, salvo after salvo, when AP was worth 1.5x HE throughout.
var _committed: Dictionary = {}



## The shell and aim point the MAIN battery should use against `target`, or an
## empty dictionary when no solution can be formed (no armour data, no guns).
##
## `ammo` indexes GunParams.shell1/shell2 the way ArtilleryController.shell_index
## does: 0 for shell1, 1 for shell2. `offset` is in the target's local space, so
## callers rotate it by whichever contact basis they believe in.
func solve(shooter: Ship, target: Ship) -> Dictionary:
	return _solve(shooter, target, KIND_MAIN)


## The same question asked of the SECONDARY battery.
##
## Same grid, same walks, same table - the only thing that differs is who is
## shooting, and for secondaries that is usually more than one gun. A hull with
## a 150mm and a 105mm battery gets both scored at every candidate and added up
## by rate of fire (see _slot_value), because a point the 150mm penetrates and
## the 105mm shatters on is worth what the SHIP does there, not what either
## mount would say on its own.
##
## Worth asking separately rather than reusing the main battery's answer: the
## shells are an order of magnitude lighter and the ranges are a third as long,
## so the aim point that citadels a cruiser with 380mm AP is frequently the one
## spot a 105mm cannot scratch.
func solve_secondary(shooter: Ship, target: Ship) -> Dictionary:
	return _solve(shooter, target, KIND_SECONDARY)


func _solve(shooter: Ship, target: Ship, kind: int) -> Dictionary:
	if not is_instance_valid(shooter) or not is_instance_valid(target):
		return {}
	var key := _bucket_key(shooter, target, kind)
	var probed := _probe_bucket(key, shooter, target)
	var ck := [kind, target.get_instance_id()]

	if probed.is_empty():
		# Nothing solved yet and nothing solvable - the target has no armour
		# data, nothing aboard reaches this far, or this is being asked outside
		# the physics step. Point at the middle of the hull, which is never
		# stupid, and keep whatever shell is already loaded rather than dropping
		# back to a default mid-fight. `walked` says the offset is a guess, so a
		# caller with a better fallback of its own can use it instead.
		var held = _committed.get(ck, {})
		return {
			"offset": aim_hint(target),
			"ammo": int(held.get("ammo", _loaded_shell(shooter, kind))),
			"probed": false,
			"walked": false,
		}

	# Commit the shell only once the bucket is finished. Until then the partial
	# answer still steers the guns - it is a real walk, just not the whole
	# survey - but it may not reload them.
	if _aim_table.has(key):
		_committed[ck] = {"ammo": int(probed["ammo"]), "bucket": key}
	var commitment = _committed.get(ck, {})
	# The bucket was solved with the shooter at +X in the target's frame, because
	# aspect is unsigned and port and starboard are the same question. Mirror the
	# answer back onto the side the shooter is really on.
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


static func _range_bucket(kind: int) -> float:
	return SEC_RANGE_BUCKET_M if kind == KIND_SECONDARY else RANGE_BUCKET_M


## Which beam the shooter is off, in the target's frame: +1 starboard, -1 port.
static func _shooter_side(shooter: Ship, target: Ship) -> float:
	var local: Vector3 = target.to_local(shooter.global_position)
	return 1.0 if local.x >= 0.0 else -1.0


## Where to point for a target this bot is only CONSIDERING - scoring it as a
## candidate, or asking whether terrain is in the way. Deliberately not a solve.
##
## pick_target() and led_target_points() ask this of every enemy on the map,
## every tick. Answering them with the full model meant a bot spent its frame
## deciding how best to hurt ships it had no intention of shooting at, which is
## what the profiler was showing: _patch_value five hundred times a frame.
##
## The middle of the visible hull is all these callers need - they are deciding
## whether a shot EXISTS, not what it is worth - and it costs two field reads.
func aim_hint(target: Ship) -> Vector3:
	if not is_instance_valid(target) or target.movement_controller == null:
		return Vector3.ZERO
	var freeboard: float = target.movement_controller.ship_height \
		- target.movement_controller.ship_draft
	return Vector3(0.0, maxf(freeboard, 1.0) * 0.35, 0.0)


## Drop cached state for targets that no longer exist.
func forget_dead() -> void:
	pass  # nothing per-target is held any more; the table is keyed by hull




## Ask the solver for this bucket's aim point. Returns the best answer worked
## out so far - which after the first call is already something to shoot at -
## or empty if the bucket has not been started and the target is unusable.
##
## This is a request, not a computation. The caller never runs the whole solve;
## it puts the bucket on the queue, is guaranteed one iteration so it leaves
## with an answer, and picks up a better one each time it asks. See _drain().
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
		_queue.append(key)
		# One iteration on the spot, off-budget. A bot that has just been given
		# a target must not have to wait a frame to know where to point, and
		# the candidate order below puts the safe answer first so that this one
		# walk is worth having on its own.
		_iterate(key, 1)

	return _best_so_far(key)


## Refill the budget and spend it, once per physics frame.
##
## The budget is what makes this safe when a destroyer lights up a whole enemy
## fleet at once: twenty bots asking about a new contact do not become twenty
## full solves, they become entries on one queue that drains at a fixed rate.
## Bots of the same hull looking at the same target from the same place are
## asking the same question, so they collapse onto one bucket before the budget
## is even consulted.
static func _service_frame() -> void:
	var frame: int = Engine.get_physics_frames()
	if frame == _budget_frame:
		return
	_budget_frame = frame
	_budget_left = SOLVER_BUDGET_PER_FRAME
	_drain()


## Spend the frame's budget on the oldest unfinished buckets.
static func _drain() -> void:
	while _budget_left > 0 and not _queue.is_empty():
		var key: Array = _queue[0]
		if not _aim_progress.has(key):
			_queue.pop_front()  # finished or abandoned elsewhere
			continue
		var spent := _iterate(key, _budget_left)
		_budget_left -= spent
		if not _aim_progress.has(key):
			_queue.pop_front()  # this bucket finished
		elif spent == 0:
			_queue.pop_front()  # cannot make progress; drop it
			_aim_progress.erase(key)


## Set up a bucket: the candidates to try, the geometry to try them at, and the
## mounts to try them with. Empty when the request cannot be served.
static func _begin_bucket(key: Array, shooter: Ship, target: Ship) -> Dictionary:
	if not is_instance_valid(shooter) or not is_instance_valid(target):
		return {}
	var kind: int = int(key[KEY_KIND])
	# The middle of the bucket, so the answer is right across it rather than at
	# one edge. Taken from the key, NOT from where the two ships happen to be
	# now: the requester may have moved on, and the bucket has to stay worth
	# finishing for whoever asks next.
	var range_m: float = (float(key[KEY_RANGE]) + 0.5) * _range_bucket(kind)
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
	var slots: int = candidates.size() * 2 * batteries.size()
	return {
		"i": 0,
		"sums": _zeros(slots),
		"counts": _zeros(slots),
		"target": target,
		"owner": shooter,
		"candidates": candidates,
		"batteries": batteries,
		# Centre of the presented silhouette, for breaking ties between aim
		# points that score the same.
		"center": Vector3(0.0,
			(target.aabb.position.y + target.aabb.size.y) * 0.25, 0.0),
		"salvo_rate": total_rate,
		"aspect": (float(key[KEY_ASPECT]) + 0.5) * ASPECT_BUCKET_DEG,
		"range": range_m,
	}


## The mounts that can reach `range_m`, as the solver needs them: two shells, a
## spread, and how fast they put shells in the air.
##
## A main battery is one entry and always was. A secondary battery is one entry
## per calibre, because a 150mm and a 105mm meeting the same plate do not get
## the same answer, and averaging their parameters into a notional shell would
## have the solver reasoning about a gun nobody carries.
##
## A mount that cannot reach the bucket's range is left out entirely rather than
## scored zero. At this range it is not performing badly, it is absent - and
## letting it into the rate would make a long-armed calibre look weaker the more
## short-armed mounts a hull happens to be carrying.
static func _batteries(shooter: Ship, kind: int, range_m: float) -> Array:
	var found: Array = []
	if kind == KIND_SECONDARY:
		var sec = shooter.secondary_controller
		if sec == null or not is_instance_valid(sec):
			return found
		for sc in sec.sub_controllers:
			if sc == null or not is_instance_valid(sc):
				continue
			found.append(_battery(sc.get_params(), (sc.guns as Array).size(), range_m))
	else:
		var ac = shooter.artillery_controller
		if ac == null or not is_instance_valid(ac):
			return found
		found.append(_battery(ac.get_params(), ac.guns.size(), range_m))

	var live: Array = []
	for b in found:
		if b != null:
			live.append(b)
	return live


## One mount, or null when it has nothing to contribute at this range.
static func _battery(p: GunParams, gun_count: int, range_m: float) -> Variant:
	if p == null or gun_count <= 0 or p.reload_time <= 0.0:
		return null
	if p.shell1 == null and p.shell2 == null:
		return null
	if p._range < range_m:
		return null
	return {
		"shell1": p.shell1,
		"shell2": p.shell2,
		"dispersion": _dispersion_at(p, range_m),
		"rate": float(gun_count) / p.reload_time,
	}


static func _zeros(n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n)
	return out


## Run up to `budget` walks for a bucket. Returns how many it actually spent.
##
## One walk is one shell of one salvo: an aim point, a shell type, and one of
## the places a shell aimed there comes down. The bucket is finished when every
## combination has been fired.
static func _iterate(key: Array, budget: int) -> int:
	var state: Dictionary = _aim_progress.get(key, {})
	if state.is_empty():
		return 0
	var target: Ship = state["target"]
	var owner: Ship = state["owner"]
	if not is_instance_valid(target) or not is_instance_valid(owner):
		_aim_progress.erase(key)
		return 0
	var space := target.get_world_3d().direct_space_state
	if space == null:
		return 0  # outside the physics step; the queue keeps the bucket

	var candidates: Array = state["candidates"]
	var batteries: Array = state["batteries"]
	var nb: int = batteries.size()
	# Breadth first: every aim point gets one shell of each type from every
	# mount before any gets a second look. Walking AP to exhaustion first would
	# leave the bucket choosing between fully-surveyed AP and a single HE data
	# point, and walking one calibre to exhaustion first would do the same to
	# the other calibre.
	var per_pass: int = candidates.size() * 2 * nb
	var total: int = per_pass * SALVO_SAMPLES.size()
	var sums: PackedFloat64Array = state["sums"]
	var counts: PackedFloat64Array = state["counts"]
	var spent: int = 0
	while int(state["i"]) < total and spent < budget:
		var i: int = state["i"]
		var sample: int = i / per_pass
		var within: int = i % per_pass
		var bi: int = within % nb
		var rest: int = within / nb
		var ammo: int = rest % 2
		var ci: int = rest / 2
		var battery: Dictionary = batteries[bi]
		var shell: ShellParams = battery["shell1"] if ammo == 0 else battery["shell2"]
		if shell != null:
			var slot: int = (ammo * candidates.size() + ci) * nb + bi
			sums[slot] += _walk_payout(target, owner, shell, candidates[ci],
				sample, float(state["aspect"]), float(state["range"]),
				battery["dispersion"], space)
			counts[slot] += 1.0
		state["i"] = i + 1
		spent += 1

	if int(state["i"]) >= total:
		_aim_progress.erase(key)
		_aim_table[key] = _best_of(state)
	else:
		_aim_progress[key] = state
	return spent


## The best (aim point, shell) pair, by payout.
##
## Ties go to the aim point nearest the centre of mass. They are common - whole
## bands of the hull resolve identically - and without a rule the winner is
## whichever the loop happened to reach first, which is an arbitrary corner of
## the bow. Aiming at the middle of a ship is what a gunner does when two spots
## are worth the same, and it is the choice that degrades most gracefully when
## the target turns or the range estimate is off.
static func _best_of(state: Dictionary) -> Dictionary:
	var candidates: Array = state["candidates"]
	var center: Vector3 = state["center"]
	var target: Ship = state["target"]
	var n: int = candidates.size()

	# What AP is actually worth here, measured - ricochets, overpenetrations and
	# all. A synthetic rate off nominal shell damage says a Des Moines threatens
	# a battleship with every shell; the bucket says most of them bounce or sail
	# through, and the fire has to be weighed against what really lands.
	var best_ap: float = 0.0
	for ci in n:
		best_ap = maxf(best_ap, _slot_value(state, ci))

	# A fire is damage over TIME, so it is only worth what the guns could not
	# have done in the same time. Where AP out-damages the burn the bonus is cut
	# in proportion; where AP mostly bounces the fire keeps its full value, which
	# is why HE stays right against a hull AP cannot hurt.
	var fire_scale: float = 1.0
	var ap_dps: float = best_ap * float(state["salvo_rate"])
	if ap_dps > 0.0:
		var fp := target.fire_manager.fparams.p() as DOTParams \
			if target.fire_manager != null and target.fire_manager.fparams != null else null
		if fp != null:
			var fire_dps: float = fp.dmg_rate * target.health_controller.max_hp
			fire_scale = clampf(fire_dps / ap_dps, 0.0, 1.0)

	var best: float = 0.0
	var best_slot: int = -1
	var best_dist: float = INF
	for slot in n * 2:
		var value: float = _slot_value(state, slot)
		if value <= 0.0:
			continue
		# HE slots carry the fire the shell would start where it lands.
		if slot >= n:
			value += _fire_value_rated(state, candidates[slot % n]) * fire_scale
		var dist: float = (candidates[slot % n] as Vector3).distance_to(center)
		if value > best or (is_equal_approx(value, best) and dist < best_dist):
			best = value
			best_dist = dist
			best_slot = slot
	if best_slot < 0:
		return {}
	return {
		"offset": candidates[best_slot % n] as Vector3,
		"ammo": best_slot / n,
		"payout": best,
	}


## What one shell of this ship's fire is worth at one aim point with one shell
## type, in damage. Negative when nothing has been walked there yet.
##
## `slot` is an (ammo, aim point) pair; every mount that can reach stores its own
## running mean underneath it. They have to be added up before the point can be
## judged - a 150mm penetration and a 105mm shatter are different events, and a
## mean over both would describe neither - and they are added up weighted by how
## fast each mount fires, so a battery that shoots twice as often counts twice.
## That is the DPM the choice is really being made on.
##
## The sum is then divided by the ship's total rate of fire, which leaves the
## answer in damage-per-shell. The division is by a constant, so it cannot change
## which point wins; what it buys is that the number means the same thing here as
## it did when only a single turret battery ever asked, so the fire comparison
## above and the payouts in the table do not silently change units the moment a
## second calibre appears.
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


## The fire an HE shell of this ship's starts at `local_aim`, rate-weighted the
## same way the direct damage is - a hull whose fires are mostly lit by a fast
## 105mm battery should be credited for that battery's fire chance, not for the
## six-second 150mm's.
static func _fire_value_rated(state: Dictionary, local_aim: Vector3) -> float:
	var batteries: Array = state["batteries"]
	var target: Ship = state["target"]
	var rate: float = float(state["salvo_rate"])
	if rate <= 0.0:
		return 0.0
	var total: float = 0.0
	for b in batteries:
		var he: ShellParams = (b as Dictionary)["shell2"]
		if he == null:
			continue
		total += _fire_value(he, target, local_aim) * float((b as Dictionary)["rate"])
	return total / rate


## The best answer for a bucket so far, finished or not.
static func _best_so_far(key: Array) -> Dictionary:
	if _aim_table.has(key):
		return _aim_table[key]
	var state: Dictionary = _aim_progress.get(key, {})
	if state.is_empty():
		return {}
	return _best_of(state)


## Candidate aim points in the target's local space, best guess first.
##
## Order matters now that the first walk is the answer a bot leaves with: the
## middle of the freeboard leads, because it is what a ship aims at when it has
## no better idea, and the waterline follows because the probe showed citadels
## come from there and nowhere else.
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
## extrapolation past maximum range, so the bot reasons about the group its own
## guns actually throw.
static func _dispersion_at(gun_params: GunParams, dist: float) -> Vector2:
	var t: float = maxf(dist / maxf(gun_params._range, 1.0), 0.0)
	return Vector2(
		_sample_curve(gun_params.dispersion_, t, gun_params.max_h_disp),
		_sample_curve(gun_params.v_dispersion_, t, gun_params.max_v_disp))


static func _sample_curve(curve: Curve, t: float, max_disp: float) -> float:
	if curve == null:
		return 0.0
	if t <= 1.0:
		return curve.sample(t) * max_disp
	var slope: float = curve.get_point_left_tangent(curve.point_count - 1)
	return (curve.sample(1.0) + slope * (t - 1.0)) * max_disp


## Where one shell of a salvo aimed at `candidate` comes down. Sample 0 is the
## aim point itself; the rest sit in the dispersion ellipse, which lies in the
## plane perpendicular to the shell's path.
static func _sample_point(target: Ship, candidate: Vector3, sample: int,
		dispersion: Vector2, dir: Vector3) -> Vector3:
	if sample % SALVO_SAMPLES.size() == 0:
		return candidate
	var spread: Vector2 = SALVO_SAMPLES[sample % SALVO_SAMPLES.size()]
	var right: Vector3 = dir.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = dir.cross(Vector3.RIGHT)
	right = right.normalized()
	var up: Vector3 = right.cross(dir).normalized()
	var world: Vector3 = target.to_global(candidate) \
		+ right * (spread.x * dispersion.x * 0.5) \
		+ up * (spread.y * dispersion.y * 0.5)
	return target.to_local(world)


## The superstructure's extent in the target's local space, or a zero-size AABB
## when the hull has none.
##
## Anchored at the node's own position, which IS the deck, rather than taken
## from the transformed mesh AABB. The mesh is authored in ship coordinates, so
## transforming its AABB produces a box that starts at the waterline and spans
## the whole hull - on Montana that read 36m wide by 35m tall starting 0.6m up,
## which is the entire superstructure mesh including masts and funnels, not
## something to aim at.
##
## Ship.gd records the superstructure MESH (super_structure), not its ArmorPart:
## ArmorPart.position is never assigned anywhere and reads (0,0,0) for every
## zone on every hull, so the mesh node is the only thing that knows where the
## deckhouse actually sits.
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

	# Raise the floor to the deck and take the same amount off the HEIGHT. The
	# mesh is authored in ship coordinates, so its box starts at the waterline
	# and its height is the whole ship - on Montana that is 35m from y=0.6, and
	# fractions of it land in the water at the bottom and in the masts at the
	# top. Moving the floor without shrinking the box just moves the masts
	# higher; what is wanted is the span from the deck to the top of the mesh.
	var deck_y: float = target.to_local((ss as Node3D).global_position).y
	if deck_y > box.position.y:
		var lift: float = deck_y - box.position.y
		box.position.y = deck_y
		box.size.y = maxf(box.size.y - lift, 0.0)
	return box


## What a fire started at `local_aim` is worth, or zero if that section of the
## ship is already alight.
##
## Fire._apply_build_up() ignores a hit while lifetime > 0, so a shell landing
## on a burning section buys nothing: the fire it would have started is already
## burning, and crediting it again is how HE ends up overvalued everywhere. Only
## the section actually aimed at matters, which is why this takes the aim point
## rather than just the shell.
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
	# Fire._apply_build_up() ignores a hit while lifetime > 0, so a shell landing
	# on a section already alight buys nothing - the fire it would have started
	# is already burning.
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


## Fire one real shell at one aim point and return what the game would pay for
## the result. This is ArmorInteraction.process_travel(), not a model of it.
##
## The firing position is synthesised from the bucket rather than read off the
## shooter. That is what lets a bucket be shared and finished later: the answer
## belongs to an aspect and a range, not to whoever happened to ask. `owner` is
## still a real ship because process_travel() treats an owner-less projectile as
## visual-only and returns null without resolving armour at all.
static func _walk_payout(target: Ship, owner: Ship, shell: ShellParams,
		candidate: Vector3, sample: int, aspect_deg: float, range_m: float,
		dispersion: Vector2, space: PhysicsDirectSpaceState3D) -> float:
	var a := deg_to_rad(aspect_deg)
	# Aspect 0 is bow-on; the hull faces -Z.
	var bearing: Vector3 = target.global_basis * Vector3(sin(a), 0.0, -cos(a))
	var from: Vector3 = target.global_position + bearing * range_m \
		+ Vector3(0.0, maxf(owner.movement_controller.ship_draft * 0.5, 5.0), 0.0)

	# Solve to the aim point once to learn which way the shell arrives; the
	# dispersion ellipse lies in the plane perpendicular to that.
	var local_aim: Vector3 = candidate
	if sample % SALVO_SAMPLES.size() != 0:
		var aimed: Vector3 = target.to_global(candidate)
		var first: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(from, aimed, shell)
		if first.is_empty() or not first[0]:
			return 0.0
		var aim_dir: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
			first[0], first[1], shell).normalized()
		local_aim = _sample_point(target, candidate, sample, dispersion, aim_dir)
	var to: Vector3 = target.to_global(local_aim)

	var launch: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(from, to, shell)
	if launch.is_empty() or not launch[0]:
		return 0.0
	var tof: float = launch[1]
	var impact_vel: Vector3 = ProjectilePhysicsWithDragV2.calculate_velocity_at_time(
		launch[0], tof, shell)
	var dir: Vector3 = impact_vel.normalized()

	# Straddle the aim point so the swept segment crosses the hull, and start it
	# clear of the sea: a segment beginning underwater is rejected outright.
	var prev_pos: Vector3 = to - dir * 60.0
	if prev_pos.y <= 1.0:
		return 0.0

	var proj := ProjectileData.new()
	proj.initialize(to + dir * 80.0, launch[0], 0.0, shell, owner, [])
	proj.set_frame_count(1)

	var res = ArmorInteraction.process_travel(proj, prev_pos, tof, space)
	if res == null:
		return 0.0
	# Whatever the shell met, it has to have been the ship we were asking about.
	# The swept segment straddles the aim point by well over a hull's beam, so
	# in a close-quarters brawl it can cross a third ship first - and scoring
	# that ship's armour as this one's would have the bot load AP for a
	# battleship it is not shooting at. A terrain hit lands here too, which is
	# correct: an island in the last hundred metres is a shot not worth taking.
	if res.ship != target:
		return 0.0
	var direct: float = float(RESULT_PAYOUT.get(res.result_type, 0.0)) * shell.damage
	if direct <= 0.0:
		return 0.0
	# Direct damage only. The fire bonus depends on what AP turned out to be
	# worth against THIS hull at THIS geometry, which is not known until the
	# bucket's AP slots have been walked - see _best_of().
	return direct


## A bucket is a battery, a shooter hull, a target hull, an aspect and a range.
## Nothing else changes the answer: the geometry of the problem is fully
## determined by which way the target is facing and how far the shells have to
## fall - so two bots of the same class looking at the same enemy from the same
## quarter are asking one question, and the solver only ever answers it once.
##
## The battery leads because a hull's turrets and its secondaries are two
## different questions about the same pair of ships, and because they do not
## even bucket range the same way (see _range_bucket).
static func _bucket_key(shooter: Ship, target: Ship, kind: int = KIND_MAIN) -> Array:
	if shooter.scene_file_path.is_empty() or target.scene_file_path.is_empty():
		return []
	var disp: Vector3 = shooter.global_position - target.global_position
	var aspect: float = rad_to_deg((-(target.global_basis.z as Vector3)).angle_to(disp))
	return [
		kind,
		shooter.scene_file_path,
		target.scene_file_path,
		int(aspect / ASPECT_BUCKET_DEG),
		int(disp.length() / _range_bucket(kind)),
	]
