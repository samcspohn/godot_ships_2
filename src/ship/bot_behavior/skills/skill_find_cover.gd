class_name SkillFindCover
extends BotSkill

var _broadside: SkillBroadside = SkillBroadside.new()

var _target_island_id: int = -1
var _target_island_pos: Vector3 = Vector3.ZERO
var _target_island_radius: float = 0.0
var _nav_destination: Vector3 = Vector3.ZERO
var _nav_destination_valid: bool = false
var _cover_recalc_ms: int = 0
var _arrived: bool = false
var can_shoot: bool = false
var _dist_to_dest: float = 0.0
var _last_valid_cover_pos: Vector3 = Vector3.ZERO
var _last_valid_cover_pos_set: bool = false
var _last_valid_intent: NavIntent = null

const _TEAM_COVER_CLAIM_TTL_MS: int = 6000
const _TEAM_COVER_MIN_SEPARATION_MULT: float = 3.0

# How long a validated cover destination is reused before the island search is
# re-run. Without this the skill holds its first pick for the whole engagement.
const _COVER_RESEARCH_INTERVAL_MS: int = 3000
# Half-width of the abeam window, measured off dead abeam of the danger vector.
# Cover inside it is a broadside transit across the fight, never "on the way" —
# see is_cover_on_the_way.
const _COVER_BEAM_HALF_WINDOW: float = deg_to_rad(30.0)
# A freshly found destination must be at least this much closer than the one we
# already hold before we abandon it — hysteresis against island thrashing.
const _COVER_SWITCH_MARGIN: float = 0.7

# What a metre of ground given up toward the enemy is worth, charged against a
# candidate island as if it were extra passage. See _island_passage. Well under
# 1 on purpose: this is a thumb on the scale, not a rule against advancing, and
# a forward island that is genuinely the only cover still wins.
const _COVER_ADVANCE_PENALTY: float = 0.6

## The three questions a ship asks about cover, in the order its intel lets it
## ask them. They are stages of a single decision rather than alternative
## behaviours: a ship walks up them as it learns more, and back down when it
## stops knowing.
##
##   STAGING    Most of the enemy team is unaccounted for. Take ground that the
##              fight will come to, judged against the presumed line - the only
##              thing that has an opinion about ships nobody has seen. Nothing is
##              tested for shootability because there is nothing yet to shoot.
##   COMMITTED  Enough of the team is accounted for to read where it actually is
##              (EnemyPresumption.COMMIT_COVERAGE). Ground is now judged against
##              observed contacts run forward on their own courses. Still no
##              shootability test: it is the expensive question, and it is the
##              wrong one to ask of an island we have not reached.
##   ON_STATION We are there. NOW ask what can actually be shot from here. If
##              nothing can, the reckoning that sent us here did not pan out -
##              but we are in cover and in no hurry, so we sit out the dwell and
##              then go on to the next island.
enum Stage { STAGING, COMMITTED, ON_STATION }

## Why ON_STATION gave up on the ground under us, if it did. The two are handled
## differently on purpose - see execute().
const ABANDON_NONE: int = 0
const ABANDON_EXPOSED: int = 1
const ABANDON_UNPRODUCTIVE: int = 2

## How long after arriving before an island may be given up for being
## unproductive. A ship that reaches cover and leaves again two seconds later
## because the enemy has not arrived yet has not taken cover, it has performed a
## turn. Being early is the normal case and it is not a reason to move.
const _STATION_DWELL_MS: int = 8000

## How much of gun range counts as "the fight will reach this ground", when
## choosing an island to go and hold.
##
## Deliberately NOT the ratio a ship wants to FIGHT at (BotDoctrine's
## gun_engage_ratio, 0.60-0.85). Those are different questions. "Where do I want
## the enemy when we trade" is a preference; "will they be within reach of this
## island by the time I am standing on it" is a fact about geometry, and using
## the preference for it makes cover far more forward than the preference itself
## ever asked for - because the gate is a hard one and it can only be satisfied
## by moving up.
##
## Measured on the real map, 12v12, spawns 20 km apart, a ship 900 m off its own:
## at 0.70 the nearest qualifying island is 6.8-9.2 km up-field, which is at or
## past the halfway line - the enemy's water. At 0.85 it is 3.0-4.7 km, the next
## island or two ahead. Above about 0.9 the gate stops binding at all and the
## passage-plus-advance ranking decides on its own, which lands in the same
## place; 0.85 is the point where the gate has become a sanity bound on the
## ranking rather than a second, contrary opinion about where to go.
const _STAGE_REACH_RATIO: float = 0.85

## How long an island stays passed over after being abandoned for having nothing
## to shoot. Without it the search re-picks the island it just left - it is still
## the nearest, and nothing about the ranking changed by leaving it.
const _SPENT_ISLAND_TTL_MS: int = 20000

# Islands given up on: island_id -> expiry_ms.
var _spent_islands: Dictionary = {}
# When the ship reached its current station, for the dwell above.
var _arrived_ms: int = 0
var _stage: int = Stage.STAGING

# Team-shared reservations: team_id -> ship_instance_id -> claim dictionary
# claim = {"pos": Vector3, "island_id": int, "updated_ms": int}
static var _team_cover_claims: Dictionary = {}

# Last key used by this skill instance; allows reset() to release reservation.
var _claimed_team_id: int = -1
var _claimed_ship_id: int = -1


