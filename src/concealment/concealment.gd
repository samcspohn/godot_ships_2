extends ShipModule
class_name Concealment

@export var params: ConcealmentParams
var bloom_value: float = 0.0
var bloom_radius: float = 0.0

func _ready() -> void:
	params.init(_ship)
	_ship.concealment = self

func _physics_process(delta: float) -> void:
	if not _Utils.authority():
		return
	if bloom_value > 0.0:
		bloom_value -= delta / params.p().bloom_duration
	else:
		bloom_radius = params.p().radius

func bloom(amount: float) -> void:
	bloom_value = 1.0
	if bloom_radius < amount:
		bloom_radius = amount

func get_concealment() -> float:
	return bloom_radius

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(bloom_value)
	writer.put_float(bloom_radius)
	writer.put_var(params.dynamic_mod.to_bytes())
	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	bloom_value = reader.get_float()
	bloom_radius = reader.get_float()
	var mod_bytes = reader.get_var()
	params.dynamic_mod.from_bytes(mod_bytes)
