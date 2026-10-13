class_name SkillStance
extends BotSkill

## Owns heading and throttle while guns can reach us. Once per enemy flight time
## it commits to a plan: hold heading H at a throttle for that flight time,
## then the tail (the route, or the heading taking least fire) for the rest of a
## horizon a minute past a half turn. Each plan is sailed (StanceSim) with every
## enemy's salvos landing on its own clock at the aspect shown then, missing by
## how far we moved off the course it led, and our guns and loaded tubes firing
## when they bear. Score = HP lost for good (repair counted), less a third of the
## HP dealt, plus progress.

const STEP: float = deg_to_rad(5.0)
const HEADINGS: int = 72
## Candidates are every CANDIDATE_STRIDE-th heading.
const CANDIDATE_STRIDE: int = 1
## Plans scoring within this of the best are equals; the simplest of them is sailed.
const NEAR_TIE: float = 0.005
## Ahead to astern or back costs like this much bow turn.
const GEAR_FLIP_TURN: float = PI / 2.0
## Simplicity is compared in steps this coarse, then the narrowest presentation wins.
const SIMPLE_STEP: float = deg_to_rad(10.0)
const ASPECT_STEP_DEG: float = 5.0
const ASPECTS: int = 37
const RANGE_BUCKET_M: float = 250.0
## Judged this long past the time a half turn takes, so every option is seen settled.
const HORIZON_BASE_S: float = 60.0
## Speed through a hard turn, as a share of full.
const TURN_SPEED_FRAC: float = 0.75
const SIM_DT: float = 3.0
## Shares of full ahead; -1 is astern.
const THROTTLES: Array[float] = [1.0, 0.75, 0.5, 0.25, 0.0, -1.0]
## Under fire, no plan runs slower than this ahead.
const UNDER_FIRE_MIN_THROTTLE: float = 0.5
## A half turn of heading costs this share of HP, shot at or not.
const TURN_W: float = 0.02
## A whole horizon broadside to the danger costs this share of HP, shot at or not.
const PRESENT_W: float = 0.02
## Full-speed progress over the horizon is worth this share of our remaining HP.
const PROGRESS_W: float = 0.1
## More guns must deal this many HP for each HP they cost us: mitigation first.
const DEAL_RATIO: float = 3.0
const DEAL_WEIGHT: float = 1.0 / DEAL_RATIO
const CLOSING_W: float = 0.05
## In range of us, but not shown to be aiming here.
const BYSTANDER_WEIGHT: float = 0.5
## The plan held now wins by this, in shares of remaining HP over the horizon.
const SWITCH_MARGIN: float = 0.02
## Stance picks how to follow the skill's route, never whether: motion stays within this of it.
const ROUTE_CONE: float = deg_to_rad(90.0)
const LEG_MIN_S: float = 6.0
## On station, drifting a turning circle past the leash for the whole horizon costs this share of HP.
const LEASH_W: float = 0.2
## A plan keeps its turn until the bow is this close to it: re-planning mid-turn leaves half-turns.
const TURN_DONE: float = deg_to_rad(30.0)
const TURN_HOLD_MAX_S: float = 90.0
## Share of a loaded tube's torpedoes expected to hit.
const TORP_HIT_SHARE: float = 0.1

var _heading: float = 0.0
var _throttle: float = 1.0
## The plan is the route's own heading, whatever it shows.
var _on_route: bool = false
var _until: float = -INF
var _since: float = -INF
var _active: bool = false
## Shooter instance id -> [range bucket, dps per aspect step then their repairable parts, tof, miss].
var _tables: Dictionary = {}

## StanceSim shooter entries: bearing, rows, weight, reload, next.
var _shooters: Array[Dictionary] = []
## Per heading index: weighted incoming dps, for the tail.
var _dps: PackedFloat32Array = PackedFloat32Array()


func apply(intent: NavIntent, ctx: SkillContext) -> NavIntent:
	var clock: SalvoClock = ctx.behavior.salvo_clock
	if intent == null or clock == null:
		reset()
		return intent
	var route: float = _route_bearing(intent, ctx)
	if not _survey(ctx) and not _quiet(ctx):
		reset()
		return intent
	var now: float = SimClock.now()
	var stale: bool = (_on_route and not is_finite(route)) or not _follows(_heading, _throttle, route)
	var turning: bool = not _on_route and now - _since < TURN_HOLD_MAX_S \
		and absf(angle_difference(ctx.behavior._get_ship_heading(), _heading)) > TURN_DONE
	if stale or (now >= _until and not turning):
		_plan(ctx, intent, route, clock, now)
	_active = true
	if _on_route:
		intent.forbid_reverse = true
		return intent
	intent.target_heading = _heading
	intent.heading_weight = 1.0
	intent.force_reverse = _throttle < 0.0
	intent.forbid_reverse = _throttle >= 0.0
	return intent