func execute(ctx: SkillContext, params: Dictionary, prioritize_cover: bool = false) -> NavIntent:
	var now_ms := Time.get_ticks_msec()
	_update_arrival(ctx, now_ms)
	_prune_spent_islands(now_ms)
	_stage = _select_stage(ctx)
	# `prioritize_cover` no longer selects anything: selection never tests
	# shootability, so "cover at any cost" is what every stage below COMMITTED
	# already does. The parameter is kept because callers still pass it and
	# because the dark arm's intent - do not reject an island for being
	# unshootable - is now simply always honoured.
	var cached_valid: bool = _last_valid_intent != null \
		and _is_last_intent_still_valid(ctx, params)

	# A valid cached destination is reused, but only for so long. It is a fixed
	# world point chosen under an older picture; re-searching periodically is what
	# lets a ship drop a distant island once a nearer one becomes viable.
	if cached_valid and now_ms - _cover_recalc_ms < _COVER_RESEARCH_INTERVAL_MS:
		_keep_cached_claim(ctx)
		return _last_valid_intent

	# var ship = ctx.ship
	# var target = ctx.target
	# var desired_range = params.get("desired_range", ship.artillery_controller.get_params()._range * 0.6)
	# var recalc_cooldown = params.get("recalc_cooldown_ms", 3000)

	# # Find initial island if we don't have one yet
	# if not _nav_destination_valid:
	# 	var island = _get_cover_position(ctx, desired_range, target, prioritize_cover)
	# 	if island.is_empty():
	# 		return null  # No cover available — caller falls back
	# 	_set_island(island)

	# # Periodically recalculate cover position
	# var now_ms = Time.get_ticks_msec()
	# if now_ms - _cover_recalc_ms >= recalc_cooldown:
	# 	_cover_recalc_ms = now_ms
	# 	var island: Dictionary
	# 	if _target_island_id >= 0:
	# 		# Already in cover: prefer staying on the same island, only move if
	# 		# it can no longer provide a shootable position.
	# 		island = _recalc_same_island(ctx, target)
	# 		if island.is_empty():
	# 			# Committed island can no longer provide cover while arrived —
	# 			# clear commitment so _get_cover_position skips it and picks
	# 			# the next viable candidate.
	# 			_target_island_id = -1
	# 			island = _get_cover_position(ctx, desired_range, target, prioritize_cover)
	# 	else:
	# 		# Not yet arrived — _get_cover_position will honour the commitment
	# 		# internally: try the cached island first, skip it on failure.
	# 		island = _get_cover_position(ctx, desired_range, target, prioritize_cover)

	# 	if not island.is_empty():
	# 		_set_island(island)
	# 	elif not _nav_destination_valid:
	# 		return null  # No cover available and no previous destination to fall back on

	# # Approach / station-keep
	# var dist = ship.global_position.distance_to(_nav_destination)
	# _dist_to_dest = dist
	# var clearance = ctx.behavior._get_ship_clearance()
	# var arrival_radius = clearance * 2.0
	# var exit_radius = clearance * 3.5
	# _arrived = dist < exit_radius if _arrived else dist < arrival_radius

	_cover_recalc_ms = now_ms

	# ON_STATION is the only stage that asks the expensive question, and it asks it
	# of one island: the one under us. It answers with the station to hold, or with
	# a reason the ground is no longer worth holding - and the two reasons are not
	# equally urgent, because arriving before the enemy does is what taking ground
	# looks like, while being in plain sight is not.
	var d: Dictionary = {}
	if _stage == Stage.ON_STATION:
		d = _recalc_same_island(ctx, ctx.target)
		var reason: int = int(d.get("abandon_reason", ABANDON_NONE))
		if reason != ABANDON_NONE:
			d = {}
			# Unproductive ground is given the dwell; exposed ground is not. Sitting
			# out eight seconds because the enemy has not arrived yet is patience;
			# sitting them out while in plain view is just standing there.
			# Held on the destination itself rather than on cached_valid: what has
			# just failed IS the reach test cached_valid runs, so requiring it here
			# would mean the dwell never applied in the one case it exists for.
			if reason == ABANDON_UNPRODUCTIVE \
					and now_ms - _arrived_ms < _STATION_DWELL_MS \
					and _last_valid_intent != null:
				_keep_cached_claim(ctx)
				return _last_valid_intent
			else:
				# Only unproductive islands are remembered. An island that stopped
				# concealing us did so because the picture moved, and the picture will
				# move again - passing over it for twenty seconds would throw away
				# perfectly good ground.
				_retire_current_island(now_ms, reason == ABANDON_UNPRODUCTIVE)
				cached_valid = false
	if d.is_empty():
		d = _get_cover_position(ctx, params)
	if d.is_empty():
		# Nothing better found — a destination that is still valid beats none.
		if cached_valid:
			_keep_cached_claim(ctx)
			return _last_valid_intent
		_release_cover_claim()
		_last_valid_intent = null
		return null

	# Same island, and the fresh pick is the spot we already hold: keep the one
	# we have. The anchored sweep is centred on a bearing that moves with the
	# ship, so its candidate headings shift a few degrees every tick; without
	# this the station-keeping wobble would be fed straight back into the
	# destination as a slow creep around the island.
	if cached_valid and int(d["id"]) == _target_island_id:
		var held_pos: Vector3 = _last_valid_intent.target_position
		if held_pos.distance_to(d["dest"] as Vector3) < ctx.behavior._get_ship_clearance():
			_keep_cached_claim(ctx)
			return _last_valid_intent

	# Only abandon a still-valid destination for one that is materially closer.
	if cached_valid and int(d["id"]) != _target_island_id:
		var my_pos: Vector3 = ctx.ship.global_position
		var cached_dist := my_pos.distance_to(_last_valid_intent.target_position)
		var new_dist := my_pos.distance_to(d["dest"] as Vector3)
		if new_dist > cached_dist * _COVER_SWITCH_MARGIN:
			_keep_cached_claim(ctx)
			return _last_valid_intent

	_set_island(d)
	can_shoot = d.get("can_shoot", false)
	_reserve_cover_claim(ctx, d)
	# "id": isl["id"],
	# "center": isl_pos,
	# "radius": isl_radius,
	# "dest": dest,
	# "can_shoot": true,
	var heading = ctx.behavior._tangential_heading(_target_island_pos, _nav_destination)
	var intent := NavIntent.create(d["dest"], heading)
	_last_valid_intent = intent

	return intent


	# var heading = ctx.behavior._tangential_heading(_target_island_pos, _nav_destination)

	# # Check shootability (shell arc over terrain) from current or destination position
	# can_shoot = false
	# var check_pos = ship.global_position if _arrived else _nav_destination
	# var shell_params = ship.artillery_controller.get_shell_params()
	# var gun_range = ship.artillery_controller.get_params()._range
	# if shell_params != null:
	# 	for enemy in ctx.server.get_valid_targets(ship.team.team_id):
	# 		if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
	# 			continue
	# 		var tgt = enemy.global_position + enemy.global_basis * ctx.behavior.target_aim_offset(enemy)
	# 		if check_pos.distance_to(tgt) > gun_range:
	# 			continue
	# 		var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(check_pos, tgt, shell_params)
	# 		if sol[0] == null:
	# 			continue
	# 		var result = Gun.sim_can_shoot_over_terrain_static(check_pos, sol[0], sol[1], shell_params, ship)
	# 		if result.can_shoot_over_terrain:
	# 			can_shoot = true
	# 			break

	# var broadside_bias: float = params.get("broadside_bias", 0.4)

	# if _arrived:
	# 	var arrived_intent = NavIntent.create(_nav_destination, heading, arrival_radius * 0.5)
	# 	arrived_intent.near_terrain = true
	# 	arrived_intent.skip_threat_adjustment = true
	# 	return _broadside.apply(arrived_intent, ctx, {"oscillation_bias": broadside_bias})

	# var intent = NavIntent.create(_nav_destination, heading)
	# intent.near_terrain = true
	# intent.skip_threat_adjustment = true
	# return _broadside.apply(intent, ctx, {"oscillation_bias": broadside_bias})
	# _get_cover_position(ctx)


