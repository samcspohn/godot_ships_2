class_name BotDials
extends RefCounted

## doc/FIGHT_DIALS_DESIGN.md. Step 1: computed, eased and logged; nothing reads them yet.

const KEYS: Array[String] = ["advantage", "range_m", "exposure_tol", "stealth", "cover_kind", "spot", "advance"]
const TAU_S := {"advantage": 10.0, "range_m": 15.0, "exposure_tol": 10.0, "stealth": 15.0, "cover_kind": 15.0, "spot": 10.0, "advance": 10.0}
## Advantage: weights of team strength, points and the local force ratio.
const ADV_W := Vector3(0.4, 0.2, 0.4)
## Friends and enemies within this share of their gun range of the priority count toward the local ratio.
const LOCAL_REACH := 1.0
const SUSTAIN_FLOOR_S := 60.0
const SUSTAIN_REF_S := 300.0
const WIN_MIN_S := 30.0
const WIN_MAX_S := 900.0
## Standing seen at a target's concealment radius this long is a full-value spot.
const SPOT_SUSTAIN_S := 180.0
## A target this much stealthier than us (its radius over ours) and this much faster is not ours to spot.
const SPOT_STEALTHIER := Vector2(0.85, 0.25)
const SPOT_FASTER := Vector2(1.0, 0.2)
const SPOT_RANK_W := [1.0, 0.8, 0.6, 0.4]
const PHASE_S := [300.0, 600.0]
## Trade ratios past this (INF beyond their guns) count as this.
const RATIO_CAP := 10.0

var raw := {}
var eased := {}
var incoming: float = 0.0
var spot_on := ""
var _at: float = -INF

## "<class>/<hull>" -> phase -> key -> samples, for match metrics.
static var stats: Dictionary = {}

func update(ctx: SkillContext) -> void:
	var b: BotBehavior = ctx.behavior
	var ship: Ship = ctx.ship
	if ship.artillery_controller == null or ship.team == null or ctx.server == null:
		return
	var server: GameServer = ctx.server
	var late: float = clampf(1.0 - server.get_match_time_remaining() / server.MATCH_DURATION, 0.0, 1.0)
	var p: Ship = _focus(b)
	var here := Vector2(ship.global_position.x, ship.global_position.z)
	var hp_eff: float = b.trade_hp() / maxf(ship.health_controller.max_hp, 1.0)
	var local := _local_ratio(ctx, p, here)
	var o := BotBehavior.team_outlook(server, ship.team.team_id)
	var adv: float = clampf(ADV_W.x * o.y + ADV_W.y * o.x + ADV_W.z * local, -1.0, 1.0)
	raw.advantage = adv
	var trade := b._trade_now
	incoming = (ship.health_controller.current_hp / maxf(ship.health_controller.max_hp, 1.0)) / trade.x if trade.x > 0.0 else 0.0
	var win: float = trade.y
	raw.exposure_tol = hp_eff / clampf(win if win > 0.0 else SUSTAIN_REF_S, WIN_MIN_S, WIN_MAX_S) * exp(BotBehavior.AGGRESSION_STAY * adv)
	raw.advance = clampf(0.5 + 0.5 * (local + adv * late), 0.0, 1.0)
	var conceal: float = NavigationMapManager.reach_conceal_radius(ship)
	if p != null:
		var tr: Dictionary = b._trade(p)
		var base: float = b.desired(p).x
		var close: float = minf(float(tr.push), base) if float(tr.push) >= 0.0 else base
		var r: float = lerpf(base, close, clampf(adv, 0.0, 1.0) * (0.5 + 0.5 * late))
		raw.range_m = r
		var at_r: float = minf(_at_range(tr.ratios, r), RATIO_CAP)
		var worst: float = _worst(tr.ratios, r, minf(conceal, p.artillery_controller.get_params()._range))
		raw.stealth = clampf(1.0 - worst / at_r, 0.0, 1.0) if at_r > 0.0 else 0.0
		var inc: float = _at_range(tr["in"], r)
		raw.cover_kind = clampf((1.0 / maxf(inc, 1e-6) - SUSTAIN_FLOOR_S) / (SUSTAIN_REF_S - SUSTAIN_FLOOR_S), 0.0, 1.0)
	raw.spot = _spot(ctx, b, conceal, here)
	_ease()
	_dump_curves(ctx)
	_record(ship, server.MATCH_DURATION - server.get_match_time_remaining())

