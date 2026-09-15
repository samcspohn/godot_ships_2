extends SceneTree

class StubShip:
	var global_position: Vector3
	func _init(p: Vector3) -> void:
		global_position = p
	func is_alive() -> bool:
		return true

class StubBehavior:
	var frame: FleetFrame
	func _init(f: FleetFrame) -> void:
		frame = f
	func fleet_frame() -> FleetFrame:
		return frame

class StubServer:
	var mine: Array = []
	var seen: Array = []
	func get_team_ships(_t: int) -> Array:
		return mine
	func get_valid_targets(_t: int) -> Array:
		return seen

func mk(positions: Array) -> Array:
	var out: Array = []
	for p in positions:
		out.append(StubShip.new(p))
	return out

func presume(positions: Array, radius: float) -> Array:
	var out: Array = []
	for p in positions:
		out.append({"position": p, "radius": radius})
	return out

func fmt(v: Vector3) -> String:
	return "(%.2f, %.2f)" % [v.x, v.z]

func _process(_delta: float) -> bool:
	var spawn_fwd := Vector3(0, 0, -20000)
	var fails := 0

	# ---- 1. Opening: fleets north/south, nothing spotted, presumed line only.
	var srv := StubServer.new()
	srv.mine = mk([Vector3(-8000,0,10000), Vector3(0,0,10000), Vector3(8000,0,10000)])
	srv.seen = []
	var f1 := FleetFrame.build(0, srv, presume(
		[Vector3(-9000,0,-10000), Vector3(0,0,-10000), Vector3(9000,0,-10000)], 1500.0), spawn_fwd)
	print("1  opening")
	print("   live=%s forward=%s right=%s spread=%.0f sep=%.0f"
		% [f1.live, fmt(f1.forward), fmt(f1.right), f1.spread, f1.separation])
	var l := f1.side_of(Vector3(-8000,0,10000))
	var r := f1.side_of(Vector3(8000,0,10000))
	print("   side(left ship)=%.2f  side(right ship)=%.2f  same_flank=%s"
		% [l, r, f1.sides_agree(l, r)])
	if not f1.live: fails += 1; print("   FAIL not live")
	if absf(f1.forward.z + 1.0) > 0.01: fails += 1; print("   FAIL forward not -Z")
	if f1.sides_agree(l, r): fails += 1; print("   FAIL opposite wings read as same flank")

	# ---- 2. Left flank fell, right held. Survivors: ours on +X, theirs on -X.
	var srv2 := StubServer.new()
	srv2.mine = mk([Vector3(9000,0,3000), Vector3(11000,0,-3000), Vector3(10000,0,0)])
	srv2.seen = mk([Vector3(-9000,0,1000), Vector3(-11000,0,-1000)])
	var f2 := FleetFrame.build(0, srv2, [], spawn_fwd)
	print("2  left flank fell, right held")
	print("   live=%s forward=%s right=%s spread=%.0f sep=%.0f"
		% [f2.live, fmt(f2.forward), fmt(f2.right), f2.spread, f2.separation])
	var n := f2.side_of(Vector3(9000,0,3000))
	var s := f2.side_of(Vector3(11000,0,-3000))
	print("   side(north ship)=%.2f  side(south ship)=%.2f  same_flank=%s"
		% [n, s, f2.sides_agree(n, s)])
	if absf(f2.forward.x + 1.0) > 0.05: fails += 1; print("   FAIL forward did not rotate to -X")
	if f2.sides_agree(n, s): fails += 1; print("   FAIL axis did not become north/south")

	# ---- 3. Blend: one spotted enemy must not capture the pole.
	var srv3 := StubServer.new()
	srv3.mine = mk([Vector3(0,0,10000)])
	srv3.seen = mk([Vector3(15000,0,0)])		  # lone contact, far right
	var f3 := FleetFrame.build(0, srv3, presume(
		[Vector3(-9000,0,-10000), Vector3(-6000,0,-10000), Vector3(-3000,0,-10000),
		 Vector3(0,0,-10000), Vector3(3000,0,-10000)], 1500.0), spawn_fwd)
	print("3  one contact right, five presumed left")
	print("   enemy_center=%s" % fmt(f3.enemy_center))
	if f3.enemy_center.x > 5000.0:
		fails += 1; print("   FAIL lone sighting captured the enemy pole")

	# ---- 4. Degenerate: fleets coincident -> fall back to spawn axis, no spin.
	var srv4 := StubServer.new()
	srv4.mine = mk([Vector3(0,0,0)])
	srv4.seen = mk([Vector3(100,0,100)])
	var f4 := FleetFrame.build(0, srv4, [], spawn_fwd)
	print("4  coincident fleets")
	print("   live=%s forward=%s" % [f4.live, fmt(f4.forward)])
	if f4.live: fails += 1; print("   FAIL claimed live at zero separation")
	if absf(f4.forward.z + 1.0) > 0.01: fails += 1; print("   FAIL did not fall back to spawn axis")

	# ---- 5. Deadband: a centreline contact belongs to everyone.
	print("5  deadband: sides_agree(0.9, -0.2)=%s  sides_agree(0.9, -0.9)=%s"
		% [f1.sides_agree(0.9, -0.2), f1.sides_agree(0.9, -0.9)])
	if not f1.sides_agree(0.9, -0.2): fails += 1; print("   FAIL centreline excluded")
	if f1.sides_agree(0.9, -0.9): fails += 1; print("   FAIL wings merged")

	# ---- 6. Local vs global: a pair pincers an isolated enemy while the main
	# lines trade on a quite different axis.
	var srv6 := StubServer.new()
	# Main lines: ours south, theirs north, both around x=0.
	var mine6: Array = [Vector3(-4000,0,10000), Vector3(0,0,10000), Vector3(4000,0,10000)]
	var seen6: Array = [Vector3(-4000,0,-10000), Vector3(0,0,-10000), Vector3(4000,0,-10000)]
	# The isolated enemy, far to the east, and the two of ours working it.
	var pocket := Vector3(20000,0,0)
	seen6.append(pocket)
	mine6.append(Vector3(17000,0,5000))
	mine6.append(Vector3(17000,0,-5000))
	srv6.mine = mk(mine6)
	srv6.seen = mk(seen6)

	var g6 := FleetFrame.build(0, srv6, [], spawn_fwd)
	var loc := FleetFrame.build(0, srv6, [], spawn_fwd, pocket, 8000.0)
	print("6  local pocket vs global battle")
	print("   global forward=%s   local forward=%s" % [fmt(g6.forward), fmt(loc.forward)])
	var gn := g6.side_of(Vector3(17000,0,5000))
	var gs := g6.side_of(Vector3(17000,0,-5000))
	var ln := loc.side_of(Vector3(17000,0,5000))
	var ls := loc.side_of(Vector3(17000,0,-5000))
	print("   global sides of the pair: %.2f / %.2f  same_flank=%s" % [gn, gs, g6.sides_agree(gn, gs)])
	print("   local  sides of the pair: %.2f / %.2f  same_flank=%s" % [ln, ls, loc.sides_agree(ln, ls)])
	if not g6.sides_agree(gn, gs):
		fails += 1; print("   FAIL global frame already split the pair")
	if loc.sides_agree(ln, ls):
		fails += 1; print("   FAIL local frame did not produce a pincer")
	if absf(loc.forward.x - 1.0) > 0.2:
		fails += 1; print("   FAIL local axis not pointed at the pocket enemy")

	# ---- 7. Locality falloff is smooth, not a cutoff.
	print("7  locality_weight: d=0 -> %.4f, d=scale -> %.4f, d=3*scale -> %.4f"
		% [FleetFrame.locality_weight(0.0, 8000.0),
		   FleetFrame.locality_weight(8000.0, 8000.0),
		   FleetFrame.locality_weight(24000.0, 8000.0)])
	if FleetFrame.locality_weight(24000.0, 8000.0) <= 0.0:
		fails += 1; print("   FAIL distant ships fall out of the frame entirely")

	# ---- 8. Depth budgeting arithmetic on top of depth_of().  SkillSpot no
	# longer runs this - its advance is gated on the detection circles instead
	# (section 9) - but depth_of() is still what tells a skill how far across
	# the gap a destination sits, so the arithmetic stays under test.
	var srv8 := StubServer.new()
	srv8.mine = mk([Vector3(-4000,0,10000), Vector3(0,0,10000), Vector3(4000,0,10000)])
	var f8 := FleetFrame.build(0, srv8, presume(
		[Vector3(-4000,0,-10000), Vector3(0,0,-10000), Vector3(4000,0,-10000)], 1500.0), spawn_fwd)
	var here8 := Vector3(0,0,10000)
	var contact8 := Vector3(0,0,-10000)
	var conceal := 3000.0
	var bearing8 := (contact8 - here8).normalized()
	var travel8: float = here8.distance_to(contact8) - conceal * 1.15
	var raw_travel := travel8
	var hd := f8.depth_of(here8)
	var dd := f8.depth_of(here8 + bearing8 * travel8)
	if dd > 0.35 and dd - hd > 0.001:
		travel8 *= clampf((0.35 - hd) / (dd - hd), 0.0, 1.0)
	var dest8 := here8 + bearing8 * travel8
	print("8  staging clamp")
	print("   sep=%.0f  here_depth=%.3f  unclamped travel=%.0f (depth %.3f)"
		% [f8.separation, hd, raw_travel, dd])
	print("   clamped travel=%.0f  dest=%s  dest_depth=%.3f"
		% [travel8, fmt(dest8), f8.depth_of(dest8)])
	if travel8 >= raw_travel:
		fails += 1; print("   FAIL clamp did not bind")
	if travel8 <= 0.0:
		fails += 1; print("   FAIL clamped to a stop on the line")
	if absf(f8.depth_of(dest8) - 0.35) > 0.01:
		fails += 1; print("   FAIL dest depth is not the budget")
	if bearing8.dot(dest8 - here8) <= 0.0:
		fails += 1; print("   FAIL advanced backwards")

	# ---- 9. SkillSpot's detection-circle gate, the real functions.
	#
	# The circles are the ones ThreatRegistry stamps for the router: one per
	# believed enemy, each sized to the range at which THIS ship becomes
	# visible.  _advance_limit() says how far down a bearing the ship may run
	# before it enters one; _push_out() walks a point that is already inside
	# back out.  Both are pure geometry, so they are tested directly.
	var spot_script: GDScript = load("res://src/ship/bot_behavior/skills/skill_spot.gd")
	var spot: Object = spot_script.new()
	var margin: float = spot_script.get_script_constant_map()["FRONTIER_MARGIN"]

	var here2 := Vector2(0.0, 10000.0)
	var north := Vector2(0.0, -1.0)   # straight at a contact sitting on the origin

	# 9a: the advance stops on the boundary, not on the contact.
	var one: Array[Dictionary] = [{ pos = Vector2(0.0, 0.0), radius = 5000.0 }]
	var g9a: Dictionary = spot._advance_limit(here2, north, 10000.0, one)
	print("9a advance clipped at the boundary: room=%.0f (expect 5000)" % float(g9a.distance))
	if absf(float(g9a.distance) - 5000.0) > 1.0:
		fails += 1; print("   FAIL did not stop on the circle")
	if (g9a.blocker as Dictionary).is_empty():
		fails += 1; print("   FAIL no blocker reported")

	# 9b: a contact the run passes wide of has no opinion about how far it goes.
	var wide: Array[Dictionary] = [{ pos = Vector2(20000.0, 0.0), radius = 5000.0 }]
	var g9b: Dictionary = spot._advance_limit(here2, north, 10000.0, wide)
	print("9b wide contact: room=%.0f (expect the full 10000)" % float(g9b.distance))
	if absf(float(g9b.distance) - 10000.0) > 1.0:
		fails += 1; print("   FAIL a contact off the bearing constrained the run")

	# 9c: a contact astern is behind us and equally irrelevant.
	var astern: Array[Dictionary] = [{ pos = Vector2(0.0, 20000.0), radius = 5000.0 }]
	var g9c: Dictionary = spot._advance_limit(here2, north, 10000.0, astern)
	print("9c contact astern: room=%.0f (expect the full 10000)" % float(g9c.distance))
	if absf(float(g9c.distance) - 10000.0) > 1.0:
		fails += 1; print("   FAIL a contact behind us constrained the run")

	# 9d: nearest circle on the bearing wins.
	var two: Array[Dictionary] = [
		{ pos = Vector2(0.0, 0.0), radius = 5000.0 },
		{ pos = Vector2(0.0, 4000.0), radius = 2000.0 },
	]
	var g9d: Dictionary = spot._advance_limit(here2, north, 10000.0, two)
	print("9d nearest circle binds: room=%.0f (expect 4000)" % float(g9d.distance))
	if absf(float(g9d.distance) - 4000.0) > 1.0:
		fails += 1; print("   FAIL the far circle won")

	# 9e: already inside one - no room at all, and the circle is named so the
	# caller can slide around it instead.
	var inside: Array[Dictionary] = [{ pos = Vector2(0.0, 9000.0), radius = 5000.0 }]
	var g9e: Dictionary = spot._advance_limit(here2, north, 10000.0, inside)
	print("9e starting inside: room=%.0f (expect 0)" % float(g9e.distance))
	if float(g9e.distance) > 0.001:
		fails += 1; print("   FAIL advanced further into a circle we are already in")
	if (g9e.blocker as Dictionary).is_empty():
		fails += 1; print("   FAIL no circle to slide around")

	# 9f: push-out lands just outside, by the same margin the navigator uses.
	var p9f: Vector2 = spot._push_out(Vector2(0.0, 1000.0), one)
	print("9f push-out: %.0f from centre (expect %.0f)"
		% [p9f.length(), 5000.0 + margin])
	if absf(p9f.length() - (5000.0 + margin)) > 1.0:
		fails += 1; print("   FAIL not pushed to the boundary plus margin")
	if p9f.y <= 0.0:
		fails += 1; print("   FAIL pushed out through the far side")

	# 9g: a point that was already clear passes through untouched.
	var clear9 := Vector2(0.0, 9000.0)
	var p9g: Vector2 = spot._push_out(clear9, one)
	print("9g already clear: untouched=%s" % [p9g == clear9])
	if p9g != clear9:
		fails += 1; print("   FAIL moved a destination that was already outside")

	# 9h: overlapping circles - one pass pushes into the next, so the result
	# has to be outside BOTH.
	var overlap: Array[Dictionary] = [
		{ pos = Vector2(0.0, 0.0), radius = 5000.0 },
		{ pos = Vector2(6000.0, 0.0), radius = 5000.0 },
	]
	var p9h: Vector2 = spot._push_out(Vector2(3000.0, 200.0), overlap)
	var d0: float = p9h.distance_to(Vector2(0.0, 0.0))
	var d1: float = p9h.distance_to(Vector2(6000.0, 0.0))
	print("9h overlap: %.0f from A, %.0f from B (both must clear 5000)" % [d0, d1])
	if d0 < 5000.0 - 1.0 or d1 < 5000.0 - 1.0:
		fails += 1; print("   FAIL settled inside one of the pair")

	# 9i: the slide works AWAY from our own fleet, so a screen fans out across
	# the enemy's bearing instead of every boat piling onto the same arc.
	# Contact on the origin, us due north of it, the fleet off to the north-east:
	# the step has to carry us west.
	var contact9 := Vector2(0.0, 0.0)
	var us9 := Vector2(0.0, 10000.0)
	var side9: float = spot._pick_side(contact9, us9, Vector2(5000.0, 15000.0))
	var step9: float = deg_to_rad(spot_script.get_script_constant_map()["SLIDE_ANGLE_DEG"])
	var arm9: Vector2 = us9 - contact9
	var a9: float = atan2(arm9.y, arm9.x) + step9 * side9
	var slid: Vector2 = contact9 + Vector2(cos(a9), sin(a9)) * arm9.length()
	print("9i slide side=%.0f -> %s (fleet is east; must go west)" % [side9, fmt(Vector3(slid.x, 0.0, slid.y))])
	if slid.x >= 0.0:
		fails += 1; print("   FAIL slid toward our own fleet")
	if absf(slid.length() - arm9.length()) > 1.0:
		fails += 1; print("   FAIL slide did not hold the standoff")

	print("")
	print("FAILURES: %d" % fails)
	return true
