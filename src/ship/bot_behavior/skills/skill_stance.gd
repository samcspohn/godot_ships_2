class_name SkillStance
extends BotSkill

## Owns heading and gear while guns can reach us. Each (heading, gear) option
## is sailed (StanceSim) at the hull's spool and turn rate for a minute past
## the time a half turn takes, every enemy's salvos landing on its own clock at
## the aspect we show then, our turrets slewing and firing on their reloads.
## Score = HP lost for good (repair capacity counted), less a third of the HP
## dealt, plus progress; at a station, closing on the guns stands in for progress.
## The steady pick holds; a lead leg (another heading for one flight time, then
## back to the steady one) is taken when it pays, which is how the side is shown
## in a reload gap or the tubes are brought to bear.
## SkillEvade weaves inside the cone of headings nearly as cheap.

## Choice index for following the route's own heading, whatever it shows.
const FREE: int = -2

const STEP: float = deg_to_rad(5.0)
const HEADINGS: int = 72
## Candidates are every CANDIDATE_STRIDE-th heading; the held one is refined by STEP.
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
## Hysteresis, in shares of remaining HP over the horizon.
const SWITCH_MARGIN: float = 0.02
## Stance picks how to follow the skill's route, never whether: motion stays within this of it.
const ROUTE_CONE: float = deg_to_rad(90.0)
const FREE_MARGIN: float = 0.01
const TRACK_GAIN: float = 0.002
const LEG_MIN_S: float = 6.0
## Share of a loaded tube's torpedoes expected to hit.
const TORP_HIT_SHARE: float = 0.1

var _heading: float = 0.0
var _astern_held: bool = false
var _has_choice: bool = false
var _hold_until: float = -INF
var _active: bool = false
var _cone: float = MIN_CONE
## Shooter instance id -> [range bucket, dps per aspect step then their repairable parts].
var _tables: Dictionary = {}

var _leg_heading: float = 0.0
var _leg_astern: bool = false
var _leg_until: float = -INF

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
	var opts := _sim_opts(ctx, route)
	var now: float = SimClock.now()
	var leading: bool = now < _leg_until and _follows(_leg_heading, _leg_astern, route)
	if not leading:
		_steady(opts, route, clock, now)
		leading = _lead(opts, route, clock, now)
	var h: float = _leg_heading if leading else _heading
	var astern: bool = _leg_astern if leading else _astern_held
	if not leading and _heading == FREE:
		_active = false
		intent.forbid_reverse = true
		return intent
	_active = true
	_cone = _cone_at(h)
	intent.target_heading = h
	intent.heading_weight = 1.0
	intent.force_reverse = astern
	intent.forbid_reverse = not astern
	return intent


func debug_text() -> String:
	if not _active:
		return "Stance: route"
	var left: float = _leg_until - SimClock.now()
	var h: float = _leg_heading if left > 0.0 else _heading
	var gear: String = "astern" if (_leg_astern if left > 0.0 else _astern_held) else "ahead"
	var what: String = "lead %.0fs" % left if left > 0.0 else "steady"
	return "Stance %s %.0f° %s | %d guns on us" % [what, rad_to_deg(h), gear, _shooters.size()]


## The heading worth holding, with hysteresis: _heading (FREE follows the route).
func _steady(opts: Dictionary, route: float, clock: SalvoClock, now: float) -> void:
	var hs := PackedFloat32Array()
	var gears := PackedByteArray()
	_candidates(hs, gears, route)
	var grid: int = hs.size()
	if is_finite(route):
		hs.append(route)
		gears.append(0)
	var tracked: bool = _has_choice and _heading != FREE and _follows(_heading, _astern_held, route)
	if tracked:
		for k in [0, -1, 1]:
			hs.append(wrapf(_heading + k * STEP, -PI, PI))
			gears.append(1 if _astern_held else 0)
	var scores: PackedFloat32Array = StanceSim.evaluate(opts, hs, gears)
	var best: float = -INF
	var best_h: float = 0.0
	var best_astern: bool = false
	for k in grid:
		if scores[k] > best:
			best = scores[k]
			best_h = hs[k]
			best_astern = gears[k] == 1
	var free: float = scores[grid] + FREE_MARGIN if is_finite(route) else -INF
	var held: float = -INF
	if tracked:
		var base: int = grid + (1 if is_finite(route) else 0)
		held = scores[base]
		for k in [1, 2]:
			if scores[base + k] > held + TRACK_GAIN:
				held = scores[base + k]
				_heading = hs[base + k]
	elif _has_choice and _heading == FREE:
		held = free
	var top: float = maxf(best, free)
	# Held for a flight time: flipping ends mid-salvo shows the side the angle was hiding.
	if not _has_choice or not is_finite(held) or (now >= _hold_until and top > held + SWITCH_MARGIN):
		_has_choice = true
		_hold_until = now + maxf(clock.dominant_tof, 1.0)
		if free >= best:
			_heading = FREE
		else:
			_heading = best_h
			_astern_held = best_astern


## Whether some other heading for one flight time, then back to the steady one, beats holding it.
func _lead(opts: Dictionary, route: float, clock: SalvoClock, now: float) -> bool:
	_leg_until = -INF
	var base_h: float = route if _heading == FREE else _heading
	if not is_finite(base_h):
		return false
	var base_astern: bool = _heading != FREE and _astern_held
	var leg: float = maxf(clock.dominant_tof, LEG_MIN_S)
	var o := opts.merged({"then_heading": base_h, "then_astern": 1.0 if base_astern else 0.0, "then_at": leg})
	var hs := PackedFloat32Array([base_h])
	var gears := PackedByteArray([1 if base_astern else 0])
	_candidates(hs, gears, route)
	var scores: PackedFloat32Array = StanceSim.evaluate(o, hs, gears)
	var best: int = 0
	for k in range(1, hs.size()):
		if scores[k] > scores[best]:
			best = k
	if best == 0 or scores[best] <= scores[0] + SWITCH_MARGIN:
		return false
	_leg_heading = hs[best]
	_leg_astern = gears[best] == 1
	_leg_until = now + leg
	return true


func _candidates(hs: PackedFloat32Array, gears: PackedByteArray, route: float) -> void:
	for i in range(0, HEADINGS, CANDIDATE_STRIDE):
		for astern in [0, 1]:
			if _follows(_heading_of(i), astern == 1, route):
				hs.append(_heading_of(i))
				gears.append(astern)


func reset() -> void:
	_leg_until = -INF
	_has_choice = false
	_hold_until = -INF
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
