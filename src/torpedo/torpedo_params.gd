extends Resource
class_name TorpedoParams

@export var speed: float
@export var damage: float

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(speed)
	writer.put_float(damage)
	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	speed = reader.get_float()
	damage = reader.get_float()
