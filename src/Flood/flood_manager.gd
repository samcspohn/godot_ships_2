extends Node
class_name FloodManager

@export var params: FloodParams
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
	params = params.instantiate(_ship) as FloodParams
	#for f in floods:
		#f.manager = self
	for f: Flood in get_children():
		f.manager = self
		floods.append(f)