## Which of the three questions this tick is entitled to ask.
##
## Standing on the island beats everything: once we are there, what can be shot
## from here is a fact rather than a projection, and it is the only stage that
## can tell us the ground was not worth taking after all.
##
## Otherwise it is purely how much of the enemy team is accounted for. No clock
## and no fixed distance: a match where contact is made in the first thirty
## seconds should commit in the first thirty seconds, and one where two fleets
## grope past each other for five minutes should still be staging at the end of
## it. See EnemyPresumption.coverage.
func _select_stage(ctx: SkillContext) -> int:
	if _arrived and _target_island_id >= 0 and _nav_destination_valid:
		return Stage.ON_STATION
	if ctx.behavior.presumption_coverage() >= EnemyPresumption.COMMIT_COVERAGE:
		return Stage.COMMITTED
	return Stage.STAGING


## Track whether the ship is actually standing in the cover it chose.
##
## Hysteresis on the two radii: a ship holding station wanders, and a single
## threshold would have it arriving and departing several times a minute, which
## is the difference between "on station" and "on station" flickering into the
## stage selector above.
func _update_arrival(ctx: SkillContext, now_ms: int) -> void:
	if not _nav_destination_valid:
		_arrived = false
		_dist_to_dest = 0.0
		return
	_dist_to_dest = ctx.ship.global_position.distance_to(_nav_destination)
	var clearance: float = ctx.behavior._get_ship_clearance()
	var was_arrived := _arrived
	if _arrived:
		_arrived = _dist_to_dest < clearance * 3.5
	else:
		_arrived = _dist_to_dest < clearance * 2.0
	if _arrived and not was_arrived:
		_arrived_ms = now_ms


## Give up the island under us, optionally remembering not to walk straight back
## onto it - it is still the nearest, so nothing else would stop us.
func _retire_current_island(now_ms: int, remember: bool = true) -> void:
	if _target_island_id >= 0 and remember:
		_spent_islands[_target_island_id] = now_ms + _SPENT_ISLAND_TTL_MS
	_target_island_id = -1
	_nav_destination_valid = false
	_last_valid_cover_pos_set = false
	_last_valid_intent = null
	_arrived = false


func _prune_spent_islands(now_ms: int) -> void:
	for island_id in _spent_islands.keys():
		if now_ms >= int(_spent_islands[island_id]):
			_spent_islands.erase(island_id)


## Bearing around `isl_pos` that a re-search of the island we already hold should
## start from, so the search asks "is there still a good spot near the one I
## have" rather than re-deciding the island from scratch.
##
## Once the ship is at the island that bearing is the ship's own - the position
## it is actually holding. While still travelling it is the destination already
## claimed, which is the point the ship is committed to and the one team-mates
## are spacing themselves against; the ship's live bearing out there is just the
## approach, and centring on it would walk the destination around the island as
## the ship closes.
##
## Returns NAN (no anchor - sweep the hide window as usual) when the reference
## point sits on the island centre and has no meaningful bearing.
func _committed_anchor_heading(ctx: SkillContext, isl_pos: Vector3, isl_radius: float) -> float:
	var my_pos: Vector3 = ctx.ship.global_position
	var near_radius: float = isl_radius + ctx.behavior._get_ship_clearance() * 6.0
	var from_pos: Vector3 = my_pos
	if _nav_destination_valid and my_pos.distance_to(isl_pos) > near_radius:
		from_pos = _nav_destination
	var to_pos: Vector3 = from_pos - isl_pos
	to_pos.y = 0.0
	if to_pos.length_squared() < 1.0:
		return NAN
	return atan2(to_pos.x, to_pos.z)


func _resolve_min_cover_separation(ctx: SkillContext, params: Dictionary) -> float:
	var default_sep = ctx.behavior._get_ship_clearance() * _TEAM_COVER_MIN_SEPARATION_MULT
	return params.get("min_cover_separation", default_sep)

func _prune_team_cover_claims(team_id: int, now_ms: int) -> void:
	if not _team_cover_claims.has(team_id):
		return
	var team_claims: Dictionary = _team_cover_claims[team_id]
	for ship_id in team_claims.keys():
		var entry: Dictionary = team_claims[ship_id]
		if now_ms - int(entry.get("updated_ms", 0)) > _TEAM_COVER_CLAIM_TTL_MS:
			team_claims.erase(ship_id)
	if team_claims.is_empty():
		_team_cover_claims.erase(team_id)
	else:
		_team_cover_claims[team_id] = team_claims

func _collect_other_claim_positions(ctx: SkillContext) -> Array:
	var claims: Array = []
	if ctx.server == null or ctx.ship == null:
		return claims
	var team_id = ctx.ship.team.team_id
	var now_ms = Time.get_ticks_msec()
	_prune_team_cover_claims(team_id, now_ms)
	if not _team_cover_claims.has(team_id):
		return claims
	var my_ship_id = ctx.ship.get_instance_id()
	var team_claims: Dictionary = _team_cover_claims[team_id]
	for ship_id in team_claims.keys():
		if int(ship_id) == my_ship_id:
			continue
		var entry: Dictionary = team_claims[ship_id]
		var p: Vector3 = entry.get("pos", Vector3.ZERO)
		if p != Vector3.ZERO:
			claims.append(p)
	return claims

