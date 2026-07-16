extends Moddable
class_name AAAParams

@export var dps: float = 100.0
@export var _range: float = 3000.0

func to_bytes() -> PackedByteArray:
	var writer := StreamPeerBuffer.new()
	writer.put_double(dps)
	writer.put_double(_range)
	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader := StreamPeerBuffer.new()
	reader.data_array = b
	dps = reader.get_double()
	_range = reader.get_double()
