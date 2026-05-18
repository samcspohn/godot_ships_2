extends Resource
class_name Upgrade

var upgrade_id: String = ""
var icon: Texture2D
var name: String = ""
var description: String = ""

## Ship classes this upgrade is available to. Empty = all classes.
var allowed_classes: Array = []

## Tier / rank (1..4). Determines which slot this upgrade fits into.
## Upgrades are grouped by tier rather than by what they do, so each slot
## forces a real tradeoff (e.g. stealth vs tank vs accuracy at tier 2).
var tier: int = 1

func _a(_ship: Ship):
	pass

func apply(_ship: Ship):
	_ship.add_static_mod(_a)

func remove(_ship: Ship):
	_ship.remove_static_mod(_a)

## Returns true if this upgrade can be slotted on the given ship.
func is_allowed_for_ship(ship: Ship) -> bool:
	if ship == null:
		return true
	if allowed_classes.is_empty():
		return true
	return ship.ship_class in allowed_classes
