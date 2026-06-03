extends BotBehavior
class_name DDBehavior

var ammo = ShellParams.ShellType.HE

# Speed variation for evasion
var speed_variation_timer: float = 0.0
var current_speed_multiplier: float = 1.0
const SPEED_VARIATION_PERIOD: float = 3.0
const SPEED_VARIATION_MIN: float = 0.6
const SPEED_VARIATION_MAX: float = 1.0

# Skills
var _skill_hunt: SkillHunt = SkillHunt.new()
var _skill_chase: SkillChase = SkillChase.new()
var _skill_torpedo_run: SkillTorpedoRun = SkillTorpedoRun.new()
var _skill_kite: SkillKite = SkillKite.new()
var _skill_retreat: SkillRetreat = SkillRetreat.new()
var _skill_flank: SkillFlank = SkillFlank.new()
var _skill_spot: SkillSpot = SkillSpot.new()
var _skill_spread: SkillSpread = SkillSpread.new()
var _skill_broadside: SkillBroadside = SkillBroadside.new()
var _skill_push: SkillPush = SkillPush.new()

# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(10),
		max_angle = deg_to_rad(25),
		evasion_period = 2.5,  # Quick, erratic weaving
		vary_speed = true      # Only DDs vary speed
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 2.0   # CAs are DD hunters
		Ship.ShipClass.DD: return 0.5
	return 1.0

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.50,
		range_increase_when_damaged = 0.30,
		min_safe_distance_ratio = 0.30,
		flank_bias_healthy = 0.7,
		flank_bias_damaged = 0.1,
		spread_distance = 1500.0,  # DDs spread more
		spread_multiplier = 1.0,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.8,      # DDs hunt aggressively
		cautious_hp_threshold = 0.3,
	}

func _roll_flank_depth() -> float:
	return randf_range(0.4, 0.9)

# ============================================================================
# EVASION - DD-specific with speed variation
# ============================================================================

func get_desired_heading(target: Ship, current_heading: float, delta: float, destination: Vector3) -> Dictionary:
	"""Override to add speed variation for DDs."""
	var result = super.get_desired_heading(target, current_heading, delta, destination)

	# Update speed variation when evading
	if result.use_evasion:
		speed_variation_timer += delta
		var speed_wave = (sin(speed_variation_timer * TAU / SPEED_VARIATION_PERIOD) + 1.0) / 2.0
		current_speed_multiplier = lerp(SPEED_VARIATION_MIN, SPEED_VARIATION_MAX, speed_wave)
	else:
		current_speed_multiplier = 1.0

	return result

func get_speed_multiplier() -> float:
	"""Returns current speed multiplier for evasion."""
	return current_speed_multiplier

# ============================================================================
# TARGET SELECTION - DD-specific logic (visible vs hidden priority)
# ============================================================================

func pick_target(targets: Array[Ship], _last_target: Ship) -> Ship:
	"""DD target selection differs based on visibility - torpedoes vs guns.
	Prefers targets we can actually shoot at over ones behind cover.
	Balances proximity threats against overextended enemies:
	 - Enemies very close get a strong proximity boost.
	 - Enemies farthest into friendly territory get an overextension bonus.
	 - When nothing is dangerously close, the most overextended enemy wins."""
	var gun_range = _ship.artillery_controller.get_params()._range
	var torpedo_range: float = -1.0
	var proximity_override_dist: float = 2500.0  # DDs are fast, smaller threshold
	var overextension_weight: float = 0.3
	var overextension_bonus: float = 1.8

	if _ship.torpedo_controller != null:
		torpedo_range = _ship.torpedo_controller.get_params()._range

	# --- First pass: compute base priority and overextension for every target ---
	var candidate_data: Array[Dictionary] = []
	var max_overextension: float = 0.0
	var has_close_threat: bool = false

	for ship in targets:
		var disp = ship.global_position - _ship.global_position
		var dist = disp.length()
		var angle = (-ship.basis.z).angle_to(disp)
		angle -= PI / 4  # Best angle to torpedo is 45 degrees incoming
		var priority: float = 0.0

		if !_ship.visible_to_enemy:
			# Hidden - prioritize torpedo targets
			priority = cos(angle) * ship.movement_controller.ship_length / dist
			if torpedo_range > 0:
				priority = priority * 0.3 + (1.0 - dist / torpedo_range) * 0.7
			if ship.ship_class == Ship.ShipClass.BB:
				priority *= 2.0  # BBs are prime torpedo targets
		else:
			# Visible - prioritize gun targets
			priority = (1.0 - dist / gun_range)

		# Boost targets within range
		if dist <= gun_range or (torpedo_range > 0 and dist <= torpedo_range):
			priority *= 10.0

		# Apply flanking priority boost - DDs should intercept flankers
		var flank_info = _get_flanking_info(ship)
		if flank_info.is_flanking:
			# DDs are excellent at intercepting flankers due to speed and torpedoes
			var flank_multiplier = 6.0  # High priority for flankers
			var depth_scale = 1.0 + flank_info.penetration_depth
			priority *= flank_multiplier * depth_scale

		# Overextension score: how far into friendly territory this enemy is
		var overext = _get_overextension_score(ship)
		if overext > max_overextension:
			max_overextension = overext

		# Track whether any enemy is dangerously close
		if dist < proximity_override_dist:
			has_close_threat = true

		var shootable = _ship.visible_to_enemy and dist <= gun_range and can_hit_target(ship)
		candidate_data.append({
			ship = ship,
			base_priority = priority,
			dist = dist,
			overextension = overext,
			shootable = shootable,
		})

	# --- Second pass: apply overextension vs proximity weighting ---
	var best_shootable: Ship = null
	var best_shootable_priority: float = -1.0
	var best_fallback: Ship = null
	var best_fallback_priority: float = -1.0

	for data in candidate_data:
		var priority: float = data.base_priority
		var dist: float = data.dist
		var overext: float = data.overextension
		var ship: Ship = data.ship

		# Overextension contribution: reward enemies deeper into friendly territory
		if max_overextension > 0.0 and overextension_weight > 0.0:
			var relative_overext = overext / max_overextension
			var overext_contrib = relative_overext * overextension_weight
			priority += overext_contrib

			# Extra bonus for the most overextended target when nothing is dangerously close
			if not has_close_threat and relative_overext > 0.9:
				priority *= overextension_bonus

		# Proximity override: if this enemy is very close, give a strong boost
		if dist < proximity_override_dist:
			var proximity_factor = 1.0 + 2.0 * (1.0 - dist / proximity_override_dist)
			priority *= proximity_factor

		# Sort into shootable vs fallback
		if data.shootable:
			if priority > best_shootable_priority:
				best_shootable = ship
				best_shootable_priority = priority
		else:
			if priority > best_fallback_priority:
				best_fallback = ship
				best_fallback_priority = priority

	# Prefer shootable gun targets when visible; otherwise fall back
	# (when hidden, torpedo targets don't need line-of-fire for guns)
	return best_shootable if best_shootable != null else best_fallback

