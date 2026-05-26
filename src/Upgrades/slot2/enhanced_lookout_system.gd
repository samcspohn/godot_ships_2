extends Upgrade
class_name EnhancedLookoutSystem

const TORP_DETECT_MOD: float = 1.50

func _init() -> void:
	upgrade_id = "lookout_sys"
	name = "Enhanced Lookout System"
	description = "Greatly increases torpedo detection range. Guaranteed ship acquisition range is a placeholder."
	tier = 2
	icon = preload("res://icons/health-normal (1).png")
	flavor_text = "Advanced passive sonar and optical systems spot threats much earlier."
	tooltip_stats = [
		{"stat": "Torpedo Acquisition Range", "value": fmt_mult_pct(TORP_DETECT_MOD), "positive": true},
		{"stat": "Guaranteed Ship Acquisition", "value": "+50% (placeholder)"},
	]

func _a(_ship: Ship) -> void:
	(_ship.concealment.params.static_mod as ConcealmentParams).torpedo_detection_multiplier *= TORP_DETECT_MOD
	# Guaranteed ship acquisition range +50% is placeholder — no implementation yet
