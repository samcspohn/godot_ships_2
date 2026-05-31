extends Node3D
class_name FloodManager

@export var dot_params: DOTParams
@export var rparams: ResistanceParams
var floods: Array[Flood] = []
var _ship: Ship

func get_active_floods() -> int:
	var count = 0
	for f in floods:
		if f.lifetime > 0:
			count += 1
	return count

func _ready() -> void:
	await get_parent().get_parent().ready
	dot_params = dot_params.instantiate(_ship) as DOTParams
	rparams = rparams.instantiate(_ship) as ResistanceParams
	floods.clear()
	for f: Flood in get_children():
		f.manager = self
		floods.append(f)
	floods.sort_custom(func(a: Flood, b: Flood) -> bool:
		return a.position.z < b.position.z
	)
