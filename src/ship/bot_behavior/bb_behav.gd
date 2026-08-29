extends BotBehavior
class_name BBBehavior

var ammo = ShellParams.ShellType.AP

# Overmatch ratio cache: { ship_instance_id: { "bow": float, "stern": float } }
var _overmatch_cache: Dictionary = {}

const OVERMATCH_RATIO_THRESHOLD: float = 0.4  # 40% of faces must be overmatchable to prefer AP

# ============================================================================
# WEIGHT CONFIGURATION - Override base class methods
# ============================================================================

func get_evasion_params() -> Dictionary:
	return {
		min_angle = deg_to_rad(25),
		max_angle = deg_to_rad(35),
		evasion_period = 20.0,  # Slow, deliberate weaves
		vary_speed = false
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 0.5
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 2.0
	return 1.0

func get_target_weights() -> Dictionary:
	return {
		size_weight = 0.3,
		range_weight = 0.5,
		hp_weight = 0.2,
		class_modifiers = {
			Ship.ShipClass.BB: 1.0,
			Ship.ShipClass.CA: 1.0,
			Ship.ShipClass.DD: 1.0,
		},
		prefer_broadside = true,
		in_range_multiplier = 10.0,
		flanking_multiplier = 4.0,  # BBs prioritize flanking enemies (slightly lower than CA/DD since BBs turn slowly)
		overextension_weight = 0.5,  # BBs care a lot about overextended enemies (big guns punish pushes)
		proximity_override_distance = 4000.0,  # BBs have larger proximity threshold due to slow turning
		overextension_bonus = 2.5,  # Strong bonus for the most forward enemy when nothing is close
	}

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.60,           # 60% of gun range — active engagement distance
		range_increase_when_damaged = 0.10, # Up to +10% range when low HP — don't retreat to max range
		min_safe_distance_ratio = 0.30,     # Only retreat if something gets within 30% range (very close)
		flank_bias_healthy = 0.6,
		flank_bias_damaged = 0.2,
		spread_distance = 3000.0,
		spread_multiplier = 1.0,
	}

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.4,      # Stand off 40% of gun range in front of last known position
		cautious_hp_threshold = 0.4,    # Only pull back toward friendlies when quite damaged
	}

func _roll_flank_depth() -> float:
	return randf_range(0.1, 0.3)

# ============================================================================
# AMMO AND AIM - Class-specific targeting logic
# ============================================================================

func pick_ammo(_target: Ship) -> int:
	return 0 if ammo == ShellParams.ShellType.AP else 1

func _get_cached_overmatch(target: Ship) -> Dictionary:
	"""Return { bow: float, stern: float } overmatch ratios, cached per target."""
	var tid = target.get_instance_id()
	if _overmatch_cache.has(tid):
		return _overmatch_cache[tid]

	var bow_ratio = get_overmatch_ratio(target, ArmorPart.Type.BOW)
	var stern_ratio = get_overmatch_ratio(target, ArmorPart.Type.STERN)
	var entry = { "bow": bow_ratio, "stern": stern_ratio }
	_overmatch_cache[tid] = entry
	return entry

func _can_overmatch_bow(target: Ship) -> bool:
	return _get_cached_overmatch(target).bow >= OVERMATCH_RATIO_THRESHOLD

func _can_overmatch_stern(target: Ship) -> bool:
	return _get_cached_overmatch(target).stern >= OVERMATCH_RATIO_THRESHOLD