func _has_cover_spacing_conflict(pos: Vector3, claim_positions: Array, min_cover_separation: float) -> bool:
	if min_cover_separation <= 0.0 or claim_positions.is_empty():
		return false
	for claim_pos in claim_positions:
		if pos.distance_to(claim_pos) < min_cover_separation:
			return true
	return false

func _reserve_cover_claim(ctx: SkillContext, island: Dictionary) -> void:
	if ctx.server == null or ctx.ship == null:
		return
	var team_id = ctx.ship.team.team_id
	var ship_id = ctx.ship.get_instance_id()
	var now_ms = Time.get_ticks_msec()
	_prune_team_cover_claims(team_id, now_ms)
	var team_claims: Dictionary = _team_cover_claims.get(team_id, {})
	team_claims[ship_id] = {
		"pos": island["dest"],
		"island_id": island["id"],
		"updated_ms": now_ms,
	}
	_team_cover_claims[team_id] = team_claims
	_claimed_team_id = team_id
	_claimed_ship_id = ship_id

## Re-stamp the reservation on the destination we are already holding, so the
## claim stays alive while the cached intent is being reused.
func _keep_cached_claim(ctx: SkillContext) -> void:
	if _target_island_id < 0 or _last_valid_intent == null:
		return
	_reserve_cover_claim(ctx, {
		"id": _target_island_id,
		"dest": _last_valid_intent.target_position,
	})

## Drop this ship's team-wide reservation while keeping the cached search result.
## Call when a cover intent was computed but not adopted: a ship that ends up
## kiting must not sit on a spot its team-mates could otherwise use.
func release_claim() -> void:
	_release_cover_claim()

func _release_cover_claim() -> void:
	if _claimed_team_id < 0 or _claimed_ship_id < 0:
		return
	if _team_cover_claims.has(_claimed_team_id):
		var team_claims: Dictionary = _team_cover_claims[_claimed_team_id]
		team_claims.erase(_claimed_ship_id)
		if team_claims.is_empty():
			_team_cover_claims.erase(_claimed_team_id)
		else:
			_team_cover_claims[_claimed_team_id] = team_claims
	_claimed_team_id = -1
	_claimed_ship_id = -1


# ---------------------------------------------------------------------------
# Recalculate the best position on the island we are already holding.
# Returns empty dict only when the island is genuinely no longer viable:
#   • No concealed position exists at all, OR
#   • Enemies ARE visible yet none can be shot from any position on the island.
# If no enemies are currently visible we cannot assess shootability, so we
# stay put rather than thrashing to a different island.
# ---------------------------------------------------------------------------
func _recalc_same_island(ctx: SkillContext, _target: Ship) -> Dictionary:
	var ship = ctx.ship
	var my_pos: Vector3 = ship.global_position
	# Already on this island, so the passage is the short hop to a station on it -
	# but never zero: cover is somewhere to sit, and Behavior.cover_horizon's hold
	# margin is what asks whether this spot is still cover in a few seconds' time.
	var lead: float = ctx.behavior.cover_horizon(_island_passage(ctx,
		_target_island_pos, _target_island_radius))
	var threats = ctx.behavior._gather_threat_positions(ship, lead)
	var targets = ctx.server.get_valid_targets(ship.team.team_id)
	var max_desired_range = ship.artillery_controller.get_params()._range * 0.7
	var min_cover_separation = ctx.behavior._get_ship_clearance() * _TEAM_COVER_MIN_SEPARATION_MULT
	var other_claim_positions = _collect_other_claim_positions(ctx)
	# Already committed to this island, so we can afford the better question:
	# not "is there a spot here I can shoot SOMETHING from" but "is there a spot
	# here I can shoot the ship that actually matters from". Each priority enemy
	# costs another sweep of the candidate set, which is why this is confined to
	# the on-island path - picking a NEW island stays on the cheap
	# first-shootable-wins search.
	var priority_targets: Array = ctx.behavior.cover_priority_targets()

	if threats.is_empty():
		# Nothing believed to be out there at all. There is no question to answer
		# and no reason to move; hold what we have.
		return {
			"id": _target_island_id,
			"center": _target_island_pos,
			"radius": _target_island_radius,
			"dest": _nav_destination,
			"can_shoot": false,
		}

	# ── Fastest path: re-validate the last known-good cover position ─────────
	# This is a fixed world point that was previously confirmed as hidden AND
	# shootable.  A cheap LOS + shoot check is all we need; no geometry search.
	if _last_valid_cover_pos_set:
		var cached_pos := _last_valid_cover_pos
		var cached_hidden := true
		for threat in threats:
			if not ctx.behavior._is_masked_from_threat(cached_pos, threat):
				cached_hidden = false
				break
		if cached_hidden:
			var can_shoot_cached := _serves_priority(ctx, cached_pos, targets, priority_targets, lead)
			var cached_conflict = _has_cover_spacing_conflict(cached_pos, other_claim_positions, min_cover_separation)
			if (targets.is_empty() or can_shoot_cached) and not cached_conflict:
				return {
					"id": _target_island_id,
					"center": _target_island_pos,
					"radius": _target_island_radius,
					"dest": cached_pos,
					"can_shoot": can_shoot_cached,
				}
		# Cached position no longer valid — clear it and keep searching.
		_last_valid_cover_pos_set = false

	# ── Fast path: current position is already concealed ─────────────────────
	# Skip the full candidate search when the ship is already hidden from every
	# known threat.  Stamp the current world position as the destination so it
	# doesn't slowly drift with the ship between recalc ticks.
	if threats.size() > 0:
		var all_hidden := true
		for threat in threats:
			if not ctx.behavior._is_masked_from_threat(my_pos, threat):
				all_hidden = false
				break
		if all_hidden:
			var can_shoot_here := _serves_priority(ctx, my_pos, targets, priority_targets, lead)
			var current_conflict = _has_cover_spacing_conflict(my_pos, other_claim_positions, min_cover_separation)
			if (targets.is_empty() or can_shoot_here) and not current_conflict:
				if can_shoot_here:
					_last_valid_cover_pos = my_pos
					_last_valid_cover_pos_set = true
				return {
					"id": _target_island_id,
					"center": _target_island_pos,
					"radius": _target_island_radius,
					"dest": my_pos,
					"can_shoot": can_shoot_here,
				}
			# Concealed but visible enemies are not shootable from here →
			# fall through so the candidate search tries a better spot on
			# this same island before considering abandoning it.

	var hide_h: float
	if threats.size() > 0:
		hide_h = ctx.behavior._compute_hide_heading(_target_island_pos, threats)
	else:
		hide_h = atan2(ctx.behavior._cached_safe_dir.x, ctx.behavior._cached_safe_dir.z)

	var cover_result = ctx.behavior._find_cover_position_on_island(
		_target_island_pos,
		_target_island_radius,
		hide_h,
		threats,
		targets,
		max_desired_range,
		other_claim_positions,
		min_cover_separation,
		priority_targets,
		NAN,
		lead,
		[],
		# The one place the ballistic solver runs. We are standing here, so what can
		# be hit from here is a fact, and it is the only honest test of whether the
		# reckoning that sent us was any good.
		true
	)

	# Island can't conceal us at all — that is urgent. Being seen is happening
	# now, not on some horizon, and nothing about sitting still improves it.
	if cover_result.is_empty():
		return {"abandon_reason": ABANDON_EXPOSED}

	# Concealed, but nothing here can be shot. The reckoning that sent us did not
	# pan out - which is disappointing rather than dangerous, so this one goes
	# through the dwell before we give the ground up.
	if targets.size() > 0 and not cover_result["can_shoot"]:
		return {"abandon_reason": ABANDON_UNPRODUCTIVE}

	# Either can shoot, or no enemies are currently spotted (can't assess
	# shootability) — stay on the island.  Cache the position when shootable.
	var result_can_shoot: bool = cover_result.get("can_shoot", false)
	if result_can_shoot:
		_last_valid_cover_pos = cover_result["pos"]
		_last_valid_cover_pos_set = true
	return {
		"id": _target_island_id,
		"center": _target_island_pos,
		"radius": _target_island_radius,
		"dest": cover_result["pos"],
		"can_shoot": result_can_shoot,
	}

