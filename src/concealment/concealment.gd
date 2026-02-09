extends ShipModule
class_name Concealment

@export var params: ConcealmentParams
var bloom_value: float = 0.0
var bloom_radius: float = 0.0

var blooms: Dictionary[float, float] = {} # value : time_remaining
# var bloom_radii: Dictionary[float, float] = {} # radius : time_remaining
var bloom_while_not_visible: float = 0.0
var prev_visible: bool = false
var last_spotted_time: float = -101.0
var spotted_by: Ship = null

func _ready() -> void:
	params.init(_ship)
	_ship.concealment = self


func _physics_process(delta: float) -> void:
	if not _Utils.authority():
		return

	if blooms.size() == 0:
		bloom_value = 0.0
		bloom_radius = params.p().radius
		prev_visible = _ship.visible_to_enemy
		return

	# handle bloom while not visible
	if !_ship.visible_to_enemy:
		if prev_visible: # ship was visible now isn't
			bloom_while_not_visible = 1.0
			last_spotted_time = Time.get_ticks_msec() / 1000.0
		bloom_while_not_visible -= delta / params.p().unspotted_bloom_duration
		if bloom_while_not_visible <= 0.0:
			blooms.clear()
			bloom_value = 0.0
			bloom_radius = params.p().radius
	else:
		bloom_while_not_visible = 0.0
		last_spotted_time = Time.get_ticks_msec() / 1000.0

	# update bloom values
	var to_remove: Array[float] = []
	var max_bloom: float = 0.0
	var min_bloom_value: float = 0.0
	for amount in blooms.keys():
		blooms[amount] -= delta / params.p().bloom_duration
		if blooms[amount] <= 0.0:
			to_remove.append(amount)
		else:
			if amount > max_bloom:
				max_bloom = amount
			if blooms[amount] > min_bloom_value:
				min_bloom_value = blooms[amount]
	bloom_value = min_bloom_value
	for amount in to_remove:
		blooms.erase(amount)
	bloom_radius = max(max_bloom, params.p().radius)


func bloom(amount: float) -> void:
	blooms[amount] = 1.0
	if !_ship.visible_to_enemy:
		bloom_while_not_visible = 1.0

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