## Highest forward throttle level (of 4) the plan allows.
func throttle_cap() -> int:
	return roundi(_throttle * 4.0) if _active and _throttle >= 0.0 else 4


## Held bow heading, and its length (throttle share); INF while following the route or off.
func debug_heading() -> Vector2:
	return Vector2(_heading, absf(_throttle)) if _active and not _on_route else Vector2(INF, 0.0)


func debug_text() -> String:
	if not _active:
		return "Stance: off"
	var gear: String = "astern" if _throttle < 0.0 else "%d/4" % throttle_cap()
	return "Stance %s %s %.0fs | %d guns on us" % ["route" if _on_route else "%.0f°" % rad_to_deg(_heading), gear,
		_until - SimClock.now(), _shooters.size()]


func _plan(ctx: SkillContext, intent: NavIntent, route: float, clock: SalvoClock, now: float) -> void:
	var opts := _sim_opts(ctx, route)
	opts.merge({"w_turn": TURN_W, "w_present": PRESENT_W, "axis": _fire_axis(ctx)})
	var gun_hs := _all_guns_headings(ctx)
	if not is_finite(route):
		opts.merge({"anchor": Vector2(intent.target_position.x, intent.target_position.z),
			"leash": ctx.ship.movement_controller._p().turning_circle_radius, "w_leash": LEASH_W})
	var leg: float = clock.dominant_tof if not _shooters.is_empty() else ctx.ship.artillery_controller.get_params().reload_time
	leg = maxf(leg, LEG_MIN_S)
	# A plan cut short (route turned away) or long expired is not one to favour.
	var held: bool = _until > -INF and now - _until < leg and _follows(_heading, _throttle, route)
	var cands: Array = []
	for astern in [false, true]:
		var hs := PackedFloat32Array()
		var gears := PackedFloat32Array()
		var kinds := PackedByteArray()
		for g: float in THROTTLES:
			# Braking reads as a dodge for one leg and nothing prices the sitting duck after it.
			if (g < 0.0) != astern or (g >= 0.0 and g < UNDER_FIRE_MIN_THROTTLE and not _shooters.is_empty()):
				continue
			if is_finite(route) and not astern:
				hs.append(route)
				gears.append(g)
				kinds.append(1)
			if held and not _on_route and _throttle == g:
				hs.append(_heading)
				gears.append(g)
				kinds.append(2)
			for i in range(0, HEADINGS, CANDIDATE_STRIDE):
				if _follows(_heading_of(i), g, route):
					hs.append(_heading_of(i))
					gears.append(g)
					kinds.append(0)
			for h in gun_hs:
				if _follows(h, g, route):
					hs.append(h)
					gears.append(g)
					kinds.append(0)
		if hs.is_empty():
			continue
		var scores: PackedFloat32Array = StanceSim.evaluate(
			opts.merged({"then_heading": _tail(ctx, route, astern), "then_at": leg}), hs, gears)
		for k in hs.size():
			var keep: bool = held and gears[k] == _throttle and (kinds[k] == 2 or (kinds[k] == 1 and _on_route))
			cands.append([hs[k], gears[k], kinds[k] == 1, scores[k] + (SWITCH_MARGIN if keep else 0.0), keep])
	if cands.is_empty():
		return
	var pick: Array = _simplest(ctx, cands, route)
	_heading = pick[0]
	_throttle = pick[1]
	_on_route = pick[2]
	_until = now + leg
	_since = now


## Of the plans within NEAR_TIE of the best: the one held, else the least
## manoeuvre (motion off the route, bow turn, gear change), then the narrowest
## presentation to the fire, so guns are shown at the least angle that bears them.
func _simplest(ctx: SkillContext, cands: Array, route: float) -> Array:
	var best: float = -INF
	for c in cands:
		best = maxf(best, c[3])
	var hdg: float = ctx.behavior._get_ship_heading()
	var astern_now: bool = ctx.ship.linear_velocity.dot(Vector3(sin(hdg), 0.0, cos(hdg))) < -1.0
	var axis: float = _fire_axis(ctx)
	var pick: Array = []
	var pick_key := Vector2(INF, INF)
	for c in cands:
		if c[3] < best - NEAR_TIE:
			continue
		if c[4]:
			return c
		var astern: bool = c[1] < 0.0
		var motion: float = wrapf(c[0] + PI, -PI, PI) if astern else c[0]
		var effort: float = absf(angle_difference(hdg, c[0])) + (GEAR_FLIP_TURN if astern != astern_now else 0.0)
		if is_finite(route):
			effort += absf(angle_difference(motion, route))
		var fold: float = 0.0
		if is_finite(axis):
			var a: float = absf(angle_difference(c[0], axis))
			fold = minf(a, PI - a)
		var key := Vector2(floorf(effort / SIMPLE_STEP), fold)
		if key.x < pick_key.x or (key.x == pick_key.x and key.y < pick_key.y):
			pick_key = key
			pick = c
	return pick