var curr_dest_island_id: int = -1
var curr_dest_island_pos: Vector3 = Vector3.ZERO
var curr_heading: float = 0.0

# ---------------------------------------------------------------------------
# Choose an island: the STAGING and COMMITTED stages.
#
# Nearest-first, and an island is accepted when it offers a position that is
# hidden from everything that might shoot us AND has something within reach of
# it by the time we would arrive. Nothing here asks whether a shell can be put
# on anyone - that is ON_STATION's question, asked once we are standing there
# (see _recalc_same_island).
#
# Dropping shootability from selection is the point of the whole arrangement.
# It is monotone in how far up the map a position is: the further forward you
# stand, the more you can shoot, so a hard gate on it always returns the most
# advanced island that clears it, whatever the ranking in front of it said. That
# is how a cruiser thirty seconds into a match ended up committed to an island on
# the enemy's side of the water.
#
# What the two stages differ in is only WHERE THE ENEMY IS RECKONED TO BE:
# the presumed line while most of them are unaccounted for, their own observed
# courses once enough of them are not. See _select_stage.
# ---------------------------------------------------------------------------
func _get_cover_position(ctx: SkillContext, params: Dictionary) -> Dictionary:
	if not NavigationMapManager.is_map_ready():
		return {}

	var islands = NavigationMapManager.get_islands()
	if islands.is_empty():
		return {}

	var ship = ctx.ship
	var my_pos = ship.global_position
	var gun_range = ship.artillery_controller.get_params()._range
	# NOTE: CABehavior._cover_params() passes "desired_range", not "max_range", so
	# its value has never reached this line. Left as found rather than silently
	# changing what a cruiser does - but the default below is what is actually in
	# force for every hull today.
	var max_desired_range = gun_range * params.get("max_range", _STAGE_REACH_RATIO)

	if ctx.server == null:
		return {}
	var targets = ctx.server.get_valid_targets(ship.team.team_id)
	# var enemy_clusters = ctx.server.get_enemy_clusters(ship.team.team_id)

	ctx.behavior._ensure_safe_dir(ship, ctx.server)
	var min_cover_separation = _resolve_min_cover_separation(ctx, params)
	var other_claim_positions = _collect_other_claim_positions(ctx)

	# Pre-compute the passage to each island once, so the sort comparator stays
	# O(1) per comparison and every island's arrival horizon is available before
	# the search loop needs it. See _island_passage for what the number contains.
	# The hide side of every island is the face pointing directly away from the
	# danger centre -- one shared reference point, computed once.
	# Which side of an island to sit on is a question that always has an answer,
	# so this uses the positioning centre rather than the confirmed-only one.
	# With the confirmed centre, the arc term collapsed to zero before first
	# contact and islands were ranked on raw proximity alone - no account of how
	# far the ship would have to sail AROUND one to reach the sheltered face,
	# which is how a bot ends up committing to an island it has to pass the enemy
	# to use.
	var _danger_center: Vector3 = ctx.behavior._get_positioning_danger_center()
	var _use_danger_center: bool = _danger_center != Vector3.ZERO

	# Distance actually sailed to take up a station on each island, and from it
	# the horizon that island's picture is solved for (see Behavior.cover_horizon).
	# The passage is the same number the sort runs on, which is the point: the
	# island that is a long way off is judged against a threat picture a long way
	# forward, and usually stops looking like cover once it is.
	# Two numbers per island, and they are deliberately not the same one.
	# _island_travel_cost is a DISTANCE THE SHIP SAILS, and only that, because the
	# arrival horizon is derived from it and an ETA inflated by a preference is not
	# an ETA. _island_sort_cost is that plus what the ground given up toward the
	# enemy is worth, and is what the ranking runs on.
	var _island_travel_cost: Dictionary = {}
	var _island_sort_cost: Dictionary = {}
	var _nearest_cost := INF
	for _sort_isl in islands:
		var _sisl_pos := Vector3((_sort_isl["center"] as Vector2).x, 0.0,
			(_sort_isl["center"] as Vector2).y)
		var _passage: float = _island_passage(ctx, _sisl_pos, _sort_isl["radius"],
			_danger_center if _use_danger_center else Vector3.ZERO)
		_island_travel_cost[_sort_isl["id"]] = _passage
		_island_sort_cost[_sort_isl["id"]] = _passage \
			+ _advance_penalty(ctx, _sisl_pos, _danger_center if _use_danger_center else Vector3.ZERO)
		_nearest_cost = minf(_nearest_cost, _passage)
	if not is_finite(_nearest_cost):
		_nearest_cost = 0.0

	# A baseline picture, at the horizon of the closest island on the map, for the
	# questions asked before any particular island is under consideration - "is
	# anybody out there at all", and which way is away from them. Each island in
	# the loop below then gets its own.
	var threats = ctx.behavior._gather_threat_positions(ship,
		ctx.behavior.cover_horizon(_nearest_cost))

	# Sort islands by estimated navigation cost — nearest usable one wins.
	# The committed island deliberately gets no priority here: it used to sort
	# first while merely within firing range, which is how a ship ended up
	# crossing kilometres to an island it had picked earlier while a perfectly
	# good one sat next to it. Hysteresis lives in execute() instead, where a
	# still-valid destination is only given up for a materially closer one.
	islands.sort_custom(func(a, b):
		return _island_sort_cost[a["id"]] < _island_sort_cost[b["id"]]
	)

	# ── No-enemy shortcut ────────────────────────────────────────────────────
	# When there are no known threats or valid targets, skip the full cover
	# search.  The islands are already sorted nearest-first (arc_cost == 0 with
	# no danger centre), so just walk the list and return the first island that
	# has no spacing conflict.
	if threats.is_empty() and targets.is_empty():
		var clearance := ctx.behavior._get_ship_clearance()
		for isl in islands:
			var c2d: Vector2 = isl["center"]
			var isl_pos := Vector3(c2d.x, 0.0, c2d.y)
			var isl_radius: float = isl["radius"]
			# Same rule as the full search, and the same exemption: never pick
			# cover past the enemy, but never give up cover already held either.
			if int(isl["id"]) != _target_island_id and _use_danger_center \
					and isl_pos.distance_to(_danger_center) < gun_range * 0.35:
				continue
			if int(isl["id"]) != _target_island_id and _spent_islands.has(int(isl["id"])):
				continue
			# Station on the side of the island facing our own lines. `radius` is
			# the island's bounding radius, so the destination has to be walked out
			# to the shoreline — a fraction of it lands on land.
			var away_dir: Vector3 = ctx.behavior._cached_safe_dir
			away_dir.y = 0.0
			if away_dir.length_squared() < 0.01:
				away_dir = my_pos - isl_pos
				away_dir.y = 0.0
			if away_dir.length_squared() < 0.01:
				away_dir = Vector3(1.0, 0.0, 0.0)
			away_dir = away_dir.normalized()
			var dest := ctx.behavior._sdf_walk_to_shore(isl_pos, away_dir, isl_radius, clearance)
			if dest == Vector3.ZERO:
				continue
			if not _has_cover_spacing_conflict(dest, other_claim_positions, min_cover_separation):
				return {
					"id": isl["id"],
					"center": isl_pos,
					"radius": isl_radius,
					"dest": dest,
					"can_shoot": false,
				}
		return {}

	# Where the enemy is reckoned to be for the purpose of "will this ground have
	# anything within reach of it". COMMITTED drops the ships nobody has seen and
	# reads only what has actually been observed; STAGING keeps them, because while
	# most of a team is unaccounted for the presumed line is the only thing with an
	# opinion about where the fight is going to happen.
	var known_only: bool = _stage == Stage.COMMITTED

	var spacing_conflict_fallback: Dictionary = {}

	# Cover has to be on our side of the fight. Without a floor here the search
	# happily returns an island past the enemy line - the ship then steams the
	# length of the map, through everything, to hide behind it.
	#
	# It applies to islands we would TRAVEL to, never to the one we are already
	# using. An island being fought over is not an island to be avoided: a
	# battleship pushing onto a cruiser drags the danger centre inside this
	# radius, which used to reject the cruiser's own island and send it running
	# broadside-on for a "safer" one. Standing and killing the ship that closed
	# is the entire reason targets are ranked by who is pushing.
	var min_safe_range: float = gun_range * 0.35

	for isl in islands:
		var center_2d: Vector2 = isl["center"]
		var isl_pos = Vector3(center_2d.x, 0.0, center_2d.y)
		var isl_radius: float = isl["radius"]

		var is_committed: bool = int(isl["id"]) == _target_island_id
		if not is_committed and _use_danger_center \
				and isl_pos.distance_to(_danger_center) < min_safe_range:
			continue
		# Already tried and found to have nothing to shoot at. It is still the
		# nearest, so nothing but this memory stops us sailing back onto it.
		if not is_committed and _spent_islands.has(int(isl["id"])):
			continue

		# Everything about THIS island is decided for the moment the ship would
		# reach it. Solving each candidate against one shared horizon is what let a
		# ship commit to an island eight kilometres off on the strength of where the
		# enemy stood when it set out; by the time it arrived the hidden face was the
		# exposed one. The horizon is quantised, so nearby islands share a picture
		# and this costs a rebuild only when the passage is genuinely different.
		var isl_lead: float = ctx.behavior.cover_horizon(_island_travel_cost[isl["id"]])
		var isl_threats: Array = ctx.behavior._gather_threat_positions(ship, isl_lead)
		var isl_reach: Array = ctx.behavior.reach_positions(isl_lead, known_only)

		# Cheap rejection before the sweep: nothing can be within max_desired_range
		# of any point on this island if nothing is within that of the island itself,
		# plus the radius the candidate ring is walked out to.
		var island_reach: float = max_desired_range + isl_radius \
			+ ctx.behavior._get_ship_clearance() * 2.0
		var reachable := false
		for reach_pos in isl_reach:
			if isl_pos.distance_to(reach_pos) <= island_reach:
				reachable = true
				break
		if not reachable:
			continue

		var hide_h: float
		if isl_threats.size() > 0:
			hide_h = ctx.behavior._compute_hide_heading(isl_pos, isl_threats)
		else:
			hide_h = atan2(ctx.behavior._cached_safe_dir.x, ctx.behavior._cached_safe_dir.z)

		# Re-searching the island we already hold starts from the bearing we hold on
		# it, not from a fresh sweep of the hide window - see
		# _committed_anchor_heading. Priority targets are passed as empty: selection
		# never runs the ballistic solver.
		var cover_result = ctx.behavior._find_cover_position_on_island(
			isl_pos,
			isl_radius,
			hide_h,
			isl_threats,
			targets,
			max_desired_range,
			other_claim_positions,
			min_cover_separation,
			[],
			_committed_anchor_heading(ctx, isl_pos, isl_radius) if is_committed else NAN,
			isl_lead,
			isl_reach,
			false
		)
		if cover_result.is_empty():
			continue

		var dest: Vector3 = cover_result["pos"]
		var island_result := {
			"id": isl["id"],
			"center": isl_pos,
			"radius": isl_radius,
			"dest": dest,
			# Unknown, and deliberately not asked. ON_STATION settles it once we
			# are standing there.
			"can_shoot": false,
		}

		if cover_result.get("spacing_conflict", false):
			if spacing_conflict_fallback.is_empty():
				spacing_conflict_fallback = island_result
			continue

		# if prioritize_cover:
		# Nearest viable island — return immediately (list is already sorted)
		return island_result

	if not spacing_conflict_fallback.is_empty():
		return spacing_conflict_fallback

	return {}


