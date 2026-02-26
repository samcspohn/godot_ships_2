extends Resource
class_name TorpedoParams

@export var speed_knts: float
var speed: float:
	get:
		return speed_knts * 0.514444  # Convert knots to meters per second
	set(value):
		speed_knts = value / 0.514444
@export var damage: float
@export var flood_buildup: float = 100.0  # Flooding chance buildup on hit
@export var detection_range: float = 1000.0  # Range at which the torpedo can be detected by enemy
@export var arming_distance: float = 100.0  # Distance torpedo must travel before it can arm and detonate

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(speed)
	writer.put_float(damage)
	writer.put_float(flood_buildup)
	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	speed = reader.get_float()
	damage = reader.get_float()
	flood_buildup = reader.get_float()
