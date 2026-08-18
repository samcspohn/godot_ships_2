extends CABehavior
class_name CVBehavior
# Carrier doctrine: fight with its air group from a long standoff.
# Reuses BB navigation/aiming; guns are secondary, aviation is primary
# (driven by BotBehavior.aviation_engage from the controller).

func get_positioning_params() -> Dictionary:
	return {
		base_range_ratio = 0.85,            # keep to 85% of gun range — carriers don't close
		range_increase_when_damaged = 0.15,
		min_safe_distance_ratio = 0.40,     # start pulling back earlier than a BB
		flank_bias_healthy = 0.4,
		flank_bias_damaged = 0.2,
		spread_distance = 2000.0,
		spread_multiplier = 1.0,
	}

func get_threat_class_weight(ship_class: Ship.ShipClass) -> float:
	match ship_class:
		Ship.ShipClass.BB: return 1.0
		Ship.ShipClass.CA: return 1.0
		Ship.ShipClass.DD: return 0.5
		Ship.ShipClass.CV: return 0.5
	return 1.0

func get_hunting_params() -> Dictionary:
	return {
		approach_multiplier = 0.6,      # stand off 60% of gun range ahead of last known positions
		cautious_hp_threshold = 0.35,
	}

func _roll_flank_depth() -> float:
	return randf_range(0.05, 0.15)  # stay closer to the friendly line than a BB
