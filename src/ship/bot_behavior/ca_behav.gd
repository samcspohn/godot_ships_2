extends BotBehavior
class_name CABehavior

var ammo = ShellParams.ShellType.HE

# Cover-zone mirror. Written by _sync_cover_debug() from the cover skill's own
# state, read by BotControllerV4's debug drawing — nothing else uses it.
var _cover_zone_valid: bool = false
var _cover_zone_radius: float = 200.0
var _cover_can_shoot: bool = false
var _cover_island_center: Vector3 = Vector3.ZERO
var _cover_island_radius: float = 0.0

# ============================================================================
# WEIGHT CONFIGURATION
# ============================================================================

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(30),
		max_angle = deg_to_rad(45),
		evasion_period = 5.0,
		vary_speed = false
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 1.4
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 0.3
	return 1.0

func get_target_weights() -> Dictionary:
	return {
		size_weight = 0.4,
		range_weight = 0.6,
		hp_weight = 0.0,
		class_modifiers = {
			Ship.ShipClass.BB: 1.0,
			Ship.ShipClass.CA: 1.2,
			Ship.ShipClass.DD: 1.5,
		},
		prefer_broadside = true,
		in_range_multiplier = 10.0,
		flanking_multiplier = 5.0,
		overextension_weight = 0.4,  # CAs balance between close threats and overextended enemies
		proximity_override_distance = 3000.0,
		overextension_bonus = 2.0,
	}

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.7,
		range_increase_when_damaged = 0.30,
		min_safe_distance_ratio = 0.40,
		flank_bias_healthy = 0.6,
		flank_bias_damaged = 0.2,
		spread_distance = 2000.0,
		spread_multiplier = 2.0,
	}



func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.3,
		cautious_hp_threshold = 0.5,
	}

func should_evade(_destination: Vector3) -> bool:
	if not _ship.is_detected():
		return false
	return true

# ============================================================================
# AMMO AND AIM
# ============================================================================

func engage_target(target: Ship) -> void:
	# Believed position, so a target that has gone dark is still tracked at its
	# dead-reckoned last-known position instead of its real one
	var aim_pos = contact_aim_point(target)
	if aim_pos == null:
		return
	if not can_fire_guns():
		_ship.artillery_controller.set_aim_input(aim_pos)
		return
	if _suppress_guns:
		_ship.artillery_controller.set_aim_input(aim_pos)
		return
	super.engage_target(target)

func pick_ammo(_target: Ship) -> int:
	return 0 if ammo == ShellParams.ShellType.AP else 1

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _ship.global_position - _target.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var dist = disp.length()
	var offset = Vector3.ZERO
	var dist_ratio: float = dist / _ship.artillery_controller.get_params()._range

	ammo = ShellParams.ShellType.HE
	var ap_auto_bounce: float = _ship.artillery_controller.get_params().shell1.auto_bounce
	var is_broadside = abs(angle - PI / 2.0) < lerp(ap_auto_bounce, PI * 0.25, pow(dist_ratio, 3.0))
	var bow_in = angle < PI / 2.0
	var stern_in = !bow_in

	match _target.ship_class:
		Ship.ShipClass.BB:
			if dist < 6000: # brawling range
				if is_broadside:
					ammo = ShellParams.ShellType.AP
					if _target.health_controller.casemate.pool1 > 0:
						offset.y = _target.movement_controller.ship_height / 4
					elif _target.health_controller.bow.pool1 > 0 and bow_in:
						offset.z = -_target.movement_controller.ship_length / 4
						offset.y = _target.movement_controller.ship_height / 5
					elif _target.health_controller.stern.pool1 > 0 and stern_in:
						offset.z = _target.movement_controller.ship_length / 4
						offset.y = _target.movement_controller.ship_height / 5
					else:
						offset.y = _target.movement_controller.ship_height / 4
				else:
					ammo = ShellParams.ShellType.HE
					if _target.health_controller.bow.pool1 > 0 and bow_in:
						offset.z = -_target.movement_controller.ship_length / 4
						offset.y = _target.movement_controller.ship_height / 5
					elif _target.health_controller.stern.pool1 > 0 and stern_in:
						offset.z = _target.movement_controller.ship_length / 4
						offset.y = _target.movement_controller.ship_height / 5
					else: # superstrucure
						offset.y = _target.movement_controller.ship_height / 2

			if is_broadside and dist < 12000:
				ammo = ShellParams.ShellType.AP
				offset.y = _target.movement_controller.ship_height / 4
			else: # angled and/or farther than 6000
				var fire_pos = null
				var priority_fires = [1,2,0,3]
				for i in priority_fires:
				# for fire: Fire in _target.fire_manager.fires:
					var fire: Fire = _target.fire_manager.fires[i]
					if fire.lifetime <= 0:
						fire_pos = fire.position
						break
				if fire_pos != null:
					offset = fire_pos
				else:
					offset.y = _target.movement_controller.ship_height / 2



		Ship.ShipClass.CA:
			if is_broadside:
				if dist < 10000:
					ammo = ShellParams.ShellType.AP
					offset.y = 0.5
				# elif dist < 10000:
				# 	ammo = ShellParams.ShellType.AP
				# 	offset.y = _target.movement_controller.ship_height / 4
				else:
					offset.y = _target.movement_controller.ship_height / 3
			else:
				offset.y = _target.movement_controller.ship_height / 3
		Ship.ShipClass.DD:
			offset.y = 1.0

	return offset

