extends ConsumableItem
class_name Radar
## Radar
## While active:
##   - Force-spots enemy ships within [spotting_range] metres regardless of
##     their concealment radius (longer range than Hydroacoustic Search).
##   - Does NOT enhance torpedo detection (use Hydroacoustic Search for that).
## Range and duration are exported so different ships can carry variants.

## Force-spotting range for enemy ships (metres) while active.
@export var spotting_range: float = 8000.0

func _init() -> void:
	type = ConsumableType.RADAR

func _effect(ship: Ship) -> void:
	var cp := ship.concealment.params.static_mod as ConcealmentParams
	cp.radar_spotting_range_override = spotting_range

func apply_effect(ship: Ship) -> void:
	ship.add_static_mod(_effect)

func remove_effect(ship: Ship) -> void:
	ship.remove_static_mod(_effect)
