extends StaticBody3D

class_name ArmorPart

enum Type {
	MODULE,
	CITADEL,
	CASEMATE,
	BOW,
	STERN,
	SUPERSTRUCTURE
}

var armor_system: ArmorSystemV2
var armor_path: String
var ship: Ship
# var is_citadel: bool = false
var type: Type = Type.MODULE

var is_citadel: bool:
	get:
		return type == Type.CITADEL

func get_armor(face_index: int) -> float:
	return armor_system.get_face_armor_thickness(armor_path, face_index)
