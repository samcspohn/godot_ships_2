class_name BotDials
extends RefCounted

## doc/FIGHT_DIALS_DESIGN.md. Step 1: computed, eased and logged; nothing reads them yet.

const TAU_S := {"advantage": 10.0, "ring_shift": 15.0, "exposure_tol": 10.0, "approach_stealth": 15.0, "conceal_edge": 15.0,
	"cover_kind": 15.0, "spot": 10.0, "advance": 10.0}
## Advantage: weights of team strength, points and the local force ratio.
const ADV_W := Vector3(0.4, 0.2, 0.4)
## Friends and enemies within this share of their gun range of the priority count toward the local ratio.
const LOCAL_REACH := 1.0
const SUSTAIN_REF_S := 300.0
const WIN_MIN_S := 30.0
const WIN_MAX_S := 900.0
## Standing seen at a target's concealment radius this long is a full-value spot.
const SPOT_SUSTAIN_S := 180.0
## Enemies this far past the longer of their guns and our reach still count as local.
const LOCAL_MARGIN_M := 2000.0
## Torpedo reach past our concealment radius, as a share of it, that is a full concealment edge.
const TORP_EDGE_SHARE := 0.3
## A target's concealment radius this share past ours is a full spotting edge.
const SPOT_EDGE_SHARE := 0.3
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
## The held Fight station's distance to its target, else ours to the priority; -1 with neither.
var station_d: float = -1.0
var group_n: int = 0
var group_r: float = -1.0
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
	raw.ring_shift = clampf(adv, 0.0, 1.0) * (0.5 + 0.5 * late)
	var conceal: float = NavigationMapManager.reach_conceal_radius(ship)
	raw.conceal_edge = _conceal_edge(b, ship, conceal)
	station_d = _station_d(b, here)
	var group := _group(ctx, b, p, here, raw.ring_shift)
	group_n = group.size()
	if not group.is_empty():
		var r := _group_ring(group)
		group_r = r
		var reach := 0.0
		for g in group:
			reach = maxf(reach, (g.e as Ship).artillery_controller.get_params()._range)
		var at_r: float = _group_ratio(group, r)
		var worst := at_r
		var x := r
		while x <= minf(conceal, reach):
			worst = minf(worst, _group_ratio(group, x))
			x += BotBehavior.RADIUS_STEP_M
		raw.approach_stealth = clampf(1.0 - worst / at_r, 0.0, 1.0) if at_r > 0.0 else 0.0
		# Outliving the win under the group's fire affords being seen behind a shield.
		var sustain: float = 1.0 / maxf(_group_in(group, r), 1e-6)
		raw.cover_kind = clampf(sustain / clampf(win if win > 0.0 else SUSTAIN_REF_S, WIN_MIN_S, WIN_MAX_S), 0.0, 1.0)
	raw.spot = _spot(ctx, b, conceal, here)
	_ease()
	_record(ship, server.MATCH_DURATION - server.get_match_time_remaining())

## Believed enemies whose guns reach us, or ours them, within LOCAL_MARGIN_M; the focus alone with none:
## {e, tr (its trade), w (chance its guns are on us), ring (shifted)}.
static func _group(ctx: SkillContext, b: BotBehavior, p: Ship, here: Vector2, shift: float) -> Array:
	var friends: Array = ctx.server.get_team_ships(ctx.ship.team.team_id)
	var ours: float = BotBehavior.reach_m(ctx.ship)
	var out := []
	for x in ctx.server._team_belief(ctx.ship.team.team_id):
		var e: Ship = x.ship
		if not is_instance_valid(e) or not e.is_alive() or e.artillery_controller == null:
			continue
		if (x.pos as Vector2).distance_to(here) > maxf(e.artillery_controller.get_params()._range, ours) + LOCAL_MARGIN_M:
			continue
		out.append(_member(b, e, FightStation._aggro(ctx, e, x.pos, friends), shift, (x.pos as Vector2).distance_to(here)))
	if out.is_empty() and p != null:
		out.append(_member(b, p, 1.0, shift, Vector2(p.global_position.x, p.global_position.z).distance_to(here)))
	return out

