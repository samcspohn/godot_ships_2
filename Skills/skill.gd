extends Resource
class_name Skill

var _ship: Ship = null
var skill_id: String = ""
var description: String = ""
var name: String = ""

func _init() -> void:
	setup_local_to_scene()

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
