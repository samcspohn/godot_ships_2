extends Resource
class_name Skill

var _ship: Ship = null
var skill_id: String = ""
var description: String = ""
var name: String = ""
## Optional icon shown on the skill button in the commander skills tab.
var icon: Texture2D = null
## Optional one-sentence description shown above the stat list.
var flavor_text: String = ""
## Structured stat entries for the rich tooltip.
## Each entry: {"stat": String, "value": String, "positive": bool}
## Omit the "positive" key for neutral/informational lines (shown in white).
var tooltip_stats: Array = []

## Ship classes this skill is available to. Empty = all classes.
## Use Ship.ShipClass values, e.g. [Ship.ShipClass.BB].
var allowed_classes: Array = []

## Skills sharing the same non-empty group are mutually exclusive: equipping
## one removes any other in the same group.
var exclusive_group: String = ""

## Tier (1..4). Used for grouping in the skills UI. Higher tiers are
## generally more impactful / build-defining.
var tier: int = 1

## Skill-point cost. A ship has a fixed budget (Ship.max_skill_points) and
## the sum of equipped skills' costs may not exceed it.
var cost: int = 1

const _CLASS_LABELS := {
	Ship.ShipClass.BB: "BB",
	Ship.ShipClass.CA: "CA",
	Ship.ShipClass.DD: "DD",
	Ship.ShipClass.CV: "CV",
}

func _init() -> void:
	setup_local_to_scene()

## Builds a BBCode string used by SkillButton's custom tooltip.
## Title is bold, flavor text is gray, stats are bullet-listed and
## colour-coded: green = beneficial, red = detrimental, white = neutral.
func get_tooltip_bbcode() -> String:
	var lines: PackedStringArray = []
	lines.append("[b]%s[/b]" % name)
	if tier == 5:
		lines.append("[color=#ffaa00]Ultimate  •  1 slot (exclusive)[/color]")
	elif cost > 0:
		lines.append("[color=#ffcc66]Tier %d  •  Cost %d pt%s[/color]" % [tier, cost, "s" if cost != 1 else ""])
	else:
		lines.append("[color=#ffcc66]Tier %d[/color]" % tier)
	if allowed_classes.size() > 0:
		var labels: PackedStringArray = []
		for c in allowed_classes:
			labels.append(_CLASS_LABELS.get(c, str(c)))
		lines.append("[color=#88aaff]Class: %s[/color]" % ", ".join(labels))
	if exclusive_group != "":
		lines.append("[color=#aa88ff]Group: %s (exclusive)[/color]" % exclusive_group)
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

## Returns true if this skill can be equipped on the given ship.
func is_allowed_for_ship(ship: Ship) -> bool:
	if ship == null:
		return true
	if allowed_classes.is_empty():
		return true
	return ship.ship_class in allowed_classes

## Override to build a preview/simulator UI inside `container`.
## `on_change` should be called each time a control value changes so the
## stats panel can refresh. Default no-op — skill has no variable state.
func build_preview_modal(_container: Control, _on_change: Callable) -> void:
	pass

## Formats a multiplier as a signed percentage-change string.
## e.g. 0.9 -> "-10%",  1.15 -> "+15%"
static func fmt_mult_pct(mod: float) -> String:
	var pct := (mod - 1.0) * 100.0
	if pct >= 0.0:
		return "+%.0f%%" % pct
	return "%.0f%%" % pct

## Formats an additive value with an explicit sign.
## e.g. 0.1 -> "+0.1",  -0.5 -> "-0.5"
static func fmt_add(val: float) -> String:
	if val >= 0.0:
		return "+%.1f" % val
	return "%.1f" % val

func _a(_ship: Ship):
	pass

func apply(ship: Ship):
	_ship = ship
	ship.add_dynamic_mod(_a)

func remove(ship: Ship):
	ship.remove_dynamic_mod(_a)

func _proc(_delta: float):
	pass

func init_ui(container: Control):
	pass

func update_ui(container: Control):
	pass

## Called once after init_ui so skills that need hover tooltips can register
## with the shared HoverTooltip overlay (which fires while Ctrl is held).
## `ht` is a HoverTooltip instance. Default no-op — skill has no hover UI.
func init_hover(_container: Control, _ht) -> void:
	pass

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	# writer.put_var(skill_id)
	# writer.put_var(name)
	# writer.put_var(description)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray):
	# var reader = StreamPeerBuffer.new()
	# reader.set_data(data)
	pass