## Mirror the cover skill's internal state onto the fields debug.gd draws from.
## Shared with CVBehavior, which runs its own decision tree over the same skill.
func _sync_cover_debug(ctx: SkillContext) -> void:
	is_in_cover = _skill_cover.is_complete(ctx)
	_cover_can_shoot = _skill_cover.can_shoot
	if _skill_cover._nav_destination_valid:
		_cover_zone_valid = true
		_cover_island_center = _skill_cover._target_island_pos
		_cover_island_radius = _skill_cover._target_island_radius
	else:
		_cover_zone_valid = false

# ============================================================================
# NAVINTENT — decision arms specific to the cruiser
# ============================================================================

func doctrine() -> BotDoctrine:
	return BotDoctrine.for_cruiser()

func _cover_params() -> Dictionary:
	return {"desired_range": get_positioning_params().base_range_ratio}

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	wants_stealth = false  # reset each tick; set true below if conditions are met
	wants_to_be_concealed = false
	_suppress_guns = false
	_ensure_safe_dir(ship, server)
	_init_flank_identity(ship, server)
	var ctx := SkillContext.create(ship, target, server, self)
	_sync_cover_debug(ctx)
	return _nav_core(ctx)

## Low threat: push, but prefer running down a closer unseen contact over
## crossing the map to fight a distant visible one.
func _select_low_threat_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	var near_unspotted := _nearest_unspotted_info(ctx.server)
	if not near_unspotted.is_empty() \
			and near_unspotted.distance < sit.nearest_dist \
			and sit.nearest_dist > sit.gun_range:
		var chase := _run_skill(&"Chase", ctx)
		if chase != null:
			return chase
	return _run_skill(&"Push", ctx, {"desired_range": sit.engagement_range})

## Cover navigates to a hide position, so its heading belongs to the navigator.
## Every other close-arm skill wants a say in where the hull points, and near
## terrain it wants the whole say — otherwise the ship routes around an island
## showing its broadside the entire way.
func _shape_close_intent(intent: NavIntent, ctx: SkillContext, _sit: Dictionary) -> void:
	if _active_skill_name == &"FindCover":
		return
	intent.heading_weight = 0.5
	# TODO: improve by checking whether the desired heading points into terrain.
	var turn_radius: float = ctx.ship.movement_controller._p().turning_circle_radius
	if NavigationMapManager.get_distance(ctx.ship.global_position) < turn_radius * 4.0:
		intent.heading_weight = 1.0

## The engaged arm: high enough threat to stop pushing, but nothing close aboard.
## The cruiser splits on its own detection state — unseen, it goes and hides;
## seen, it weighs hiding against kiting.
func _select_engaged_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	var d := _doc()
	var cover_params := _cover_params()

	if not ctx.ship.is_detected():
		var hide := _run_skill(&"FindCover", ctx, cover_params)
		if hide != null:
			# Only worth holding fire if something out there actually has eyes on
			# us; if terrain covers every contact, shoot.
			_suppress_guns = _has_open_line_of_sight(ctx, sit)
			return hide
		return _run_skill(&"Push", ctx, {"desired_range": sit.engagement_range})

	var cover_intent := _skill_cover.execute(ctx, cover_params, false)
	if cover_intent == null:
		return _run_skill(&"Push", ctx, {"desired_range": sit.engagement_range})

	var off_path: bool = sit.nearest != null \
		and sit.threat > d.cover_abandon_threat \
		and not _skill_cover.is_cover_on_the_way(ctx) \
		and active_shooters_at_me.size() > 0
	if not off_path:
		_active_skill_name = &"FindCover"
		return cover_intent

	# Cover is too far off the engagement path and we are being shot at — kite,
	# but lean the destination slightly toward the island we gave up on.
	var intent := _run_skill(&"Kite", ctx, {"desired_range_ratio": 0.65})
	if intent == null:
		intent = _run_skill(&"Push", ctx, {"desired_range": sit.engagement_range})
	if intent != null:
		intent.target_position = intent.target_position.lerp(cover_intent.target_position, 0.1)
	return intent

## True when any contact inside gun range has a clear line to us.
func _has_open_line_of_sight(ctx: SkillContext, sit: Dictionary) -> bool:
	var from_pos: Vector3 = ctx.ship.global_position
	var gun_range: float = sit.gun_range
	for enemy in sit.spotted:
		if from_pos.distance_to(enemy.global_position) < gun_range \
				and not _is_los_blocked_with_clearance(from_pos, enemy.global_position):
			return true
	for pos in sit.unspotted.values():
		if from_pos.distance_to(pos) < gun_range \
				and not _is_los_blocked_with_clearance(from_pos, pos):
			return true
	return false

func _apply_gun_policy(ctx: SkillContext, sit: Dictionary) -> void:
	# Only when something is actually spotted, matching the arms this used to sit
	# in. Result unused: the call is kept for its side effect, deducing a
	# concealed spotter from unexplained bloom.
	if sit.has_spotted:
		_probe_concealment(ctx.server)

func try_use_consumable():
	super.try_use_consumable()
