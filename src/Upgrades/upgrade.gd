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

## Optional one-sentence description shown above the stat list.
var flavor_text: String = ""
## Structured stat entries for the rich tooltip.
## Each entry: {"stat": String, "value": String, "positive": bool}
## Omit "positive" for neutral/informational lines (shown in white).
var tooltip_stats: Array = []

const _CLASS_LABELS := {
	Ship.ShipClass.BB: "BB",
	Ship.ShipClass.CA: "CA",
	Ship.ShipClass.DD: "DD",
	Ship.ShipClass.CV: "CV",
}

## Builds a BBCode string for the rich tooltip panel.
func get_tooltip_bbcode() -> String:
	var lines: PackedStringArray = []
	lines.append("[b]%s[/b]" % name)
	lines.append("[color=#ffcc66]Slot %d[/color]" % tier)
	if allowed_classes.size() > 0:
		var labels: PackedStringArray = []
		for c in allowed_classes:
			labels.append(_CLASS_LABELS.get(c, str(c)))
		lines.append("[color=#88aaff]Class: %s[/color]" % ", ".join(labels))
	if flavor_text != "":
		lines.append("")
		lines.append("[color=#aaaaaa]%s[/color]" % flavor_text)
	if tooltip_stats.size() > 0:
		lines.append("")
		for entry: Dictionary in tooltip_stats:
			var color: String
			if not entry.has("positive"):
				color = "#ffffff"
			elif entry["positive"]:
				color = "#55dd88"
			else:
				color = "#ff6666"
			lines.append("• %s:  [color=%s]%s[/color]" % [entry["stat"], color, entry["value"]])
	return "\n".join(lines)

static func fmt_mult_pct(mod: float) -> String:
	var pct := (mod - 1.0) * 100.0
	if pct >= 0.0:
		return "+%.0f%%" % pct
	return "%.0f%%" % pct

static func fmt_add(val: float) -> String:
	if val >= 0.0:
		return "+%.1f" % val
	return "%.1f" % val

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
