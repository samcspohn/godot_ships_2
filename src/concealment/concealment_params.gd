extends Moddable
class_name ConcealmentParams

@export var radius: float
@export var bloom_duration: float
@export var unspotted_bloom_duration: float

func from_bytes(data: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	radius = reader.get_float()
	bloom_duration = reader.get_float()
	unspotted_bloom_duration = reader.get_float()

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(radius)
	writer.put_float(bloom_duration)
	writer.put_float(unspotted_bloom_duration)
	return writer.data_array
