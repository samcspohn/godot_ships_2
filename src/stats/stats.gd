extends Node
class_name Stats

var total_damage: float = 0
var penetration_count: int = 0
var overpen_count: int = 0
var shatter_count: int = 0
var ricochet_count: int = 0
var citadel_count: int = 0
var citadel_overpen_count: int = 0
var partial_pen_count: int = 0
var main_damage: float = 0

var frags: int = 0

var secondary_count: int = 0
var main_hits: int = 0

# Secondary hit counters
var sec_penetration_count: int = 0
var sec_overpen_count: int = 0
var sec_shatter_count: int = 0
var sec_ricochet_count: int = 0
var sec_citadel_count: int = 0
var sec_citadel_overpen_count: int = 0
var sec_partial_pen_count: int = 0

var sec_damage: float = 0
var damage_events: Array[Dictionary] = []

var fire_count: int = 0
var fire_damage: float = 0
var flood_count: int = 0
var flood_damage: float = 0

# Hit type to counter name mapping (matches ArmorInteraction.HitResult values)
const HIT_TYPE_COUNTERS := {
	0: "penetration_count",      # PENETRATION
	1: "partial_pen_count",      # PARTIAL_PEN
	2: "ricochet_count",         # RICOCHET
	3: "overpen_count",          # OVERPENETRATION
	4: "shatter_count",          # SHATTER
	5: "citadel_count",          # CITADEL
	6: "citadel_overpen_count",  # CITADEL_OVERPEN
}


## Records a hit event and updates all relevant stats.
## Called from C++ ProjectileManager to consolidate all stat tracking.
## [param hit_type] ArmorInteraction.HitResult enum value
## [param damage] Amount of damage dealt
## [param is_secondary] Whether this was a secondary battery hit
## [param position] World position of the hit
## [param sunk] Whether this hit caused the target to sink
func record_hit(hit_type: int, damage: float, is_secondary: bool, position: Vector3, sunk: bool) -> void:
	# Track total damage
	total_damage += damage

	# Track damage by weapon type
	if is_secondary:
		sec_damage += damage
		secondary_count += 1
	else:
		main_damage += damage
		main_hits += 1

	# Track hit type counter
	var counter_name: String = HIT_TYPE_COUNTERS.get(hit_type, "")
	if counter_name != "":
		var full_name := ("sec_" + counter_name) if is_secondary else counter_name
		set(full_name, get(full_name) + 1)

	# Track frag
	if sunk:
		frags += 1
		damage_events.append({
			"type": "sunk"
		})

	# Record damage event for UI processing
	damage_events.append({
		"type": "hit",
		"hit_type": hit_type,
		"sec": is_secondary,
		"damage": damage,
		"position": position
	})


func to_dict() -> Dictionary:
	var _damage_events = damage_events.duplicate()
	damage_events.clear()
	return {
		"td": total_damage,
		"p": penetration_count,
		"op": overpen_count,
		"s": shatter_count,
		"r": ricochet_count,
		"sh": secondary_count,
		"c": citadel_count,
		"co": citadel_overpen_count,
		"pp": partial_pen_count,
		"f": frags,
		"mh": main_hits,
		"sp": sec_penetration_count,
		"sop": sec_overpen_count,
		"ss": sec_shatter_count,
		"sr": sec_ricochet_count,
		"sc": sec_citadel_count,
		"sco": sec_citadel_overpen_count,
		"spp": sec_partial_pen_count,
		"st": sec_damage,
		"mtd": main_damage,
		"de": _damage_events,
		"fd": fire_damage,
		"fld": flood_damage
	}

func from_dict(data: Dictionary):
	total_damage = data.get("td", 0)
	penetration_count = data.get("p", 0)
	overpen_count = data.get("op", 0)
	shatter_count = data.get("s", 0)
	ricochet_count = data.get("r", 0)
	secondary_count = data.get("sh", 0)
	citadel_count = data.get("c", 0)
	citadel_overpen_count = data.get("co", 0)
	partial_pen_count = data.get("pp", 0)
	frags = data.get("f", 0)
	main_hits = data.get("mh", 0)
	sec_penetration_count = data.get("sp", 0)
	sec_overpen_count = data.get("sop", 0)
	sec_shatter_count = data.get("ss", 0)
	sec_ricochet_count = data.get("sr", 0)
	sec_citadel_count = data.get("sc", 0)
	sec_citadel_overpen_count = data.get("sco", 0)
	sec_partial_pen_count = data.get("spp", 0)
	sec_damage = data.get("st", 0)
	main_damage = data.get("mtd", 0)
	damage_events += data.get("de", [])
	fire_damage = data.get("fd", 0)
	flood_damage = data.get("fld", 0)


func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()

	writer.put_float(total_damage)
	writer.put_32(penetration_count)
	writer.put_32(overpen_count)
	writer.put_32(shatter_count)
	writer.put_32(ricochet_count)
	writer.put_32(citadel_count)
	writer.put_32(citadel_overpen_count)
	writer.put_32(partial_pen_count)

	writer.put_32(secondary_count)
	writer.put_32(frags)
	writer.put_32(main_hits)

	writer.put_32(sec_penetration_count)
	writer.put_32(sec_overpen_count)
	writer.put_32(sec_shatter_count)
	writer.put_32(sec_ricochet_count)
	writer.put_32(sec_citadel_count)
	writer.put_32(sec_citadel_overpen_count)
	writer.put_32(sec_partial_pen_count)

	writer.put_float(sec_damage)
	writer.put_float(main_damage)

	# Damage events
	writer.put_32(damage_events.size())
	for event in damage_events:
		# var event_dict = event
		# var event_bytes = PackedByteArray()
		# var event_writer = StreamPeerBuffer.new()
		# event_writer.put_var(event_dict)
		# event_bytes = event_writer.get_data_array()
		# writer.put_32(event_bytes.size())
		# writer.put_data(event_bytes)
		writer.put_var(event)
	damage_events.clear()

	writer.put_32(fire_count)
	writer.put_float(fire_damage)
	writer.put_32(flood_count)
	writer.put_float(flood_damage)

	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	total_damage = reader.get_float()
	penetration_count = reader.get_32() # these could be u16 to save bandwidth
	overpen_count = reader.get_32()
	shatter_count = reader.get_32()
	ricochet_count = reader.get_32()
	citadel_count = reader.get_32()
	citadel_overpen_count = reader.get_32()
	partial_pen_count = reader.get_32()

	secondary_count = reader.get_32()
	frags = reader.get_32()
	main_hits = reader.get_32()

	sec_penetration_count = reader.get_32()
	sec_overpen_count = reader.get_32()
	sec_shatter_count = reader.get_32()
	sec_ricochet_count = reader.get_32()
	sec_citadel_count = reader.get_32()
	sec_citadel_overpen_count = reader.get_32()
	sec_partial_pen_count = reader.get_32()
	sec_damage = reader.get_float()
	main_damage = reader.get_float()
	# Damage events
	var de_size = reader.get_32()
	for i in range(de_size):
		var event_dict: Dictionary = reader.get_var()
		damage_events.append(event_dict)
		# var event_size = reader.get_32()
		# var event_bytes = reader.get_data(event_size)
		# var event_reader = StreamPeerBuffer.new()
		# event_reader.data_array = event_bytes
		# var event_dict = event_reader.get_var()
		# damage_events.append(event_dict)
	fire_count = reader.get_32()
	fire_damage = reader.get_float()
	flood_count = reader.get_32()
	flood_damage = reader.get_float()