# ============================================================================
# AMMO AND AIM - Class-specific targeting logic
# ============================================================================

func pick_ammo(_target: Ship) -> int:
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _ship.global_position - _target.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var dist = disp.length()
	var offset = Vector3.ZERO

	ammo = ShellParams.ShellType.HE

	match _target.ship_class:
		Ship.ShipClass.BB:
			# HE at battleship superstructure
			ammo = ShellParams.ShellType.HE
			offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.CA:
			# Check if broadside
			if abs(sin(angle)) > sin(deg_to_rad(70)):
				if dist < 500:
					# AP at broadside cruisers waterline < 500
					ammo = ShellParams.ShellType.AP
					offset.y = 0.0
				elif dist < 1000:
					# AP at broadside cruisers when < 1000
					ammo = ShellParams.ShellType.AP
					offset.y = 0.5
				else:
					# HE at cruiser superstructure
					ammo = ShellParams.ShellType.HE
					offset.y = _target.movement_controller.ship_height / 2
			else:
				# HE at cruiser superstructure when angled
				ammo = ShellParams.ShellType.HE
				offset.y = _target.movement_controller.ship_height / 2
		Ship.ShipClass.DD:
			# Check if broadside for AP at waterline
			if abs(sin(angle)) > sin(deg_to_rad(70)) and dist < 1000:
				# AP at broadside destroyers at waterline when < 1000
				ammo = ShellParams.ShellType.AP
				offset.y = 0.0
			else:
				# HE at destroyers
				ammo = ShellParams.ShellType.HE
				offset.y = 1.0
	return offset

