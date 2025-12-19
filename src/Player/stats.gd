extends Node
class_name Stats

var total_damage: float = 0
var penetration_count: int = 0
var overpen_count: int = 0
var shatter_count: int = 0
var ricochet_count: int = 0
var citadel_count: int = 0
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

var sec_damage: float = 0
var damage_events: Array[Dictionary] = []

var fire_damage: float

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
		"f": frags,
		"mh": main_hits,
		"sp": sec_penetration_count,
		"sop": sec_overpen_count,
		"ss": sec_shatter_count,
		"sr": sec_ricochet_count,
		"sc": sec_citadel_count,
		"st": sec_damage,
		"mtd": main_damage,
		"de": _damage_events,
		"fd": fire_damage
	}

func from_dict(data: Dictionary):
	total_damage = data.get("td", 0)
	penetration_count = data.get("p", 0)
	overpen_count = data.get("op", 0)
	shatter_count = data.get("s", 0)
	ricochet_count = data.get("r", 0)
	secondary_count = data.get("sh", 0)
	citadel_count = data.get("c", 0)
	frags = data.get("f", 0)
	main_hits = data.get("mh", 0)
	sec_penetration_count = data.get("sp", 0)
	sec_overpen_count = data.get("sop", 0)
	sec_shatter_count = data.get("ss", 0)
	sec_ricochet_count = data.get("sr", 0)
	sec_citadel_count = data.get("sc", 0)
	sec_damage = data.get("st", 0)
	main_damage = data.get("mtd", 0)
	damage_events += data.get("de", [])
	fire_damage = data.get("fd", 0)