## How far the ship actually has to sail to be sitting in cover on `isl_pos`.
##
## Two terms, and the second is the one that was missing whenever this number was
## wanted as an arrival time: the run to the island's edge, and then the arc
## round it to the sheltered face. Cover is on the far side from the enemy, and a
## ship does not arrive there by reaching the island - on a 1.5 km island that
## arc is most of the last five kilometres of the passage.
##
## Strictly a distance sailed. What the position is WORTH is _advance_penalty's
## business; keeping the two apart is what stops a preference leaking into the
## horizon the threat picture is projected to.
func _island_passage(ctx: SkillContext, isl_pos: Vector3, isl_radius: float,
		danger_center: Vector3 = Vector3.ZERO) -> float:
	var my_pos: Vector3 = ctx.ship.global_position
	var edge_dist := maxf(my_pos.distance_to(isl_pos) - isl_radius, 0.0)
	if danger_center == Vector3.ZERO:
		danger_center = ctx.behavior._get_positioning_danger_center()
	if danger_center == Vector3.ZERO:
		return edge_dist

	# Hide direction: from danger centre toward island centre (the far side).
	var hide_dir := isl_pos - danger_center
	hide_dir.y = 0.0
	# Ship direction: from island centre toward the ship.
	var ship_dir: Vector3 = my_pos - isl_pos
	ship_dir.y = 0.0
	if hide_dir.length_squared() <= 1.0 or ship_dir.length_squared() <= 1.0:
		return edge_dist
	var cos_a := hide_dir.normalized().dot(ship_dir.normalized())
	# acos gives the unsigned angle (0..PI) between the two directions.
	return edge_dist + acos(clampf(cos_a, -1.0, 1.0)) * isl_radius


