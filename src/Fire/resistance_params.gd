extends Moddable
class_name ResistanceParams

@export var max_buildup: float = 100.0
@export var buildup_reduction_rate: float = 0.005 # 0.5% of max per second
@export_storage var reduction_block_rate: float = 1.0 # rate at which buildup reduction is blocked after shell hit, 1.0 means full block, 0.0 means no block

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(dynamic_mod.max_buildup)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	dynamic_mod.max_buildup = reader.get_float()