## The narrowest headings each side at which every turret bears on the target, when the guns would fire.
func _all_guns_headings(ctx: SkillContext) -> PackedFloat32Array:
	var t: Ship = ctx.target
	var arty = ctx.ship.artillery_controller
	if t == null or not is_instance_valid(t) or arty == null or not _guns_free(ctx):
		return PackedFloat32Array()
	return StanceSim.all_guns_headings(arty.guns, Vector2(t.global_position.x, t.global_position.z),
		ctx.behavior._get_ship_heading())

## Bearing of the weighted incoming fire, else of the target; INF with neither.
func _fire_axis(ctx: SkillContext) -> float:
	var v := Vector2.ZERO
	for sh in _shooters:
		v += Vector2(sin(float(sh.bearing)), cos(float(sh.bearing))) * float(sh.weight)
	if v.length_squared() < 1e-6:
		var t: Ship = ctx.target
		if t == null or not is_instance_valid(t):
			return INF
		var to: Vector3 = t.global_position - ctx.ship.global_position
		return atan2(to.x, to.z)
	return atan2(v.x, v.y)


## What a plan settles on after its first flight time.
func _tail(ctx: SkillContext, route: float, astern: bool) -> float:
	if is_finite(route):
		return wrapf(route + PI, -PI, PI) if astern else route
	if _shooters.is_empty():
		return ctx.behavior._get_ship_heading()
	var best: int = 0
	for i in HEADINGS:
		if _dps[i] < _dps[best]:
			best = i
	return _heading_of(best)


func reset() -> void:
	_until = -INF
	_on_route = false
	_active = false


## Incoming damage per second from `shooter` at `aspect_deg` off our bow, -1 unknown.
static func dps_at(ship: Ship, shooter: Ship, range_m: float, aspect_deg: float) -> float:
	var model := BotGunnery.damage_model(ship)
	BotGunnery.damage_model(shooter)
	var e: Dictionary = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	return maxf(float(e.ap_dps), float(e.he_dps)) if not e.is_empty() else -1.0


## (dps, repairable dps) of the worse ammo for us, or (-1, 0) unknown.
static func _expected(ship: Ship, shooter: Ship, range_m: float, aspect_deg: float) -> Vector2:
	var model := BotGunnery.damage_model(ship)
	BotGunnery.damage_model(shooter)
	var e: Dictionary = model.get_expected(shooter.get_instance_id(), ship.get_instance_id(), range_m, aspect_deg)
	if e.is_empty():
		return Vector2(-1.0, 0.0)
	var he: bool = float(e.he_dps) > float(e.ap_dps)
	var dps: float = float(e.he_dps) if he else float(e.ap_dps)
	return Vector2(dps, dps * float(e.get("he_heal" if he else "ap_heal", 0.5)))


## HP the repair party can still restore of NEW damage within `horizon`, from
## its real state: the charge running now, then each charge it can start in
## time, less what is already waiting to be repaired.
static func repair_spare(ship: Ship, horizon: float) -> float:
	var cm: ConsumableManager = ship.consumable_manager
	if cm == null:
		return 0.0
	var hc = ship.health_controller
	var spare: float = 0.0
	for item in cm.equipped_consumables:
		if item == null or item.type != ConsumableItem.ConsumableType.REPAIR_PARTY:
			continue
		var p := item.p() as RepairParty
		var ci := item.p() as ConsumableItem
		var per_use: float = hc.max_hp * p.heal_per_sec * ci.duration
		var left: int = ci.max_stack - item.used if ci.max_stack != -1 else 1 << 20
		var t: float = 0.0
		if cm.active_effects.has(item.id):
			spare += per_use * float(cm.active_effects[item.id])
			t = float(cm.active_effects[item.id]) * ci.duration + ci.cooldown_time
		elif cm.cooldowns.has(item.id):
			t = float(cm.cooldowns[item.id]) * ci.cooldown_time
		while left > 0 and t < horizon:
			spare += per_use
			left -= 1
			t += ci.duration + ci.cooldown_time
	return maxf(spare - hc.healable_damage, 0.0)