static func _member(b: BotBehavior, e: Ship, w: float, shift: float, d: float) -> Dictionary:
	var tr: Dictionary = b._trade(e)
	return {"e": e, "tr": tr, "w": w, "d": d, "ring": shifted_ring(b.desired(e).x, float(tr.push), shift)}

## The rings averaged by the fire each enemy puts on us from where it is now; plain mean with none.
static func _group_ring(group: Array) -> float:
	var num := 0.0
	var den := 0.0
	for g in group:
		var k: float = float(g.w) * _at_range(g.tr["in"], float(g.d))
		num += k * float(g.ring)
		den += k
	if den > 0.0:
		return num / den
	return group.reduce(func(a, g): return a + float(g.ring), 0.0) / group.size()

## Their fire on us, every member at `r`: share of our trade HP per second.
static func _group_in(group: Array, r: float) -> float:
	return group.reduce(func(a, g): return a + float(g.w) * _at_range(g.tr["in"], r), 0.0)

## Our best target's share per second over the group's fire, every member at `r`.
static func _group_ratio(group: Array, r: float) -> float:
	var best: float = group.reduce(func(a, g): return maxf(a, _at_range(g.tr.out, r)), 0.0)
	var inc := _group_in(group, r)
	return minf(best / inc, RATIO_CAP) if inc > 0.0 else (RATIO_CAP if best > 0.0 else 0.0)

## An enemy's ring moved `shift` of the way from its desired range in to its push range.
static func shifted_ring(desired: float, push: float, shift: float) -> float:
	return lerpf(desired, minf(push, desired), shift) if push >= 0.0 else desired

## How much of our worth we can deliver unseen: torpedoes reaching past our concealment radius
## (guns bloom to their own range, so never), or top priorities we out-conceal and so spot dark.
static func _conceal_edge(b: BotBehavior, ship: Ship, conceal: float) -> float:
	var torp := 0.0
	var tc: TorpedoController = ship.torpedo_controller if is_instance_valid(ship.torpedo_controller) else null
	if tc != null and not tc.launchers.is_empty() and conceal > 0.0:
		torp = clampf((tc.get_max_range() - conceal) / (conceal * TORP_EDGE_SHARE), 0.0, 1.0)
	var spot := 0.0
	var n := 0
	for c in b.priorities:
		if n >= BotBehavior.PRIORITY_COUNT:
			break
		var e: Ship = c.ship
		if e == null or not is_instance_valid(e) or e.concealment == null or e.concealment.params == null:
			continue
		n += 1
		var ce: float = (e.concealment.params.p() as ConcealmentParams).radius
		spot += clampf((ce / maxf(conceal, 1.0) - 1.0) / SPOT_EDGE_SHARE, 0.0, 1.0)
	return maxf(torp, spot / n if n > 0 else 0.0)

static func _station_d(b: BotBehavior, here: Vector2) -> float:
	var st: FightStation = b._skill_fight.station
	if st.has_station() and is_instance_valid(st._target):
		var sp: Vector3 = st.station_position()
		return Vector2(sp.x, sp.z).distance_to(Vector2(st._target.global_position.x, st._target.global_position.z))
	var pp: Vector3 = b.priority_point()
	return here.distance_to(Vector2(pp.x, pp.z)) if pp.is_finite() else -1.0

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
	if station_d >= 0.0:
		(row.get_or_add("station_d", []) as Array).append(station_d)
	if group_r >= 0.0:
		(row.get_or_add("group_r", []) as Array).append(group_r)
	(row.get_or_add("group_n", []) as Array).append(float(group_n))

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
	return "A %+.2f · ring %.2f · grp %d @ %.1fk · d %.1fk · tol %.2f%%/s (in %.2f) · appr %.2f · edge %.2f · cov %.2f · spot %.2f%s · push %.2f" % [
		g.call("advantage"), g.call("ring_shift"), group_n, group_r / 1000.0, station_d / 1000.0, g.call("exposure_tol") * 100.0, incoming * 100.0,
		g.call("approach_stealth"), g.call("conceal_edge"), g.call("cover_kind"), g.call("spot"),
		(" " + spot_on) if spot_on != "" else "", g.call("advance")]

