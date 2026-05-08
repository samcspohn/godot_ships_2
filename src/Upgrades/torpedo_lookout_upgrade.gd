extends Upgrade
## Torpedo Lookout System
## Increases torpedo detection range by 50% for this ship.

func _init() -> void:
	upgrade_id = "torpedo_lookout"
	name = "Torpedo Lookout System"
	description = "Increases the detection range of enemy torpedoes by 50%."

func _a(_ship: Ship) -> void:
	(_ship.concealment.params.static_mod as ConcealmentParams).torpedo_detection_multiplier *= 1.5
