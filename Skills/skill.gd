extends Resource
class_name Skill

var _ship: Ship = null
var skill_id: String = ""
var description: String = ""
var name: String = ""
## Optional one-sentence description shown above the stat list.
var flavor_text: String = ""
## Structured stat entries for the rich tooltip.
## Each entry: {"stat": String, "value": String, "positive": bool}
## Omit the "positive" key for neutral/informational lines (shown in white).
var tooltip_stats: Array = []

func _init() -> void:
	setup_local_to_scene()

## Builds a BBCode string used by SkillButton's custom tooltip.
## Title is bold, flavor text is gray, stats are bullet-listed and
## colour-coded: green = beneficial, red = detrimental, white = neutral.
func get_tooltip_bbcode() -> String:
	var lines: PackedStringArray = []
	lines.append("[b]%s[/b]" % name)
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
		return "+%g" % val
	return "%g" % val

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
