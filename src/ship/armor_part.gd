extends StaticBody3D

class_name ArmorPart

var armor_system: ArmorSystemV2
var armor_path: String
var ship: Ship

func get_armor(face_index: int) -> float:
	return armor_system.get_face_armor_thickness(armor_path, face_index)