## Every gun that can reach us, weighted by how sure we are it is on us, with
## its salvo clock. False while unseen or while nothing shoots or aims here.
func _survey(ctx: SkillContext) -> bool:
	var ship: Ship = ctx.ship
	var clock: SalvoClock = ctx.behavior.salvo_clock
	_shooters = []
	if not ship.is_detected() or ship.team == null or ctx.server == null:
		return false
	var weight := {}
	for s in ctx.behavior.active_shooters_at_me.keys():
		weight[s] = 1.0
	for s in clock.aimers:
		weight[s] = 1.0
	if weight.is_empty():
		return false
	for e in ctx.server.get_valid_targets(ship.team.team_id):
		if weight.has(e) or not is_instance_valid(e) or e.artillery_controller == null:
			continue
		if ship.global_position.distance_to(e.global_position) <= e.artillery_controller.get_params()._range:
			weight[e] = BYSTANDER_WEIGHT
	var now: float = SimClock.now()
	for s in weight.keys():
		if not (s is Ship) or not is_instance_valid(s) or not s.is_alive():
			continue
		var to: Vector3 = s.global_position - ship.global_position
		var t: Array = _table(ship, s, Vector2(to.x, to.z).length())
		if (t[1] as PackedFloat32Array).is_empty():
			continue
		_shooters.append({"bearing": atan2(to.x, to.z), "rows": t[1], "weight": float(weight[s]),
			"reload": s.artillery_controller.get_params().reload_time, "next": clock.next_landing(s, now),
			"tof": t[2], "miss_cross": t[3].x, "miss_range": t[3].y})
	if _shooters.is_empty():
		return false
	_dps.resize(HEADINGS)
	for i in HEADINGS:
		var dps: float = 0.0
		for sh in _shooters:
			var a: int = clampi(roundi(rad_to_deg(absf(angle_difference(_heading_of(i), sh.bearing))) / ASPECT_STEP_DEG), 0, ASPECTS - 1)
			dps += float(sh.weight) * sh.rows[a]
		_dps[i] = dps
	return true


## No gun on us: true while a target is in reach of guns we will fire or of loaded tubes.
func _quiet(ctx: SkillContext) -> bool:
	var target: Ship = ctx.target
	if target == null or not is_instance_valid(target) or not target.is_alive():
		return false
	var d: float = ctx.ship.global_position.distance_to(target.global_position)
	var arty = ctx.ship.artillery_controller
	var guns: bool = _guns_free(ctx) and arty != null and d <= arty.get_params()._range
	var tubes: bool = ctx.behavior.would_fire_torpedoes() and not _loaded_tubes(ctx).is_empty()
	if not guns and not tubes:
		return false
	_shooters = []
	_dps.resize(HEADINGS)
	_dps.fill(0.0)
	return true


static func _guns_free(ctx: SkillContext) -> bool:
	return ctx.behavior.would_fire_guns()


## [range bucket, dps rows, flight time, spread of the fall of shot (across, along)].
func _table(ship: Ship, shooter: Ship, range_m: float) -> Array:
	var id := shooter.get_instance_id()
	var bucket := int(range_m / RANGE_BUCKET_M)
	var cached: Array = _tables.get(id, [])
	if not cached.is_empty() and int(cached[0]) == bucket:
		return cached
	# dps per aspect step, then the repairable part of each.
	var row := PackedFloat32Array()
	row.resize(2 * ASPECTS)
	for i in ASPECTS:
		var e := _expected(ship, shooter, range_m, i * ASPECT_STEP_DEG)
		if e.x < 0.0:
			row = PackedFloat32Array()
			break
		row[i] = e.x
		row[ASPECTS + i] = e.y
	var gp: GunParams = shooter.artillery_controller.get_params()
	var shot: Array = ProjectilePhysicsWithDragV2.calculate_launch_vector(shooter.global_position, ship.global_position, gp.shell1)
	var tof: float = float(shot[1]) if shot.size() > 1 and float(shot[1]) > 0.0 else 0.0
	var miss := Vector2.ZERO
	if gp.dispersion != null:
		miss = gp.dispersion.dispersion_at(range_m, gp._range) * 0.5 / maxf(gp.dispersion.sigma, 0.1)
		# Vertical spread aims above or below us, so it lands spread along range.
		var shell := BotGunnery._shell_at(BotGunnery._shell_table(gp.shell1), range_m)
		miss.y /= tan(deg_to_rad(clampf(float(shell[0]) if not shell.is_empty() else 45.0, 1.0, 89.0)))
	_tables[id] = [bucket, row, tof, miss]
	return _tables[id]


static func _heading_of(i: int) -> float:
	return wrapf(-PI + i * STEP, -PI, PI)


