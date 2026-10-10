class_name SkillStance
extends BotSkill

## Owns heading and gear while guns can reach us. Once per enemy flight time
## it commits to a plan: hold heading H (ahead or astern) for that flight time,
## then the tail (the route, or the heading taking least fire) for the rest of a
## horizon a minute past a half turn. Each plan is sailed (StanceSim) with every
## enemy's salvos landing on its own clock at the aspect shown then, and our guns
## and loaded tubes firing when they bear. Score = HP lost for good (repair
## counted), less a third of the HP dealt, plus progress. Showing the side in a
## reload gap and turning the tubes on are plans that win.
## SkillEvade weaves inside the cone of headings nearly as cheap.

const STEP: float = deg_to_rad(5.0)
const HEADINGS: int = 72
## Candidates are every CANDIDATE_STRIDE-th heading.
const CANDIDATE_STRIDE: int = 3
const ASPECT_STEP_DEG: float = 5.0
const ASPECTS: int = 37
const RANGE_BUCKET_M: float = 250.0
## Judged this long past the time a half turn takes, so every option is seen settled.
const HORIZON_BASE_S: float = 60.0
## Speed through a hard turn, as a share of full.
const TURN_SPEED_FRAC: float = 0.75
const SIM_DT: float = 3.0
## Headings costing no more than this over the chosen one are its cone.
const CONE_TOL: float = 0.25
const MIN_CONE: float = deg_to_rad(5.0)
const MAX_CONE: float = deg_to_rad(45.0)
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
## Share of a loaded tube's torpedoes expected to hit.
const TORP_HIT_SHARE: float = 0.1

var _heading: float = 0.0
var _astern: bool = false
## The plan is the route's own heading, whatever it shows.
var _on_route: bool = false
var _until: float = -INF
var _active: bool = false
var _cone: float = MIN_CONE
## Shooter instance id -> [range bucket, dps per aspect step then their repairable parts].
var _tables: Dictionary = {}

## StanceSim shooter entries: bearing, rows, weight, reload, next.
var _shooters: Array[Dictionary] = []
## Per heading index: weighted incoming dps, for the cone.
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
	var stale: bool = (_on_route and not is_finite(route)) or not _follows(_heading, _astern, route)
	if now >= _until or stale:
		_plan(ctx, route, clock, now)
	if _on_route:
		_active = false
		intent.forbid_reverse = true
		return intent
	_active = true
	_cone = _cone_at(_heading)
	intent.target_heading = _heading
	intent.heading_weight = 1.0
	intent.force_reverse = _astern
	intent.forbid_reverse = not _astern
	return intent


func debug_text() -> String:
	if not _active:
		return "Stance: route"
	return "Stance %.0f° %s %.0fs | %d guns on us" % [rad_to_deg(_heading), "astern" if _astern else "ahead",
		_until - SimClock.now(), _shooters.size()]


func _plan(ctx: SkillContext, route: float, clock: SalvoClock, now: float) -> void:
	var opts := _sim_opts(ctx, route)
	var leg: float = clock.dominant_tof if not _shooters.is_empty() else ctx.ship.artillery_controller.get_params().reload_time
	leg = maxf(leg, LEG_MIN_S)
	# A plan cut short (route turned away) or long expired is not one to favour.
	var held: bool = _until > -INF and now - _until < leg and _follows(_heading, _astern, route)
	var best: float = -INF
	for astern in [false, true]:
		var hs := PackedFloat32Array()
		var kinds := PackedByteArray()
		if is_finite(route) and not astern:
			hs.append(route)
			kinds.append(1)
		if held and not _on_route and _astern == astern:
			hs.append(_heading)
			kinds.append(2)
		for i in range(0, HEADINGS, CANDIDATE_STRIDE):
			if _follows(_heading_of(i), astern, route):
				hs.append(_heading_of(i))
				kinds.append(0)
		if hs.is_empty():
			continue
		var gears := PackedByteArray()
		gears.resize(hs.size())
		gears.fill(1 if astern else 0)
		var scores: PackedFloat32Array = StanceSim.evaluate(
			opts.merged({"then_heading": _tail(ctx, route, astern), "then_at": leg}), hs, gears)
		for k in hs.size():
			var keep: bool = held and (kinds[k] == 2 or (kinds[k] == 1 and _on_route))
			var sc: float = scores[k] + (SWITCH_MARGIN if keep else 0.0)
			if sc > best:
				best = sc
				_heading = hs[k]
				_astern = astern
				_on_route = kinds[k] == 1
	_until = now + leg


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