## The priority, else the first identified one.
static func _focus(b: BotBehavior) -> Ship:
	var p := b.priority_target()
	if p != null:
		return p
	for c in b.priorities:
		if c.ship != null and is_instance_valid(c.ship) and c.ship.is_alive():
			return c.ship
	return null

## log2 of friendly over enemy alive HP within their gun reach of the priority (else of us), -1..1.
static func _local_ratio(ctx: SkillContext, p: Ship, here: Vector2) -> float:
	var at := here
	if p != null:
		at = Vector2(p.global_position.x, p.global_position.z)
	var mine := 0.0
	for f: Ship in ctx.server.get_team_ships(ctx.ship.team.team_id):
		if is_instance_valid(f) and f.is_alive() and f.artillery_controller != null \
				and Vector2(f.global_position.x, f.global_position.z).distance_to(at) <= f.artillery_controller.get_params()._range * LOCAL_REACH:
			mine += f.health_controller.current_hp
	var theirs := 0.0
	for e in ctx.server._team_belief(ctx.ship.team.team_id):
		var s: Ship = e.ship
		if is_instance_valid(s) and s.is_alive() and s.artillery_controller != null \
				and (e.pos as Vector2).distance_to(at) <= s.artillery_controller.get_params()._range * LOCAL_REACH:
			theirs += s.health_controller.current_hp
	if mine <= 0.0 and theirs <= 0.0:
		return 0.0
	return clampf(log(maxf(mine, 1.0) / maxf(theirs, 1.0)) / log(2.0), -1.0, 1.0)

## Best spot value over the top priorities still dark, rank-weighted.
func _spot(ctx: SkillContext, b: BotBehavior, conceal: float, here: Vector2) -> float:
	var best := 0.0
	spot_on = ""
	var rank := 0
	var belief: Array[Dictionary] = ctx.server._team_belief(ctx.ship.team.team_id)
	for c in b.priorities:
		if rank >= SPOT_RANK_W.size():
			break
		var e: Ship = c.ship
		if e == null or not is_instance_valid(e) or not e.is_alive():
			continue
		rank += 1
		if e.visible_to_enemy or e.concealment == null or e.concealment.params == null:
			continue
		var v: float = SPOT_RANK_W[rank - 1] * spot_value(b, e, conceal, here, belief)
		if v > best:
			best = v
			spot_on = e.ship_name
	return best

## Whether we can spot `e`: unseen if we out-conceal it; else by standing seen at its concealment
## radius, worth what we survive there, what our guns do there, and nothing on a stealthier, faster target.
static func spot_value(b: BotBehavior, e: Ship, conceal: float, here: Vector2, belief: Array[Dictionary]) -> float:
	var ce: float = (e.concealment.params.p() as ConcealmentParams).radius
	if conceal <= ce:
		return 1.0
	var me: Ship = b._ship
	var hp: float = maxf(b.trade_hp(), 1.0)
	var inc := 0.0
	for x in belief:
		var s: Ship = x.ship
		if not is_instance_valid(s) or not s.is_alive() or s.artillery_controller == null:
			continue
		var d: float = ce if s == e else maxf((x.pos as Vector2).distance_to(here), ce)
		if d <= s.artillery_controller.get_params()._range:
			inc += BotBehavior._curve_at(BotBehavior.dps_curve(s, me), d) / hp
	var survive: float = clampf(1.0 / maxf(inc, 1e-6) / SPOT_SUSTAIN_S, 0.0, 1.0)
	var tr: Dictionary = b._trade(e)
	var shoot: float = 0.5 + 0.5 * clampf(_at_range(tr.ratios, ce), 0.0, 1.0)
	var stealthier: float = clampf((SPOT_STEALTHIER.x - ce / conceal) / SPOT_STEALTHIER.y, 0.0, 1.0)
	var faster: float = clampf((e.movement_controller.max_speed / maxf(me.movement_controller.max_speed, 1.0) - SPOT_FASTER.x) / SPOT_FASTER.y, 0.0, 1.0)
	return survive * shoot * (1.0 - stealthier * faster)

## The worst trade on the approach from `far` (where we are seen and in its guns) in to `near`.
static func _worst(ratios: PackedFloat32Array, near: float, far: float) -> float:
	var w: float = minf(_at_range(ratios, near), RATIO_CAP)
	var r := near
	while r <= far:
		w = minf(w, _at_range(ratios, r))
		r += BotBehavior.RADIUS_STEP_M
	return w

static func _at_range(curve: PackedFloat32Array, r: float) -> float:
	if curve.is_empty():
		return 0.0
	var i: int = clampi(roundi((r - BotBehavior.POINT_BLANK_M) / BotBehavior.RADIUS_STEP_M), 0, curve.size() - 1)
	return curve[i]

