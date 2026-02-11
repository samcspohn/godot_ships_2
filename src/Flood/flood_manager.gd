extends Node
class_name FloodManager

@export var params: FloodParams
@export var floods: Array[Flood] = []
var _ship: Ship

func get_active_floods() -> int:
	var count = 0
	for f in floods:
		if f.lifetime > 0:
			count += 1
	return count

func _ready() -> void:
	await get_parent().get_parent().ready
	params.init(_ship)
	for f in floods:
		f.manager = self
