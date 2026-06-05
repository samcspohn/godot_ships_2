extends Moddable
class_name DOTParams

@export var dmg_rate: float # per second
@export var dur: float

func _init() -> void:
	pass

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(dynamic_mod.dmg_rate)
	writer.put_float(dynamic_mod.dur)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	dynamic_mod.dmg_rate = reader.get_float()
	dynamic_mod.dur = reader.get_float()