## What an island's position costs it in the ranking, over and above the passage:
## how much ground it gives up TOWARD the enemy, priced by _COVER_ADVANCE_PENALTY.
##
## Two islands the same distance off are not the same proposition when one of
## them is two kilometres further up the field. The ground has to be taken and
## then held, the standoff to everything shooting is shorter, and - the part that
## actually kills ships - the closer a position is to the enemy, the faster its
## sheltered face swings round as the enemy moves, so cover that was real on
## departure is a bare flank on arrival. The exposure probe in
## EnemyPresumption already makes the forward candidates harder to satisfy; this
## stops the search reaching for one in the first place just because it happened
## to be a few hundred metres nearer. A penalty and not a veto: a forward island
## that is genuinely the only cover still wins.
func _advance_penalty(ctx: SkillContext, isl_pos: Vector3, danger_center: Vector3) -> float:
	if danger_center == Vector3.ZERO:
		return 0.0
	var advance := maxf(ctx.ship.global_position.distance_to(danger_center)
		- isl_pos.distance_to(danger_center), 0.0)
	return advance * _COVER_ADVANCE_PENALTY


func _set_island(island: Dictionary) -> void:
	if _target_island_id != island["id"]:
		# Switching islands — cached position belongs to the old island, and we are
		# self-evidently no longer standing on the station we were holding.
		_last_valid_cover_pos_set = false
		_arrived = false
	_target_island_id = island["id"]
	_target_island_pos = island["center"]
	_target_island_radius = island["radius"]
	_nav_destination = island["dest"]
	_nav_destination_valid = true


# ---------------------------------------------------------------------------
# Returns true if any valid target can be hit with a ballistic arc from
# from_pos.  Mirrors the shootability check in execute().
# ---------------------------------------------------------------------------
func _is_last_intent_still_valid(ctx: SkillContext, params: Dictionary) -> bool:
	if _last_valid_intent == null or not _nav_destination_valid:
		return false
	if ctx.ship == null or ctx.server == null:
		return false
	var pos: Vector3 = _last_valid_intent.target_position
	var ship = ctx.ship

	# if an island is outside desired range, its validity is ignored for better cover options
	if pos.distance_to(ship.global_position) > ship.artillery_controller.get_params()._range * 1.0: # adjust to 1 for more safety
		return false

	# Validity of a destination we are still travelling to is judged for when we
	# arrive there, so the horizon is the passage still left to run. The point is
	# already chosen, so this is the plain distance to it rather than the full
	# island passage - no arc left to sail, and no choice left to bias.
	var lead: float = ctx.behavior.cover_horizon(pos.distance_to(ship.global_position))
	var threats = ctx.behavior._gather_threat_positions(ship, lead)
	for threat in threats:
		if not ctx.behavior._is_masked_from_threat(pos, threat):
			return false

	# Still worth going to, on the same terms it was chosen on: something has to be
	# within reach of it by the time we get there. Shootability is deliberately not
	# re-asked - it was never asked in the first place, and re-asking it here would
	# reintroduce through the back door the very gate that dragged ships up the map.
	# A held destination that has stopped being reachable-to is a destination the
	# battle has moved away from, and that is the thing worth noticing.
	var known_only: bool = _stage == Stage.COMMITTED
	var reach: Array = ctx.behavior.reach_positions(lead, known_only)
	if not reach.is_empty():
		var gun_range: float = ship.artillery_controller.get_params()._range
		var reach_limit: float = gun_range * params.get("max_range", _STAGE_REACH_RATIO)
		var in_reach := false
		for reach_pos in reach:
			if pos.distance_to(reach_pos) <= reach_limit:
				in_reach = true
				break
		if not in_reach:
			return false

	var min_cover_separation = _resolve_min_cover_separation(ctx, params)
	var other_claim_positions = _collect_other_claim_positions(ctx)
	if _has_cover_spacing_conflict(pos, other_claim_positions, min_cover_separation):
		return false

	return true


