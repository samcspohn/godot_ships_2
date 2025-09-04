extends Node
class_name Stats

var total_damage: float = 0
var penetration_count: int = 0
var overpen_count: int = 0
var shatter_count: int = 0
var ricochet_count: int = 0
var citadel_count: int = 0

var secondary_count: int = 0

func to_dict() -> Dictionary:
	return {
		"td": total_damage,
		"p": penetration_count,
		"op": overpen_count,
		"s": shatter_count,
		"r": ricochet_count,
		"sh": secondary_count,
		"c": citadel_count
	}

func from_dict(data: Dictionary):
	total_damage = data.get("td", 0)
	penetration_count = data.get("p", 0)
	overpen_count = data.get("op", 0)
	shatter_count = data.get("s", 0)
	ricochet_count = data.get("r", 0)
	secondary_count = data.get("sh", 0)
	citadel_count = data.get("c", 0)
