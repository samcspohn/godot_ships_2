extends Node
class_name FloodManager

@export var params: FloodParams
@export var floods: Array[Flood] = []
var _ship: Ship

func _ready() -> void:
	await get_parent().get_parent().ready
	params.init(_ship)
	for f in floods:
		f.manager = self