## Whether a position is good enough to STAY in. With a priority list that means
## it can reach one of the enemies that matter; without one it falls back to the
## old any-target question.
##
## This is what stops the fast paths undoing the priority search: a spot that can
## only reach a harmless destroyer used to satisfy them outright, so a cruiser
## parked there never re-searched and never noticed the battleship coming round
## its island. Rejecting here only costs a full sweep, which then returns the
## best position available - possibly this same one.
func _serves_priority(ctx: SkillContext, from_pos: Vector3, targets: Array, priority_targets: Array, lead: float = 0.0) -> bool:
	if priority_targets.is_empty():
		return _can_shoot_from(ctx, from_pos, targets, lead)
	var shell_params = ctx.ship.artillery_controller.get_shell_params()
	if shell_params == null:
		return false
	var gun_range: float = ctx.ship.artillery_controller.get_params()._range
	var gun_range_sq: float = gun_range * gun_range
	var considered := 0
	for pri in priority_targets:
		if not is_instance_valid(pri) or not pri.is_alive():
			continue
		# Through the contact solution, never the live transform: a priority
		# target may be one the team has lost, and testing against where it
		# really is would hand this bot a position built on a ship it cannot see.
		var pri_pos = ctx.behavior.cover_test_position(pri, lead)
		if pri_pos == null:
			continue
		considered += 1
		if ctx.behavior._can_shoot_point_from(from_pos, pri_pos, shell_params, gun_range_sq):
			return true
	if considered == 0:
		return _can_shoot_from(ctx, from_pos, targets, lead)
	return false


## Whether anything in `targets` can be engaged from `from_pos` - asked of where
## those ships will be `lead` seconds from now, which is when the ship holding
## `from_pos` will be in a position to shoot at them.
func _can_shoot_from(ctx: SkillContext, from_pos: Vector3, targets: Array, lead: float = 0.0) -> bool:
	var ship = ctx.ship
	var shell_params = ship.artillery_controller.get_shell_params()
	if shell_params == null:
		return false
	var gun_range = ship.artillery_controller.get_params()._range
	var gun_range_sq: float = gun_range * gun_range
	for tgt in ctx.behavior.led_target_points(targets, lead):
		if ctx.behavior._can_shoot_point_from(from_pos, tgt, shell_params, gun_range_sq):
			return true
	return false


func is_complete(_ctx: SkillContext) -> bool:
	return _arrived


func get_dist() -> float:
	return _dist_to_dest


func reset() -> void:
	_release_cover_claim()
	_target_island_id = -1
	_nav_destination_valid = false
	_arrived = false
	_arrived_ms = 0
	_stage = Stage.STAGING
	_spent_islands.clear()
	can_shoot = false
	_last_valid_cover_pos_set = false
	_last_valid_intent = null


# ---------------------------------------------------------------------------
# Returns true if the current cover destination is reasonably "on the way" —
# that is, whether reaching it costs a detour, rather than whether it happens
# to lie toward the enemy.  Two courses count as "the way":
#
#   * the course made good — where the hull is travelling RIGHT NOW.  Cover the
#     ship is already closing on is not a detour whichever compass point it sits
#     on, and abandoning it the instant the ship is spotted throws away every
#     metre already spent getting there.  Taken from velocity rather than from
#     the bow so that a ship backing down reads as travelling astern.
#   * the retreat course SkillKite would run, away from the danger centre.  If
#     the ship is about to disengage, cover along the way out is free.
#
# Either one passing is enough.  Cover on neither course — off the beam of a
# ship that is neither approaching it nor withdrawing past it — is a genuine
# detour and does not count.
#
# Both courses are read against the danger vector first: cover lying abeam of
# it is a transit across the fight and is rejected outright, whatever the hull
# is doing at this instant.
#
# Angle tolerance scales with distance to cover:
#   60° when cover is <= 1000 m away  (almost there — accept wide detours)
#   15° when cover is >= 6000 m away  (far detour is too costly)
#
# Call this AFTER execute() so that _nav_destination is up to date.
# ---------------------------------------------------------------------------
func is_cover_on_the_way(ctx: SkillContext) -> bool:
	if not _nav_destination_valid:
		return false
	var ship = ctx.ship
	var to_cover = _nav_destination - ship.global_position
	to_cover.y = 0.0
	var dist_to_cover = to_cover.length()
	if dist_to_cover < 750.0:
		return true

	var t = clampf((dist_to_cover - 750.0) / 5000.0, 0.0, 1.0)
	var angle_tol = lerpf(deg_to_rad(60.0), deg_to_rad(15.0), t)
	var cover_bearing = atan2(to_cover.x, to_cover.z)

	var retreat_heading = wrapf(SkillAngle.calc_heading(ctx, {}), -PI, PI)
	var to_retreat: Vector2 = Vector2(sin(retreat_heading), cos(retreat_heading))
	var to_cover_2d: Vector2 = Vector2(sin(cover_bearing), cos(cover_bearing))
	if absf(to_retreat.dot(to_cover_2d)) >= cos(angle_tol):
		return true

	return false
