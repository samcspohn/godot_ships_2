extends ConsumableItem
class_name HydroacousticSearch
## Hydroacoustic Search
## While active:
##   - Guarantees torpedo detection out to [torpedo_detection_range] metres.
##   - Force-spots enemy ships within [spotting_range] metres regardless of
##     their concealment radius.
## Both ranges are exported so different ships can carry stronger/weaker variants.

## Minimum torpedo detection range (metres) while active.
@export var torpedo_detection_range: float = 3000.0
## Force-spotting range for enemy ships (metres) while active.
@export var spotting_range: float = 4000.0

func _init() -> void:
	type = ConsumableType.HYDROACOUSTIC_SEARCH

## Writes both overrides onto the static_mod layer so they are picked up
## every physics tick without an extra per-frame lookup.
func _effect(ship: Ship) -> void:
	var cp := ship.concealment.params.static_mod as ConcealmentParams
	cp.torpedo_detection_range_override = torpedo_detection_range
	cp.spotting_range_override = spotting_range

func apply_effect(ship: Ship) -> void:
	ship.add_static_mod(_effect)

func remove_effect(ship: Ship) -> void:
	# Removing the mod function triggers _update_static_mods() which resets
	# static_mod from base and reapplies all remaining mods, so the override
	# is automatically cleared without manually zeroing it.
	ship.remove_static_mod(_effect)

func _get_stat_lines() -> Array[String]:
	return [
		"Torpedo detection: %.1f km" % (torpedo_detection_range / 1000.0),
		"Ship force-spot: %.1f km" % (spotting_range / 1000.0),
	]