## `h` pulled back inside the held heading's cone; unchanged when idle.
func clamp_heading(h: float) -> float:
	if not _active:
		return h
	return wrapf(_heading + clampf(angle_difference(_heading, h), -_cone, _cone), -PI, PI)


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
		var row := _table(ship, s, Vector2(to.x, to.z).length())
		if row.is_empty():
			continue
		_shooters.append({"bearing": atan2(to.x, to.z), "rows": row, "weight": float(weight[s]),
			"reload": s.artillery_controller.get_params().reload_time, "next": clock.next_landing(s, now)})
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


## No gun on us: true while there is a target to bring the turrets or tubes to.
func _quiet(ctx: SkillContext) -> bool:
	if ctx.target == null or not is_instance_valid(ctx.target) or not ctx.target.is_alive():
		return false
	_shooters = []
	_dps.resize(HEADINGS)
	_dps.fill(0.0)
	return true


func _table(ship: Ship, shooter: Ship, range_m: float) -> PackedFloat32Array:
	var id := shooter.get_instance_id()
	var bucket := int(range_m / RANGE_BUCKET_M)
	var cached: Array = _tables.get(id, [])
	if not cached.is_empty() and int(cached[0]) == bucket:
		return cached[1]
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
	_tables[id] = [bucket, row]
	return row


static func _heading_of(i: int) -> float:
	return wrapf(-PI + i * STEP, -PI, PI)


static func _index_of(h: float) -> int:
	return posmod(roundi((h + PI) / STEP), HEADINGS)


static func _follows(h: float, astern: bool, route: float) -> bool:
	if not is_finite(route):
		return true
	var motion: float = wrapf(h + PI, -PI, PI) if astern else h
	return absf(angle_difference(motion, route)) <= ROUTE_CONE


func _cone_at(h: float) -> float:
	var i: int = _index_of(h)
	var limit: float = _dps[i] * (1.0 + CONE_TOL)
	var half: int = 0
	while (half + 1) * STEP <= MAX_CONE:
		if _dps[posmod(i + half + 1, HEADINGS)] > limit or _dps[posmod(i - half - 1, HEADINGS)] > limit:
			break
		half += 1
	return maxf(half * STEP, MIN_CONE)


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
		"reverse": p.reverse_speed_ratio, "hp": ship.health_controller.current_hp, "pos": here,
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
	if range_m > gp._range:
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


## Loaded tubes, the torpedo lead and what a launch is worth, when the target is in reach.
func _add_tubes(opts: Dictionary, ctx: SkillContext, target: Ship) -> void:
	var tc = ctx.ship.torpedo_controller
	if tc == null or tc.get_params() == null:
		return
	var tp: TorpedoLauncherParams = tc.get_params()
	if ctx.ship.global_position.distance_to(target.global_position) > tp._range:
		return
	var loaded: Array = []
	var muzzles: int = 0
	for l: TorpedoLauncher in tc.launchers:
		if is_instance_valid(l) and l.reload >= 1.0:
			loaded.append(l)
			muzzles += l.muzzles.size()
	if loaded.is_empty():
		return
	var aim: Vector3 = ctx.behavior.torpedo_target_position if ctx.behavior.has_valid_torpedo_solution else target.global_position
	opts.merge({"tubes": loaded, "tube_target": Vector2(aim.x, aim.z),
		"tube_value": float(muzzles) / loaded.size() * tc.get_torp_params().damage * TORP_HIT_SHARE})


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
