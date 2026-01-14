extends TurretParams
class_name TorpedoLauncherParams

# @export var traverse_speed: float
# @export var reload_time: float
# @export var range: float
@export var torpedo_params: TorpedoParams

# func from_params(params: TorpedoLauncherParams) -> void:
# 	traverse_speed = params.traverse_speed
# 	reload_time = params.reload_time
# 	range = params._range
# 	torpedo_params = params.torpedo_params

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(traverse_speed)
	writer.put_float(reload_time)
	writer.put_float(_range)
	writer.put_var(torpedo_params.to_bytes())
	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	traverse_speed = reader.get_float()
	reload_time = reader.get_float()
	_range = reader.get_float()
	var torpedo_bytes = reader.get_var()
	torpedo_params = TorpedoParams.new()
	torpedo_params.from_bytes(torpedo_bytes)