# ============================================================================
# NAVINTENT — V4 bot controller interface
# ============================================================================

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	wants_stealth = false  # reset each tick; always set true at end for DD
	wants_to_be_concealed = false  # reset each tick; set true below via probe
	var ctx = SkillContext.create(ship, target, server, self)
	_init_flank_identity(ship, server)

	var spotted   = server.get_valid_targets(ship.team.team_id)
	var unspotted = server.get_unspotted_enemies(ship.team.team_id)
	var has_targets = spotted.size() > 0 or not unspotted.is_empty()

	var hp_ratio          = ship.health_controller.current_hp / ship.health_controller.max_hp
	var concealment_radius: float = (ship.concealment.params.p() as ConcealmentParams).radius
	var pos_params        = get_positioning_params()
	var threat 			  = get_threat_score(ctx)

	var nearest_threat_dist := INF
	for s in spotted:
		var d := ship.global_position.distance_to(s.global_position)
		if d < nearest_threat_dist:
			nearest_threat_dist = d

	var _spot_chase_hunt = func():
		var _intent
		if threat < 0.5:
			if spotted.size() > 0:
				_intent = _skill_push.execute(ctx, {})
				if _intent:
					_active_skill_name = &"Push"
					wants_stealth = false
					wants_to_be_concealed = false
					_suppress_guns = false
			else:
				_intent = _skill_chase.execute(ctx, {})
				if _intent:
					_active_skill_name = &"Chase"
		if threat >= 0.5 or _intent == null:
			_intent = _skill_spot.execute(ctx, {"approach_distance": concealment_radius})
			_active_skill_name = &"Spot"
			if _intent == null:
				_intent = _skill_hunt.execute(ctx, {})
				_active_skill_name = &"Hunt"
		return _intent

	var intent: NavIntent = null

	# ── 1. No enemies → hunt ─────────────────────────────────────────────────
	if not has_targets:
		intent = _skill_hunt.execute(ctx, {})
		_active_skill_name = &"Hunt"

	# ── 2. Detected → retreat directly away from danger center; shed detection ASAP ──
	elif ship.visible_to_enemy:
		if threat < 0.5:
			intent = _skill_push.execute(ctx, {})
			if intent:
				_active_skill_name = &"Push"
				intent = _apply_reverse_alignment(intent, nearest_threat_dist, 8000.0)
			wants_stealth = false
			wants_to_be_concealed = false
		else:
			intent = _skill_retreat.execute(ctx, {})
			if intent:
				_active_skill_name = &"Retreat"

	# ── 3. Target is a DD → kite + broadside post-process, fallback hunt ──────
	elif target != null:
		intent = _spot_chase_hunt.call()

	# ── 4. No torpedo controller → spot, fallback hunt ───────────────────────
	elif ship.torpedo_controller == null:
		intent = _spot_chase_hunt.call()

	# ── 5. Torpedoes ready → torpedo run (non-DD targets only) ───────────────
	elif _get_max_torp_reload() >= 1.0 and target != null and target.ship_class != Ship.ShipClass.DD:
		# If a closer unspotted BB/CA is within striking range, spot it first —
		# a point-blank run on a revealed target is worth the delay.
		if _has_better_unspotted_torp_target(ship, target, server):
			intent = _spot_chase_hunt.call()
		else:
			intent = _skill_torpedo_run.execute(ctx, {})
			if intent:
				_active_skill_name = &"TorpedoRun"
			# Null intent — fall through to spotting
			if intent == null:
				intent = _spot_chase_hunt.call()

	# ── 6. Reloading → spot, fallback hunt ───────────────────────────────────
	else:
		intent = _spot_chase_hunt.call()

	# Final fallback
	if intent == null:
		intent = _intent_sail_forward(ship)
		_active_skill_name = &"SailForward"

	# DDs always use stealth-aware routing: when undetected this keeps them
	# outside enemy detection zones in transit; when detected it routes them
	# back toward cover so they shed detection as fast as possible.
	if threat > 0.5:
		wants_stealth = true
		_suppress_guns = true
	else:
		_suppress_guns = false

	# Concealment probe: suppress guns when detected + bloom active + enemy
	# is far enough away that going dark would actually drop us off detection.
	# DDs should always try to go dark when the opportunity exists.
	wants_to_be_concealed = _probe_concealment(server)

	# Post-process spread (skip for Retreat and Kite)
	if _active_skill_name == &"Spot":
		intent = _skill_spread.apply(intent, ctx, {"spread_distance": 5000.0, "spread_multiplier": 1.0})

	elif _active_skill_name not in [&"FindCover", &"Push", &"Kite", &"Retreat"]:
		intent = _skill_spread.apply(intent, ctx, {"spread_distance": 1000.0, "spread_multiplier": 1.0})

	if _active_skill_name not in [&"Retreat", &"Spot"]:
		intent = _skill_broadside.apply(intent, ctx, {})

	return intent

# ============================================================================
# COMBAT - DD-specific engagement with torpedo logic
# ============================================================================

## Returns true when there is an unspotted non-DD enemy that is both within
## 1.5× torpedo range AND closer to us than the current spotted target.
## In that case it is worth spotting first for a better torpedo run.
func _has_better_unspotted_torp_target(ship: Ship, current_target: Ship, server: GameServer) -> bool:
	if ship.torpedo_controller == null:
		return false
	var torp_range: float = ship.torpedo_controller.get_params()._range
	if torp_range <= 0.0:
		return false

	var scan_radius: float = torp_range * 1.5
	var current_dist: float = ship.global_position.distance_to(current_target.global_position) \
		if current_target != null else INF

	var unspotted := server.get_unspotted_enemies(ship.team.team_id)
	for s in unspotted.keys():
		if not is_instance_valid(s):
			continue
		if s.ship_class == Ship.ShipClass.DD:
			continue  # DDs are poor torpedo targets
		var last_pos: Vector3 = unspotted[s]
		var dist: float = ship.global_position.distance_to(last_pos)
		if dist <= scan_radius and dist < current_dist:
			return true
	return false

func engage_target(target: Ship):
	# Guns only when already spotted (revealing position is already done)
	if _ship.visible_to_enemy or not _suppress_guns and can_fire_guns():
		super.engage_target(target)
	else:
		# Aim turrets but don't fire
		_ship.artillery_controller.set_aim_input(target.global_position + target.global_basis * target_aim_offset(target))

	# Torpedoes are always managed
	update_torpedo_aim(target)
	torpedo_fire_timer += 1.0 / Engine.physics_ticks_per_second
	if torpedo_fire_timer >= torpedo_fire_interval:
		torpedo_fire_timer = 0.0
		try_fire_torpedoes(target)