static func _follows(h: float, throttle: float, route: float) -> bool:
	if not is_finite(route):
		return true
	var motion: float = wrapf(h + PI, -PI, PI) if throttle < 0.0 else h
	return absf(angle_difference(motion, route)) <= ROUTE_CONE


## The hull, the guns on us per heading, and our turrets on the target, for StanceSim.
func _sim_opts(ctx: SkillContext, route: float) -> Dictionary:
	var ship: Ship = ctx.ship
	var mv = ship.movement_controller
	var p: MovementParams = mv._p()
	var heading: float = ctx.behavior._get_ship_heading()
	var vmax: float = maxf(mv.max_speed, 1.0)
	var radius: float = maxf(p.turning_circle_radius, 1.0)
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var horizon: float = HORIZON_BASE_S + PI * radius / (vmax * TURN_SPEED_FRAC)
	var opts := {"heading": heading, "v": ship.linear_velocity.dot(Vector3(sin(heading), 0.0, cos(heading))),
		"vmax": vmax, "radius": radius, "tighten": p.slow_speed_turn_tightening, "spool": p.acceleration_time,
		"reverse": p.reverse_speed_ratio, "half_length": mv.ship_length * 0.5,
		"rudder_s": p.rudder_response_time, "yaw_rate": ship.angular_velocity.y,
		"hp": ship.health_controller.current_hp, "pos": here,
		"shooters": _shooters, "aspect_step": ASPECT_STEP_DEG, "route": route if is_finite(route) else INF,
		"horizon": horizon, "spare": repair_spare(ship, horizon), "dt": SIM_DT,
		"w_progress": PROGRESS_W, "w_closing": CLOSING_W, "w_deal": DEAL_WEIGHT}
	var target: Ship = ctx.target
	var arty = ship.artillery_controller
	if target == null or not is_instance_valid(target) or not target.is_alive() or arty == null:
		return opts
	_add_tubes(opts, ctx, target)
	var to_me: Vector3 = ship.global_position - target.global_position
	var range_m: float = Vector2(to_me.x, to_me.z).length()
	var gp: GunParams = arty.get_params()
	if range_m > gp._range or not _guns_free(ctx):
		return opts
	var t_fwd: Vector3 = -target.global_transform.basis.z
	var aspect: float = rad_to_deg(absf(angle_difference(atan2(t_fwd.x, t_fwd.z), atan2(to_me.x, to_me.z))))
	var out := _expected(target, ship, range_m, aspect)
	if out.x < 0.0:
		return opts
	var ready := PackedFloat32Array()
	for g in arty.guns:
		ready.append((1.0 - clampf(g.reload, 0.0, 1.0)) * gp.reload_time)
	opts.merge({"target": Vector2(target.global_position.x, target.global_position.z), "guns": arty.guns,
		"gun_ready": ready, "reload_s": gp.reload_time, "traverse": gp.traverse_speed, "out_dps": out.x})
	return opts


## Loaded tubes, the torpedo lead and what a launch is worth, when the launcher would fire:
## a solved lead, which is also the launcher's own range gate.
func _add_tubes(opts: Dictionary, ctx: SkillContext, _target: Ship) -> void:
	var tc = ctx.ship.torpedo_controller
	var loaded := _loaded_tubes(ctx)
	if loaded.is_empty() or not ctx.behavior.would_fire_torpedoes():
		return
	var muzzles: int = 0
	for l: TorpedoLauncher in loaded:
		muzzles += l.muzzles.size()
	var aim: Vector3 = ctx.behavior.torpedo_target_position
	opts.merge({"tubes": loaded, "tube_target": Vector2(aim.x, aim.z),
		"tube_value": float(muzzles) / loaded.size() * tc.get_torp_params().damage * TORP_HIT_SHARE})


static func _loaded_tubes(ctx: SkillContext) -> Array:
	var tc = ctx.ship.torpedo_controller
	if tc == null or tc.get_params() == null:
		return []
	return tc.launchers.filter(func(l): return is_instance_valid(l) and l.reload >= 1.0 and not l.disabled)

## Bearing the route runs toward, INF once there.
static func _route_bearing(intent: NavIntent, ctx: SkillContext) -> float:
	if ctx.navigator == null or ctx.navigator.is_arrived():
		return INF
	var to: Vector3 = ctx.navigator.get_current_waypoint() - ctx.ship.global_position
	to.y = 0.0
	if to.length_squared() < 1.0:
		to = intent.target_position - ctx.ship.global_position
		to.y = 0.0
	return atan2(to.x, to.z) if to.length_squared() >= 1.0 else INF