func target_aim_offset(_target: Ship) -> Vector3:
	var disp = _ship.global_position - _target.global_position
	var angle = (-_target.basis.z).angle_to(disp)
	var offset = Vector3(0, 0, 0)
	angle = abs(angle)

	# Default to AP
	ammo = ShellParams.ShellType.AP

	match _target.ship_class:
		Ship.ShipClass.BB:
			# Determine if the target is showing bow or stern
			var is_bow_on = angle < PI / 2.0   # forward half of target faces us
			var can_overmatch = _can_overmatch_bow(_target) if is_bow_on else _can_overmatch_stern(_target)

			if angle < deg_to_rad(10) or angle > deg_to_rad(170):
				# Heavily angled (nearly bow/stern-on)
				if can_overmatch:
					# AP will punch through the thin plating regardless of angle
					ammo = ShellParams.ShellType.AP
					offset.y = 0.1
					if is_bow_on:
						offset.z -= _target.movement_controller.ship_length * 0.25
					else:
						offset.z += _target.movement_controller.ship_length * 0.25
				else:
					# Thick bow/stern — AP will bounce, use HE on superstructure
					ammo = ShellParams.ShellType.HE
					var super_idx = _target.armor_parts.find_custom(func(part):
						return part.type == ArmorPart.Type.SUPERSTRUCTURE)
					if super_idx != -1:
						offset.y = (_target.armor_parts[super_idx] as ArmorPart).position.y
					else:
						offset.y = _target.movement_controller.ship_height * 0.55
			elif angle < deg_to_rad(30) or angle > deg_to_rad(150):
				# Moderately angled
				if can_overmatch:
					# AP through the bow/stern plate into the hull
					ammo = ShellParams.ShellType.AP
					offset.y = 0.1
					if is_bow_on:
						offset.z -= _target.movement_controller.ship_length * 0.25
					else:
						offset.z += _target.movement_controller.ship_length * 0.25
				else:
					# Can't overmatch — AP at superstructure for reliable damage
					ammo = ShellParams.ShellType.AP
					offset.y = _target.movement_controller.ship_height / 2.0
			else:
				# Broadside — always AP at waterline for citadel hits
				ammo = ShellParams.ShellType.AP
				offset.y = 0.1
		Ship.ShipClass.CA:
			if angle < deg_to_rad(20):
				# AP at angled cruiser bow/stern
				ammo = ShellParams.ShellType.AP
				offset.z -= _target.movement_controller.ship_length * 0.25
			elif angle > deg_to_rad(180-20):
				ammo = ShellParams.ShellType.AP
				offset.z += _target.movement_controller.ship_length * 0.25
			else:
				# AP at broadside cruisers waterline
				ammo = ShellParams.ShellType.AP
				offset.y = 0.0
		Ship.ShipClass.DD:
			# AP at destroyers — overpens citadel for good damage
			ammo = ShellParams.ShellType.HE
			offset.y = 2.0
			offset.z -= _target.movement_controller.ship_length * 0.2
	return offset

# ============================================================================
# NAVINTENT — V4 bot controller interface
# ============================================================================

func doctrine() -> BotDoctrine:
	return BotDoctrine.for_battleship()

func get_nav_intent(target: Ship, ship: Ship, server: GameServer) -> NavIntent:
	wants_stealth = false  # BBs push or camp — never route around detection zones
	wants_to_be_concealed = false
	_init_flank_identity(ship, server)
	return _nav_core(SkillContext.create(ship, target, server, self))

## The engaged arm: not close aboard, or not detected. A battleship walks a
## threat ladder — flank while it is quiet, camp while it is manageable, get
## behind an island as it builds, and kite once it is bad.
func _select_engaged_skill(ctx: SkillContext, sit: Dictionary) -> NavIntent:
	var d := _doc()
	if sit.threat < d.flank_max_threat or sit.nearest_dist > sit.gun_range:
		return _run_skill(&"Flank", ctx)

	if sit.threat < d.camp_max_threat and active_shooters_at_me.is_empty():
		var camp := _run_skill(&"Camp", ctx, {"here": true})
		# Probe cover so its team-wide claim bookkeeping stays warm; _finish_nav
		# releases the claim again because Camp is what actually got adopted.
		_skill_cover.execute(ctx, {})
		return camp

	if sit.threat < d.cover_max_threat:
		return _run_skill(&"FindCover", ctx)

	var cover_intent := _skill_cover.execute(ctx, {}, false)
	var cover_usable: bool = cover_intent != null \
		and (_skill_cover.is_cover_on_the_way(ctx)
			or not ctx.ship.is_detected()
			or active_shooters_at_me.is_empty()) \
		and sit.nearest_threat_dist > d.cover_min_threat_dist
	if cover_usable:
		_active_skill_name = &"FindCover"
		return cover_intent
	return _run_skill(&"Kite", ctx)

func _apply_gun_policy(ctx: SkillContext, _sit: Dictionary) -> void:
	# Result deliberately unused: BBs never suppress. The call is kept for its
	# side effect — deducing a concealed spotter from unexplained bloom.
	_probe_concealment(ctx.server)