func _ease() -> void:
	var now: float = SimClock.now()
	var dt: float = now - _at
	_at = now
	for k in raw:
		if not eased.has(k) or dt > 2.0 * float(TAU_S[k]):
			eased[k] = raw[k]
		else:
			eased[k] = lerpf(eased[k], raw[k], 1.0 - exp(-dt / float(TAU_S[k])))

func _record(ship: Ship, elapsed: float) -> void:
	var phase: String = "early" if elapsed < PHASE_S[0] else ("mid" if elapsed < PHASE_S[1] else "late")
	var key := "%s/%s" % [Ship.ShipClass.keys()[ship.ship_class], ship.ship_name]
	var row: Dictionary = stats.get_or_add(key, {}).get_or_add(phase, {})
	for k in eased:
		(row.get_or_add(k, []) as Array).append(eased[k])
	(row.get_or_add("incoming", []) as Array).append(incoming)

static func summary() -> Dictionary:
	var out := {}
	for key in stats:
		out[key] = {}
		for phase in stats[key]:
			out[key][phase] = {}
			for k in stats[key][phase]:
				var a: Array = (stats[key][phase][k] as Array).duplicate()
				a.sort()
				var q := func(f: float) -> float: return a[mini(int(a.size() * f), a.size() - 1)]
				out[key][phase][k] = {"n": a.size(), "p10": q.call(0.1), "p50": q.call(0.5), "p90": q.call(0.9)}
	return out

func debug_text() -> String:
	if eased.is_empty():
		return ""
	var g := func(k: String) -> float: return float(eased.get(k, -1.0))
	return "A %+.2f · R %.1fk · tol %.2f%%/s (in %.2f) · st %.2f · cov %.2f · spot %.2f%s · push %.2f" % [
		g.call("advantage"), g.call("range_m") / 1000.0, g.call("exposure_tol") * 100.0, incoming * 100.0,
		g.call("stealth"), g.call("cover_kind"), g.call("spot"), (" " + spot_on) if spot_on != "" else "", g.call("advance")]

var _dumped := {}

## CURVE_DUMP=<hull>: one CURVE line per enemy hull, every RADIUS_STEP_M, of both sides' dps and the trade.
func _dump_curves(ctx: SkillContext) -> void:
	var want := OS.get_environment("CURVE_DUMP")
	var me: Ship = ctx.ship
	if want.is_empty() or me.ship_name != want:
		return
	for e: Ship in ctx.server.get_team_ships(1 - me.team.team_id):
		if not is_instance_valid(e) or e.artillery_controller == null or _dumped.has(e.ship_name):
			continue
		_dumped[e.ship_name] = true
		var rows := []
		var top: float = maxf(me.artillery_controller.get_params()._range, e.artillery_controller.get_params()._range)
		var r: float = BotBehavior.POINT_BLANK_M
		while r <= top:
			rows.append({"r": r, "out": _parts(me, e, r), "in": _parts(e, me, r)})
			r += BotBehavior.RADIUS_STEP_M
		print("CURVE ", JSON.stringify({"me": me.ship_name, "e": e.ship_name, "me_hp": me.health_controller.max_hp,
			"e_hp": e.health_controller.max_hp, "me_range": me.artillery_controller.get_params()._range,
			"e_range": e.artillery_controller.get_params()._range,
			"me_sec": me.secondary_controller.get_max_range() if is_instance_valid(me.secondary_controller) else 0.0,
			"e_sec": e.secondary_controller.get_max_range() if is_instance_valid(e.secondary_controller) else 0.0, "rows": rows}))

static func _parts(shooter: Ship, target: Ship, r: float) -> Dictionary:
	var asp: float = BotBehavior.guns_bear_aspect(target)
	var exp_main: float = maxf(SkillStance._expected(target, shooter, r, asp).x, 0.0)
	var salvo: float = DamageExpectation.salvo_factor(shooter, target, r, asp)
	var sec_raw: float = BotBehavior._secondary_dps(shooter, target, r, asp)
	var size_mod: float = HPManager.size_mod(target.mass, BotBehavior.secondary_caliber(shooter))
	return {"main_exp": exp_main, "salvo": salvo, "main": exp_main * salvo, "sec_raw": sec_raw, "size_mod": size_mod,
		"sec": sec_raw * size_mod, "torp": BotBehavior.torpedo_rate(shooter, target, r) * target.health_controller.max_hp,
		"curve": BotBehavior._curve_at(BotBehavior.dps_curve(shooter, target), r)}
